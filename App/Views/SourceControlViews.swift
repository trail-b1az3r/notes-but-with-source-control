import SwiftUI
import SwiftData
import NotesCore

// MARK: Diff

struct DiffView: View {
    let lines: [DiffLine]
    var body: some View {
        if LineDiff.summary(lines).isEmpty {
            ContentUnavailableView("No Differences", systemImage: "equal.circle", description: Text("These two versions are identical."))
        } else {
            ScrollView([.vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(LineDiff.collapse(lines)) { l in
                        HStack(alignment: .top, spacing: 6) {
                            Text(l.kind == .added ? "+" : l.kind == .removed ? "−" : " ").frame(width: 14)
                            Text(l.text.isEmpty ? " " : l.text).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(.footnote, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 1)
                        .background(l.kind == .added ? Color.green.opacity(0.18) : l.kind == .removed ? Color.red.opacity(0.18) : .clear)
                        .accessibilityLabel("\(l.kind == .added ? "Added" : l.kind == .removed ? "Removed" : "Unchanged"): \(l.text)")
                    }
                }
            }
        }
    }
}

// MARK: GitHub history

struct HistoryView: View {
    let note: Note
    @Environment(AppModel.self) private var app
    @State private var commits: [GHCommitSummary] = []
    @State private var loading = true
    @State private var error: String?
    @State private var page = 1
    @State private var more = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(commits) { c in
                    NavigationLink { CommitVersionView(note: note, commit: c) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(c.headline).font(.headline).lineLimit(2)
                            HStack {
                                Text(c.authorName); Text("·")
                                if let d = c.date { Text(d, format: .relative(presentation: .named)) }
                                Spacer(); Text(c.shortSHA).font(.system(.caption, design: .monospaced))
                            }.font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                if more, !commits.isEmpty { Button("Load More") { Task { await load() } } }
            } header: { Text("GitHub commits for this file") } footer: {
                Text("This is the shared history on GitHub. Your private edit history on this device is under Edit History.")
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
            if let error { Text(error).foregroundStyle(.red) }
            if !loading, commits.isEmpty, error == nil {
                ContentUnavailableView("No Commits Yet", systemImage: "clock", description: Text("This file has no commits on \(note.branch ?? "this branch") yet."))
            }
        }
        .navigationTitle("History")
        .toolbar { Button("Done") { dismiss() } }
        .task { await load() }
    }

    private func load() async {
        guard let o = note.repoOwner, let r = note.repoName, let b = note.branch, let p = note.path else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let next = try await app.client.commits(owner: o, name: r, branch: b, path: p, page: page)
            commits += next; more = next.count == 30; page += 1
        } catch { app.report(error); self.error = AppModel.message(for: error) }
    }
}

struct CommitVersionView: View {
    let note: Note
    let commit: GHCommitSummary
    @Environment(AppModel.self) private var app
    @Environment(SyncService.self) private var sync
    @State private var content: String?
    @State private var error: String?
    @State private var confirm = false
    @State private var restored = false

    var body: some View {
        VStack {
            if let content {
                let lines = LineDiff.diff(old: content, new: note.body)
                Text("Changes from this version to your current note: \(LineDiff.summary(lines).description)")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                DiffView(lines: lines)
            } else if let error { Text(error).foregroundStyle(.red).padding() } else { ProgressView() }
        }
        .navigationTitle(commit.shortSHA)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Restore…") { confirm = true }.disabled(content == nil || note.readOnly || note.hasPendingChanges)
        }
        .confirmationDialog("Restore this version?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Restore and Commit") { Task { await restore() } }
        } message: {
            Text("This replaces the note with the version from \(commit.shortSHA) and creates a new commit. History is not rewritten.")
        }
        .alert("Restored", isPresented: $restored) { Button("OK", role: .cancel) {} } message: { Text("A new commit was created with the restored content.") }
        .task {
            guard let o = note.repoOwner, let r = note.repoName, let p = note.path else { return }
            do {
                let f = try await app.client.file(owner: o, name: r, path: p, ref: commit.sha)
                content = f.text ?? ""
            } catch { self.error = AppModel.message(for: error) }
        }
    }

    private func restore() async {
        guard let content else { return }
        sync.snapshot(note, reason: "before restore")
        note.body = content
        let ok = await sync.sync(note, message: "Restore \((note.path ?? "file")) to \(commit.shortSHA)")
        if ok { restored = true } else { error = note.lastSyncError }
    }
}

// MARK: Commit / pending changes

