import SwiftUI
import SwiftData
import NotesCore

struct RepositoriesView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \RepoConnection.name) private var repos: [RepoConnection]
    @State private var adding = false

    var body: some View {
        List {
            if !app.isSignedIn {
                ContentUnavailableView {
                    Label("Not Connected to GitHub", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text("Sign in from Settings to browse repositories. Local notes keep working without an account.")
                }
            } else if repos.isEmpty {
                ContentUnavailableView {
                    Label("No Repositories", systemImage: "externaldrive")
                } description: { Text("Add a repository to use it as a notes workspace or open its Markdown files as notes.") }
                actions: { Button("Add Repository") { adding = true }.buttonStyle(.borderedProminent) }
            }
            ForEach(repos) { r in
                NavigationLink { RepoDetailView(repo: r) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { Text(r.fullName).font(.headline); Image(systemName: r.isPrivate ? "lock" : "globe").font(.caption).foregroundStyle(.secondary) }
                        Text("\(r.currentBranch)\(r.canPush ? "" : " · read-only")").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Repositories")
        .toolbar { Button { adding = true } label: { Image(systemName: "plus") }.disabled(!app.isSignedIn).accessibilityLabel("Add Repository") }
        .sheet(isPresented: $adding) { NavigationStack { RepoPickerView() } }
    }
}

struct RepoPickerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var existing: [RepoConnection]
    @State private var repos: [GHRepo] = []
    @State private var search = ""
    @State private var urlText = ""
    @State private var loading = true
    @State private var error: String?
    @State private var creating = false

    private var filtered: [GHRepo] { search.isEmpty ? repos : repos.filter { $0.fullName.localizedCaseInsensitiveContains(search) } }

    var body: some View {
        List {
            Section {
                TextField("owner/name or github.com URL", text: $urlText).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Add by URL") { Task { await addByURL() } }.disabled(urlText.isEmpty)
            } header: { Text("Enter a repository") } footer: {
                Text("Access follows your GitHub permissions. Private repositories need the “private” sign-in option.")
            }
            Section { Button("Create a New Repository…", systemImage: "plus.rectangle.on.folder") { creating = true } }
            Section("Your repositories") {
                if loading { ProgressView() }
                ForEach(filtered) { r in
                    Button { add(r) } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(r.fullName).foregroundStyle(.primary)
                                Text(r.canPush ? "Read & write" : "Read-only").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: r.private ? "lock" : "globe").foregroundStyle(.secondary)
                            if existing.contains(where: { $0.repoID == r.id }) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .searchable(text: $search)
        .navigationTitle("Add Repository")
        .toolbar { Button("Done") { dismiss() } }
        .sheet(isPresented: $creating) { NavigationStack { CreateRepoView { add($0); creating = false } } }
        .task { await load() }
    }

    private func load() async {
        do { repos = try await app.client.listRepositories() } catch { app.report(error); self.error = AppModel.message(for: error) }
        loading = false
    }

    private func addByURL() async {
        guard let p = RepoPath.parseRepository(urlText) else { error = "That doesn't look like a GitHub repository. Use owner/name."; return }
        do { add(try await app.client.repository(owner: p.owner, name: p.name)) }
        catch { self.error = (error as? GitHubError) == .notFound ? "Repository not found, or it's private and you haven't granted private access." : AppModel.message(for: error) }
    }

    private func add(_ r: GHRepo) {
        guard !existing.contains(where: { $0.repoID == r.id }) else { dismiss(); return }
        context.insert(RepoConnection(repo: r)); try? context.save(); dismiss()
    }
}

struct CreateRepoView: View {
    var created: (GHRepo) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = "notes"
    @State private var desc = ""
    @State private var isPrivate = true
    @State private var confirm = false
    @State private var error: String?
    @State private var working = false

    var body: some View {
        Form {
            Section { TextField("Repository name", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled(); TextField("Description (optional)", text: $desc) }
            Section {
                Picker("Visibility", selection: $isPrivate) { Text("Private").tag(true); Text("Public").tag(false) }.pickerStyle(.segmented)
            } footer: {
                Text(isPrivate ? "Only you (and people you invite) can see it. Requires private-repository access." : "Anyone on the internet can see everything you commit here.")
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("New Repository")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { if working { ProgressView() } else { Button("Create") { confirm = true }.disabled(name.isEmpty) } }
        }
        .confirmationDialog("Create \(isPrivate ? "private" : "public") repository “\(name)”?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Create on GitHub") { Task {
                working = true; defer { working = false }
                do { created(try await app.client.createRepository(name: name, description: desc.isEmpty ? nil : desc, isPrivate: isPrivate)) }
                catch { self.error = AppModel.message(for: error) }
            } }
        } message: { Text("This creates a new repository on your GitHub account. No notes are uploaded until you commit them.") }
    }
}

struct RepoDetailView: View {
    @Bindable var repo: RepoConnection
    @Environment(AppModel.self) private var app
    @Environment(SyncService.self) private var sync
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var notes: [Note]
    @State private var branches: [GHBranch] = []
    @State private var path = ""
    @State private var items: [GHContentItem] = []
    @State private var loading = false
    @State private var error: String?
    @State private var opened: Note?
    @State private var newFileName = ""
    @State private var showNewFile = false
    @State private var newBranchName = ""
    @State private var showNewBranch = false
    @State private var confirmRemove = false

    private var tracked: [Note] { notes.filter { $0.repoFullName == repo.fullName && $0.deletedAt == nil } }

    var body: some View {
        List {
            Section {
                if let d = repo.repoDescription { Text(d) }
                LabeledContent("Visibility", value: repo.isPrivate ? "Private" : "Public")
                LabeledContent("Default branch", value: repo.defaultBranch)
                LabeledContent("Access", value: repo.canPush ? "Read & write" : "Read-only")
                if let d = repo.lastFetchedAt { LabeledContent("Last fetched") { Text(d, format: .relative(presentation: .named)) } }
                Picker("Branch", selection: $repo.currentBranch) { ForEach(branchNames, id: \.self) { Text($0).tag($0) } }
                if repo.canPush { Button("New Branch…", systemImage: "arrow.triangle.branch") { showNewBranch = true } }
            }
            Section("Tracked notes (\(tracked.count))") {
                ForEach(tracked) { n in NavigationLink(n.path ?? n.title) { NoteEditorView(note: n) } }
            }
            Section {
                if !path.isEmpty { Button("‹ \((path as NSString).deletingLastPathComponent.isEmpty ? "Repository root" : (path as NSString).deletingLastPathComponent)") { path = (path as NSString).deletingLastPathComponent } }
                if loading { ProgressView() }
                ForEach(items.filter { !excluded($0.path) }) { item in
                    Button { tap(item) } label: { fileRow(item) }.disabled(!item.isDirectory && !(item.isRegularFile && RepoPath.isNote(item.path)))
                }
                if !loading, items.isEmpty, error == nil {
                    ContentUnavailableView("Empty Folder", systemImage: "folder", description: Text("This directory has no files on \(repo.currentBranch)."))
                }
            } header: { Text("/" + path) }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section {
                NavigationLink("Recent Commits") { RepoCommitsView(repo: repo) }
                NavigationLink("Repository Settings") { RepoSettingsView(repo: repo, confirmRemove: $confirmRemove) }
            }
        }
        .navigationTitle(repo.name)
        .navigationDestination(item: $opened) { NoteEditorView(note: $0) }
        .toolbar {
            if repo.canPush { Button { showNewFile = true } label: { Image(systemName: "doc.badge.plus") }.accessibilityLabel("New File") }
        }
        .refreshable { await load(force: true) }
        .task(id: "\(repo.currentBranch)|\(path)") { await load() }
        .task { await loadBranches() }
        .alert("New File", isPresented: $showNewFile) {
            TextField("name.md", text: $newFileName).textInputAutocapitalization(.never)
            Button("Create") { createFile() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Created in /\(path.isEmpty ? repo.defaultDirectory : path). It's added to GitHub when you commit.") }
        .alert("New Branch", isPresented: $showNewBranch) {
            TextField("branch-name", text: $newBranchName).textInputAutocapitalization(.never)
            Button("Create") { Task { await createBranch() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Branches from \(repo.currentBranch).") }
        .confirmationDialog("Remove this repository connection?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Connection, Keep Notes", role: .destructive) {
                for n in tracked { sync.detach(n) }
                context.delete(repo); try? context.save(); dismiss()
            }
        } message: { Text("Notes from this repository become local notes with their content intact. Nothing on GitHub is changed or deleted.") }
    }

    private var branchNames: [String] { Array(Set(branches.map(\.name) + [repo.currentBranch, repo.defaultBranch])).sorted() }
    private func excluded(_ p: String) -> Bool { repo.excludedPaths.contains { p == $0 || p.hasPrefix($0 + "/") } }

    private func fileRow(_ item: GHContentItem) -> some View {
        HStack {
            Image(systemName: item.isDirectory ? "folder" : RepoPath.isNote(item.path) ? "doc.text" : item.type == "symlink" ? "link" : "doc")
                .foregroundStyle(item.isDirectory || RepoPath.isNote(item.path) ? Color.accentColor : .secondary)
            VStack(alignment: .leading) {
                Text(item.name).foregroundStyle(.primary)
                if !item.isDirectory && !RepoPath.isNote(item.path) { Text(item.type == "file" ? "Unsupported format" : "Not supported").font(.caption).foregroundStyle(.secondary) }
                else if item.size > RepoPath.maxNoteBytes { Text("Too large to open").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func tap(_ item: GHContentItem) {
        if item.isDirectory { path = item.path; return }
        Task {
            do {
                opened = try await sync.open(owner: repo.owner, repo: nil, name: repo.name, path: item.path, branch: repo.currentBranch,
                                             mode: .workspace, readOnly: !repo.canPush, repoID: repo.repoID)
            } catch { app.report(error); self.error = AppModel.message(for: error) }
        }
    }

    private func createFile() {
        let dir = path.isEmpty ? repo.defaultDirectory : path
        let full = dir.isEmpty ? newFileName : dir + "/" + newFileName
        do { opened = try sync.newFile(conn: repo, path: full) } catch { self.error = AppModel.message(for: error) }
        newFileName = ""
    }

    private func load(force: Bool = false) async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let list = try await app.client.contents(owner: repo.owner, name: repo.name, path: path, ref: repo.currentBranch)
            items = list.sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
            repo.lastFetchedAt = .now
        } catch GitHubError.notFound {
            items = []
            error = path.isEmpty ? "The branch “\(repo.currentBranch)” or repository wasn't found. Pick another branch." : "That folder no longer exists on this branch."
        } catch is CancellationError {
        } catch { app.report(error); self.error = AppModel.message(for: error) }
    }

    private func loadBranches() async {
        branches = (try? await app.client.branches(owner: repo.owner, name: repo.name)) ?? []
        if !branches.isEmpty, !branches.contains(where: { $0.name == repo.defaultBranch }), let first = branches.first {
            repo.defaultBranch = first.name // missing default branch: fall back to an existing one
            if !branches.contains(where: { $0.name == repo.currentBranch }) { repo.currentBranch = first.name }
        }
    }

    private func createBranch() async {
        do {
            try await app.client.createBranch(owner: repo.owner, name: repo.name, newBranch: newBranchName, from: repo.currentBranch)
            await loadBranches(); repo.currentBranch = newBranchName; newBranchName = ""
        } catch { self.error = AppModel.message(for: error) }
    }
}

struct RepoCommitsView: View {
    let repo: RepoConnection
    @Environment(AppModel.self) private var app
    @State private var commits: [GHCommitSummary] = []
    @State private var error: String?
    @State private var loading = true
    var body: some View {
        List {
            ForEach(commits) { c in
                NavigationLink { CommitFilesView(repo: repo, commit: c) } label: {
                    VStack(alignment: .leading) {
                        Text(c.headline).lineLimit(2)
                        Text("\(c.authorName) · \(c.shortSHA)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if loading { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Commits · \(repo.currentBranch)")
        .task {
            do { commits = try await app.client.commits(owner: repo.owner, name: repo.name, branch: repo.currentBranch, path: nil) }
            catch { self.error = AppModel.message(for: error) }
            loading = false
        }
    }
}

struct CommitFilesView: View {
    let repo: RepoConnection
    let commit: GHCommitSummary
    @Environment(AppModel.self) private var app
    @State private var detail: GHCommitDetail?
    @State private var error: String?
    var body: some View {
        List {
            Section { Text(commit.commit.message) }
            if let files = detail?.files {
                Section("Changed files") {
                    ForEach(files, id: \.filename) { f in
                        NavigationLink {
                            ScrollView { Text(f.patch ?? "No textual diff available (binary or too large).").font(.system(.footnote, design: .monospaced)).padding().textSelection(.enabled) }
                                .navigationTitle((f.filename as NSString).lastPathComponent)
                        } label: {
                            VStack(alignment: .leading) { Text(f.filename); Text("\(f.status) · +\(f.additions) −\(f.deletions)").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle(commit.shortSHA)
        .task {
            do { detail = try await app.client.commitDetail(owner: repo.owner, name: repo.name, sha: commit.sha) }
            catch { self.error = AppModel.message(for: error) }
        }
    }
}

struct RepoSettingsView: View {
    @Bindable var repo: RepoConnection
    @Binding var confirmRemove: Bool
    @State private var newExcluded = ""
    var body: some View {
        Form {
            Section { TextField("e.g. notes", text: $repo.defaultDirectory).textInputAutocapitalization(.never).autocorrectionDisabled() }
                header: { Text("Default directory for new files") }
            Section {
                ForEach(repo.excludedPaths, id: \.self) { Text($0) }.onDelete { repo.excludedPaths.remove(atOffsets: $0) }
                HStack {
                    TextField("path/to/exclude", text: $newExcluded).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Add") {
                        if let p = try? RepoPath.validate(newExcluded) { repo.excludedPaths.append(p) }
                        newExcluded = ""
                    }.disabled(newExcluded.isEmpty)
                }
            } header: { Text("Excluded paths") } footer: { Text("Excluded files are hidden from the browser.") }
            Section {
                Button("Remove Repository Connection", role: .destructive) { confirmRemove = true }
            } footer: {
                Text("Removing a connection unlinks notes locally. It never deletes files or the repository on GitHub. Deleting a file on GitHub is a separate, explicit action in a note's menu. Deleting a whole repository can only be done on github.com.")
            }
        }
        .navigationTitle("Repository Settings")
    }
}
