import Foundation
import SwiftData
import NotesCore

enum StorageMode: String, Codable {
    case local      // Mode A: standalone note
    case file       // Mode B: linked to one repository file
    case workspace  // Mode C: file opened from a connected repository workspace
}

enum SyncStatus {
    case local, synced, modified, newFile, conflict, remoteDeleted
}

@Model final class Note {
    @Attribute(.unique) var id: UUID
    var body: String
    var createdAt: Date
    var modifiedAt: Date
    var isPinned: Bool
    var folderID: UUID?
    var deletedAt: Date?
    var modeRaw: String

    // Repository identity (Mode B / C). `path` is canonical and the note ID stays stable across renames.
    var repoOwner: String?
    var repoName: String?
    var repoID: Int?
    var path: String?
    var branch: String?
    var readOnly: Bool
    /// Last remote blob SHA and content this note was known to match.
    var baseSHA: String?
    var baseContent: String?
    var lastCommitSHA: String?
    var lastSyncedAt: Date?
    var lastSyncError: String?
    /// "ok", "conflict" or "remoteDeleted"
    var statusRaw: String
    var conflictRemoteContent: String?
    var conflictRemoteSHA: String?

    init(body: String = "", folderID: UUID? = nil) {
        id = UUID(); self.body = body
        createdAt = .now; modifiedAt = .now
        isPinned = false; self.folderID = folderID
        modeRaw = StorageMode.local.rawValue
        readOnly = false; statusRaw = "ok"
    }

    var mode: StorageMode {
        get { StorageMode(rawValue: modeRaw) ?? .local }
        set { modeRaw = newValue.rawValue }
    }

    var title: String {
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let t = line.trimmingCharacters(in: CharacterSet(charactersIn: "# \t"))
            if !t.isEmpty { return t }
        }
        return path.map { ($0 as NSString).lastPathComponent } ?? "New Note"
    }

    var preview: String {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: true).dropFirst()
        return lines.prefix(2).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    var repoFullName: String? {
        guard let o = repoOwner, let n = repoName else { return nil }
        return "\(o)/\(n)"
    }

    var syncStatus: SyncStatus {
        if mode == .local { return .local }
        if statusRaw == "conflict" { return .conflict }
        if statusRaw == "remoteDeleted" { return .remoteDeleted }
        if baseSHA == nil { return .newFile }
        return body == baseContent ? .synced : .modified
    }

    var hasPendingChanges: Bool {
        switch syncStatus { case .modified, .newFile: return true; default: return false }
    }

    var isLocal: Bool { mode == .local }
}

@Model final class Folder {
    @Attribute(.unique) var id: UUID
    var name: String
    var parentID: UUID?
    var createdAt: Date
    /// Optional mapping to a repository directory (informational; never deletes remote data).
    var mappedRepo: String?
    var mappedPath: String?
    init(name: String, parentID: UUID? = nil) {
        id = UUID(); self.name = name; self.parentID = parentID; createdAt = .now
    }
}

/// Local edit history, kept separate from GitHub commit history.
@Model final class LocalRevision {
    var id: UUID
    var noteID: UUID
    var body: String
    var reason: String   // "edit", "before pull", "before conflict resolution", "restore"
    var createdAt: Date
    init(noteID: UUID, body: String, reason: String) {
        id = UUID(); self.noteID = noteID; self.body = body; self.reason = reason; createdAt = .now
    }
}

@Model final class RepoConnection {
    @Attribute(.unique) var id: UUID
    var owner: String
    var name: String
    var repoID: Int
    var repoDescription: String?
    var isPrivate: Bool
    var canPush: Bool
    var defaultBranch: String
    var currentBranch: String
    var lastFetchedAt: Date?
    var defaultDirectory: String
    var excludedPaths: [String]
    var htmlURL: String?

    init(repo: GHRepo) {
        id = UUID(); owner = repo.owner.login; name = repo.name; repoID = repo.id
        repoDescription = repo.description; isPrivate = repo.private; canPush = repo.canPush
        defaultBranch = repo.defaultBranch ?? "main"; currentBranch = repo.defaultBranch ?? "main"
        defaultDirectory = ""; excludedPaths = []; htmlURL = repo.htmlUrl?.absoluteString
    }
    var fullName: String { "\(owner)/\(name)" }
}