struct CommitView: View {
    let notes: [Note]
    @Environment(SyncService.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var working = false
    @State private var results: [UUID: Bool] = [:]

    var body: some View {
        Form {
            Section("Commit Message") {
                TextField("Describe your changes", text: $message, axis: .vertical).lineLimit(1...4)
            }
            ForEach(notes) { n in
                Section {
                    DiffView(lines: LineDiff.collapse(LineDiff.diff(old: n.baseContent ?? "", new: n.body)))
                        .frame(height: 180)
                } header: { Text(n.path ?? n.title) } footer: {
                    if let r = results[n.id] { Text(r ? "Committed" : (n.lastSyncError ?? "Failed")).foregroundStyle(r ? .green : .red) }
                    else { Text("\(n.repoFullName ?? "") · \(n.branch ?? "")") }
                }
            }
            Section { Text("Each file is committed separately using the Contents API. Nothing is marked as committed until GitHub confirms it.").font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("Commit Changes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if working { ProgressView() } else {
                    Button("Commit") { Task { await commit() } }.disabled(message.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear { if message.isEmpty, let n = notes.first { message = Prefs.commitMessage(for: n) } }
    }

    private func commit() async {
        working = true
        for n in notes { results[n.id] = await sync.sync(n, message: message) }
        working = false
        if results.values.allSatisfy({ $0 }) { dismiss() }
    }
}

struct PendingChangesView: View {
    @Environment(SyncService.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var items: [Note] = []
    @State private var committing = false

    var body: some View {
        List {
            if items.isEmpty {
                ContentUnavailableView("All Caught Up", systemImage: "checkmark.circle", description: Text("No repository notes have pending changes."))
            }
            ForEach(items) { n in
                HStack {
                    Image(systemName: icon(n)).foregroundStyle(color(n))
                    VStack(alignment: .leading) {
                        Text(n.path ?? n.title)
                        Text("\(label(n)) · \(n.repoFullName ?? "")").font(.caption).foregroundStyle(.secondary)
                        if let e = n.lastSyncError { Text(e).font(.caption).foregroundStyle(.red) }
                    }
                }
            }
        }
        .navigationTitle("Pending Changes")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) { Button("Sync Now") { Task { await sync.syncAll(); items = sync.pendingNotes() } } }
            ToolbarItem(placement: .bottomBar) {
                Button("Review & Commit…") { committing = true }.disabled(items.filter(\.hasPendingChanges).isEmpty)
            }
        }
        .sheet(isPresented: $committing, onDismiss: { items = sync.pendingNotes() }) {
            NavigationStack { CommitView(notes: items.filter(\.hasPendingChanges)) }
        }
        .onAppear { items = sync.pendingNotes() }
    }
    private func label(_ n: Note) -> String {
        switch n.syncStatus { case .newFile: "Added"; case .modified: "Modified"; case .conflict: "Conflict"; case .remoteDeleted: "Deleted on GitHub"; default: "" }
    }
    private func icon(_ n: Note) -> String {
        switch n.syncStatus { case .newFile: "plus.circle"; case .modified: "pencil.circle"; default: "exclamationmark.triangle" }
    }
    private func color(_ n: Note) -> Color {
        switch n.syncStatus { case .newFile: .green; case .modified: .orange; default: .red }
    }
}

// MARK: Conflict resolution

struct ConflictView: View {
    @Bindable var note: Note
    @Environment(SyncService.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var manual = ""
    @State private var confirmDiscard = false
    @State private var working = false

    private var base: String { note.baseContent ?? "" }
    private var remote: String { note.conflictRemoteContent ?? "" }
    private var merge: MergeResult { ThreeWayMerge.merge(base: base, local: note.body, remote: remote) }

    var body: some View {
        VStack(spacing: 12) {
            Text("Someone changed \(note.path ?? "this file") on GitHub while you were editing it. Both versions are kept. Choose how to combine them; a recovery copy of your edits is saved under Edit History.")
                .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal)
            Picker("View", selection: $mode) {
                Text("Yours").tag(0); Text("GitHub").tag(1); Text("Merge").tag(2)
            }.pickerStyle(.segmented).padding(.horizontal)
            switch mode {
            case 0: DiffView(lines: LineDiff.diff(old: base, new: note.body))
            case 1: DiffView(lines: LineDiff.diff(old: base, new: remote))
            default:
                TextEditor(text: $manual).font(.system(.footnote, design: .monospaced)).padding(.horizontal, 8)
                Text("Remove the <<<<<<<, =======, >>>>>>> markers and keep the lines you want.").font(.caption).foregroundStyle(.secondary)
            }
            if working { ProgressView() }
        }
        .navigationTitle("Resolve Conflict")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } }
            ToolbarItem(placement: .bottomBar) {
                HStack {
                    Button("Keep Mine") { Task { working = true; await sync.resolveKeepLocal(note); working = false; dismiss() } }
                    Spacer()
                    Button("Use GitHub's", role: .destructive) { confirmDiscard = true }
                    Spacer()
                    Button("Save Merge") { Task { working = true; await sync.resolveManual(note, text: manual); working = false; dismiss() } }
                        .disabled(manual.contains("<<<<<<<") || manual.contains(">>>>>>>"))
                }
            }
        }
        .confirmationDialog("Discard your edits?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard My Edits, Use GitHub's Version", role: .destructive) { sync.resolveAcceptRemote(note); dismiss() }
        } message: { Text("Your version stays recoverable in Edit History.") }
        .onAppear { manual = merge.textWithMarkers() }
    }
}

