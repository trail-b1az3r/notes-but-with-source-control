import Foundation
import SwiftData
import Observation
import NotesCore

/// Local-first synchronization. The local database is the durable source for unsynced edits:
/// nothing is marked synced until GitHub confirms the commit.
@MainActor @Observable final class SyncService {
    let context: ModelContext
    let app: AppModel
    private(set) var busy: Set<UUID> = []
    var lastError: [UUID: String] = [:]
    private var debounce: [UUID: Task<Void, Never>] = [:]
    private var attempts: [UUID: Int] = [:]

    init(context: ModelContext, app: AppModel) {
        self.context = context; self.app = app
        app.onReconnect = { [weak self] in
            guard Prefs.autoSync else { return }
            Task { await self?.syncAll() }
        }
    }

    // MARK: Local editing

    func noteEdited(_ note: Note) {
        note.modifiedAt = .now
        snapshotIfStale(note)
        try? context.save()
        guard !note.isLocal, Prefs.autoSync, note.hasPendingChanges, note.syncStatus != .conflict else { return }
        debounce[note.id]?.cancel()
        debounce[note.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000) // idle period: never commit per keystroke
            guard !Task.isCancelled else { return }
            await self?.sync(note)
        }
    }

    func snapshot(_ note: Note, reason: String) {
        context.insert(LocalRevision(noteID: note.id, body: note.body, reason: reason))
        try? context.save()
    }

    private func snapshotIfStale(_ note: Note) {
        let id = note.id
        var d = FetchDescriptor<LocalRevision>(predicate: #Predicate { $0.noteID == id }, sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        d.fetchLimit = 1
        let last = try? context.fetch(d).first
        if last == nil || Date.now.timeIntervalSince(last!.createdAt) > 300 { snapshot(note, reason: "edit") }
    }

    func revisions(for note: Note) -> [LocalRevision] {
        let id = note.id
        return (try? context.fetch(FetchDescriptor<LocalRevision>(predicate: #Predicate { $0.noteID == id }, sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
    }

    // MARK: Opening / creating repository files

    func open(owner: String, repo: GHRepo?, name: String, path: String, branch: String, mode: StorageMode, readOnly: Bool, repoID: Int?) async throws -> Note {
        let cleanPath = try RepoPath.validate(path)
        guard RepoPath.isNote(cleanPath) else { throw GitHubError.validation("Only .md, .markdown and .txt files can be opened as notes.") }
        let all = (try? context.fetch(FetchDescriptor<Note>())) ?? []
        if let existing = all.first(where: { $0.repoOwner == owner && $0.repoName == name && $0.path == cleanPath && $0.branch == branch && $0.deletedAt == nil }) {
            return existing
        }
        let f = try await app.client.file(owner: owner, name: name, path: cleanPath, ref: branch)
        guard let text = f.text else { throw GitHubError.notUTF8 }
        let n = Note(body: text)
        n.mode = mode; n.repoOwner = owner; n.repoName = name; n.repoID = repoID
        n.path = cleanPath; n.branch = branch; n.readOnly = readOnly
        n.baseSHA = f.sha; n.baseContent = text; n.lastSyncedAt = .now
        context.insert(n); try? context.save()
        return n
    }

    /// Creates a note for a file that does not exist remotely yet; the first commit creates it.
    func newFile(conn: RepoConnection, path: String) throws -> Note {
        var clean = try RepoPath.validate(path)
        if !RepoPath.isNote(clean) { clean += ".md" }
        let n = Note(body: "# \(((clean as NSString).lastPathComponent as NSString).deletingPathExtension)\n\n")
        n.mode = .workspace; n.repoOwner = conn.owner; n.repoName = conn.name; n.repoID = conn.repoID
        n.path = clean; n.branch = conn.currentBranch; n.readOnly = !conn.canPush
        context.insert(n); try? context.save()
        return n
    }

    /// Links a local note to a new file in a repository (explicit user action; never automatic).
    func link(_ note: Note, conn: RepoConnection, path: String) throws {
        var clean = try RepoPath.validate(path)
        if !RepoPath.isNote(clean) { clean += ".md" }
        snapshot(note, reason: "before linking")
        note.mode = .file; note.repoOwner = conn.owner; note.repoName = conn.name; note.repoID = conn.repoID
        note.path = clean; note.branch = conn.currentBranch; note.readOnly = !conn.canPush
        note.baseSHA = nil; note.baseContent = nil; note.statusRaw = "ok"
        try? context.save()
    }

    /// Turns a linked note back into a local note, keeping its content. Remote data is untouched.
    func detach(_ note: Note) {
        note.mode = .local; note.statusRaw = "ok"
        note.baseSHA = nil; note.baseContent = nil; note.conflictRemoteContent = nil; note.conflictRemoteSHA = nil
        try? context.save()
    }

    // MARK: Sync

    func syncAll() async {
        let notes = ((try? context.fetch(FetchDescriptor<Note>())) ?? []).filter { !$0.isLocal && $0.deletedAt == nil && $0.syncStatus != .conflict }
        for n in notes { await sync(n) }
    }

    func pendingNotes() -> [Note] {
        ((try? context.fetch(FetchDescriptor<Note>())) ?? []).filter { $0.deletedAt == nil && ($0.hasPendingChanges || $0.syncStatus == .conflict || $0.syncStatus == .remoteDeleted) }
    }

    /// Pulls remote changes and pushes local ones. `message` is the commit message used if a commit is made.
    @discardableResult
    func sync(_ note: Note, message: String? = nil) async -> Bool {
        guard !note.isLocal, let owner = note.repoOwner, let repo = note.repoName,
              let path = note.path, let branch = note.branch else { return true }
        guard !busy.contains(note.id) else { return false }
        guard app.isSignedIn else { note.lastSyncError = "Sign in to GitHub to sync this note."; return false }
        guard app.isOnline else {
            note.lastSyncError = "Offline. Your edits are saved on this device and will sync when you're back online."
            return false
        }
        busy.insert(note.id); defer { busy.remove(note.id) }
        debounce[note.id]?.cancel()

        do {
            for _ in 0..<2 { // one retry if a concurrent push races us
                var remote: RemoteSnapshot?
                do {
                    let f = try await app.client.file(owner: owner, name: repo, path: path, ref: branch)
                    guard let text = f.text else { throw GitHubError.notUTF8 }
                    remote = RemoteSnapshot(sha: f.sha, content: text)
                } catch GitHubError.notFound { remote = nil }

                let state = FileSyncState(baseContent: note.baseContent ?? "", baseSHA: note.baseSHA, localContent: note.body, remote: remote)
                let msg = message ?? Prefs.commitMessage(for: note)

                // A file created locally that doesn't exist remotely yet.
                if note.baseSHA == nil, remote == nil {
                    if note.readOnly { throw GitHubError.forbidden("This repository is read-only for your account.") }
                    try await push(note, owner, repo, path, branch, blobSHA: nil, message: msg)
                    attempts[note.id] = nil; return true
                }

                switch SyncPlanner.decide(state) {
                case .upToDate:
                    markSynced(note, sha: remote?.sha, content: remote?.content)
                    return true
                case .push:
                    if note.readOnly { throw GitHubError.forbidden("This repository is read-only for your account. Your edits stay on this device.") }
                    do { try await push(note, owner, repo, path, branch, blobSHA: remote?.sha, message: msg) }
                    catch GitHubError.conflict { continue }
                    attempts[note.id] = nil; return true
                case .pull(let r):
                    snapshot(note, reason: "before pull")
                    note.body = r.content
                    markSynced(note, sha: r.sha, content: r.content)
                    return true
                case .adoptRemote(let r):
                    markSynced(note, sha: r.sha, content: r.content)
                    return true
                case .autoMerge(let merged, let r):
                    // Non-overlapping edits: keep a recovery copy, apply locally, then push on top of the remote.
                    snapshot(note, reason: "before auto-merge")
                    note.body = merged
                    note.baseSHA = r.sha; note.baseContent = r.content
                    try? context.save()
                    if note.readOnly { throw GitHubError.forbidden("Merged locally, but this repository is read-only for your account.") }
                    do { try await push(note, owner, repo, path, branch, blobSHA: r.sha, message: msg) }
                    catch GitHubError.conflict { continue }
                    return true
                case .conflict(_, let r):
                    snapshot(note, reason: "before conflict")
                    note.statusRaw = "conflict"
                    note.conflictRemoteContent = r.content; note.conflictRemoteSHA = r.sha
                    note.lastSyncError = "This file changed on GitHub while you were editing it."
                    try? context.save()
                    return false
                case .remoteDeleted:
                    note.statusRaw = "remoteDeleted"
                    note.lastSyncError = "This file was deleted or moved on GitHub."
                    try? context.save()
                    return false
                }
            }
            throw GitHubError.conflict
        } catch {
            app.report(error)
            note.lastSyncError = AppModel.message(for: error)
            attempts[note.id, default: 0] += 1
            try? context.save()
            scheduleRetry(note, error: error)
            return false
        }
    }

    private func push(_ note: Note, _ owner: String, _ repo: String, _ path: String, _ branch: String, blobSHA: String?, message: String) async throws {
        let body = note.body
        let r = try await app.client.putFile(owner: owner, name: repo, path: path, message: message,
                                             content: Data(body.utf8), blobSHA: blobSHA, branch: branch)
        // Only now, with GitHub's confirmation, is the note considered synced.
        note.lastCommitSHA = r.commitSHA
        markSynced(note, sha: r.blobSHA, content: body)
    }

    private func markSynced(_ note: Note, sha: String?, content: String?) {
        note.baseSHA = sha; note.baseContent = content
        note.statusRaw = "ok"; note.lastSyncError = nil; note.lastSyncedAt = .now
        note.conflictRemoteContent = nil; note.conflictRemoteSHA = nil
        try? context.save()
    }

    private func scheduleRetry(_ note: Note, error: Error) {
        guard Prefs.autoSync else { return }
        switch error as? GitHubError {
        case .network?, .server?, .rateLimited?: break
        default: return
        }
        let delay = Backoff.delay(attempt: attempts[note.id] ?? 1)
        debounce[note.id]?.cancel()
        debounce[note.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.sync(note)
        }
    }

    // MARK: Conflict resolution

    func resolveKeepLocal(_ note: Note) async {
        guard let rc = note.conflictRemoteContent, let rs = note.conflictRemoteSHA else { return }
        snapshot(note, reason: "before conflict resolution")
        note.baseContent = rc; note.baseSHA = rs; note.statusRaw = "ok"
        await sync(note, message: "Resolve conflict in \(note.path ?? "file"): keep local version")
    }

    func resolveAcceptRemote(_ note: Note) {
        guard let rc = note.conflictRemoteContent, let rs = note.conflictRemoteSHA else { return }
        snapshot(note, reason: "before accepting remote")
        note.body = rc
        markSynced(note, sha: rs, content: rc)
    }

    func resolveManual(_ note: Note, text: String) async {
        guard let rc = note.conflictRemoteContent, let rs = note.conflictRemoteSHA else { return }
        snapshot(note, reason: "before conflict resolution")
        note.body = text
        note.baseContent = rc; note.baseSHA = rs; note.statusRaw = "ok"
        try? context.save()
        await sync(note, message: "Merge changes in \(note.path ?? "file")")
    }

    func recreateRemote(_ note: Note) async {
        note.baseSHA = nil; note.baseContent = nil; note.statusRaw = "ok"
        await sync(note)
    }

    // MARK: Remote file operations

    func reload(_ note: Note, branch: String? = nil) async throws {
        guard !note.hasPendingChanges else { throw GitHubError.validation("Commit or discard your pending changes first.") }
        guard let o = note.repoOwner, let r = note.repoName, let p = note.path else { return }
        let b = branch ?? note.branch ?? "main"
        let f = try await app.client.file(owner: o, name: r, path: p, ref: b)
        guard let text = f.text else { throw GitHubError.notUTF8 }
        note.branch = b; note.body = text
        markSynced(note, sha: f.sha, content: text)
    }

    /// GitHub's contents API has no rename; a move is a create at the new path plus a delete of the old one (two commits).
    func move(_ note: Note, to newPath: String) async throws {
        guard !note.hasPendingChanges, let o = note.repoOwner, let r = note.repoName, let old = note.path,
              let b = note.branch, let oldSHA = note.baseSHA else {
            throw GitHubError.validation("Commit your pending changes before moving this file.")
        }
        var clean = try RepoPath.validate(newPath)
        if !RepoPath.isNote(clean) { clean += ".md" }
        let created = try await app.client.putFile(owner: o, name: r, path: clean, message: "Move \(old) to \(clean)", content: Data(note.body.utf8), blobSHA: nil, branch: b)
        _ = try await app.client.deleteFile(owner: o, name: r, path: old, message: "Move \(old) to \(clean)", blobSHA: oldSHA, branch: b)
        note.path = clean
        markSynced(note, sha: created.blobSHA, content: note.body)
    }

    /// Deletes the file on GitHub (creates a delete commit) and converts the note to a local copy.
    func deleteRemote(_ note: Note) async throws {
        guard let o = note.repoOwner, let r = note.repoName, let p = note.path, let b = note.branch, let sha = note.baseSHA else { return }
        _ = try await app.client.deleteFile(owner: o, name: r, path: p, message: "Delete \(p)", blobSHA: sha, branch: b)
        detach(note)
    }
}