// MARK: Local history

struct LocalHistoryView: View {
    let note: Note
    @Environment(SyncService.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var pick: LocalRevision?

    var body: some View {
        List {
            Section {
                ForEach(sync.revisions(for: note)) { r in
                    NavigationLink { RevisionView(note: note, revision: r) } label: {
                        VStack(alignment: .leading) {
                            Text(r.createdAt, format: .dateTime.month().day().hour().minute())
                            Text(r.reason.capitalized).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text("Edit history on this device") } footer: {
                Text("Local revisions are private and separate from GitHub commits.")
            }
        }
        .navigationTitle("Edit History")
        .toolbar { Button("Done") { dismiss() } }
    }
}

struct RevisionView: View {
    let note: Note
    let revision: LocalRevision
    @Environment(SyncService.self) private var sync
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        DiffView(lines: LineDiff.diff(old: revision.body, new: note.body))
            .navigationTitle("Compared to Now")
            .toolbar {
                Button("Restore") {
                    sync.snapshot(note, reason: "before restore")
                    note.body = revision.body; sync.noteEdited(note); dismiss()
                }
            }
    }
}

// MARK: Link / move / details

struct LinkNoteView: View {
    let note: Note
    @Environment(SyncService.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @Query private var connections: [RepoConnection]
    @State private var selected: RepoConnection?
    @State private var path = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Picker("Repository", selection: $selected) {
                    Text("Choose…").tag(RepoConnection?.none)
                    ForEach(connections.filter(\.canPush)) { Text($0.fullName).tag(RepoConnection?.some($0)) }
                }
                TextField("Path, e.g. notes/ideas.md", text: $path).textInputAutocapitalization(.never).autocorrectionDisabled()
            } footer: {
                Text("Linking does not publish anything. The file is created on \(selected?.currentBranch ?? "the branch") only when you commit. Add repositories from the Repositories tab.")
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Link to GitHub")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Link") {
                    guard let c = selected else { return }
                    do { try sync.link(note, conn: c, path: path); dismiss() } catch { self.error = AppModel.message(for: error) }
                }.disabled(selected == nil || path.isEmpty)
            }
        }
    }
}

struct MoveFileView: View {
    let note: Note
    @Environment(SyncService.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var error: String?
    @State private var working = false
    var body: some View {
        Form {
            Section { TextField("New path", text: $path).textInputAutocapitalization(.never).autocorrectionDisabled() }
                footer: { Text("GitHub has no rename operation, so this creates the file at the new path and deletes the old one (two commits). Commit pending edits first.") }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Rename or Move")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if working { ProgressView() } else {
                    Button("Move") { Task {
                        working = true; defer { working = false }
                        do { try await sync.move(note, to: path); dismiss() } catch { self.error = AppModel.message(for: error) }
                    } }.disabled(path.isEmpty || path == note.path)
                }
            }
        }
        .onAppear { path = note.path ?? "" }
    }
}

struct RepoDetailsSheet: View {
    let note: Note
    @Environment(SyncService.self) private var sync
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var branches: [GHBranch] = []
    @State private var error: String?

    var body: some View {
        Form {
            Section("This note represents") {
                LabeledContent("Repository", value: note.repoFullName ?? "—")
                LabeledContent("File", value: note.path ?? "—")
                LabeledContent("Branch", value: note.branch ?? "—")
                LabeledContent("Last commit", value: note.lastCommitSHA.map { String($0.prefix(7)) } ?? "—")
                if let d = note.lastSyncedAt { LabeledContent("Last synced") { Text(d, format: .relative(presentation: .named)) } }
                if note.readOnly { Label("Read-only: you can't push to this repository.", systemImage: "lock") }
            }
            Section("Branch") {
                Picker("Switch Branch", selection: .init(get: { note.branch ?? "" }, set: { b in Task { await switchBranch(b) } })) {
                    ForEach(branches) { Text($0.name).tag($0.name) }
                }
            }
            if note.syncStatus == .remoteDeleted {
                Section {
                    Text("This file no longer exists on \(note.branch ?? "this branch"). Your content is safe on this device.")
                    Button("Recreate on GitHub") { Task { await sync.recreateRemote(note); dismiss() } }
                    Button("Keep as Local Note") { sync.detach(note); dismiss() }
                }
            } else {
                Section { Button("Disconnect from GitHub (keep local copy)", role: .destructive) { sync.detach(note); dismiss() } }
                    footer: { Text("This only unlinks the note. The file on GitHub is not changed or deleted.") }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Repository")
        .toolbar { Button("Done") { dismiss() } }
        .task {
            guard let o = note.repoOwner, let r = note.repoName else { return }
            branches = (try? await app.client.branches(owner: o, name: r)) ?? []
        }
    }

    private func switchBranch(_ b: String) async {
        do { try await sync.reload(note, branch: b); error = nil } catch { self.error = AppModel.message(for: error) }
    }
}
