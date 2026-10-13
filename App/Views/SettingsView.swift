import SwiftUI
import SwiftData
import NotesCore

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query private var notes: [Note]
    @Query private var revisions: [LocalRevision]
    @Query private var folders: [Folder]
    @AppStorage(Prefs.autoSyncKey) private var autoSync = false
    @AppStorage(Prefs.templateKey) private var template = ""
    @AppStorage("monospacedEditor") private var mono = false
    @AppStorage("showCounts") private var counts = false
    @AppStorage("privateAccess") private var privateAccess = true
    @AppStorage("appearance") private var appearance = 0
    @State private var confirmSignOut = false
    @State private var confirmWipe = false
    @State private var backupURL: URL?

    var body: some View {
        Form {
            Section {
                if app.isSignedIn {
                    LabeledContent("Account", value: app.user.map { "@\($0.login)" } ?? "Signed in")
                    Button("Sign Out", role: .destructive) { confirmSignOut = true }
                } else if app.isSigningIn, let code = app.deviceCode {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Enter this code on GitHub").font(.subheadline)
                        Text(code.userCode).font(.system(.title, design: .monospaced).bold()).textSelection(.enabled)
                        Text("Copied to clipboard. Waiting for you to approve…").font(.footnote).foregroundStyle(.secondary)
                        Link("Open github.com/login/device", destination: code.verificationURI)
                        Button("Cancel", role: .cancel) { app.cancelSignIn() }
                    }
                } else if app.isSigningIn {
                    ProgressView()
                } else {
                    Toggle("Allow private repositories", isOn: $privateAccess)
                    Button("Sign in with GitHub") { app.signIn(privateAccess: privateAccess) }
                }
                if let e = app.signInError { Text(e).foregroundStyle(.red).font(.footnote) }
            } header: { Text("GitHub") } footer: {
                Text(privateAccess
                     ? "Requests the “repo” permission, which GitHub grants as full access to repositories you can access; there is no narrower option for private repositories. Notes: only reads and writes the files you open."
                     : "Requests “public_repo”: access to public repositories only.")
            }

            Section {
                Toggle("Sync automatically", isOn: $autoSync)
                TextField("Commit message template", text: $template, prompt: Text(Prefs.defaultTemplate))
            } header: { Text("Sync") } footer: {
                Text("Automatic sync commits after you stop typing, when online. iOS doesn't allow guaranteed background sync, so pending changes upload when the app is open. Placeholders: {{file}} {{title}} {{date}}.")
            }

            Section("Editor") {
                Toggle("Monospaced font", isOn: $mono)
                Toggle("Show word count", isOn: $counts)
                Picker("Appearance", selection: $appearance) { Text("System").tag(0); Text("Light").tag(1); Text("Dark").tag(2) }
            }

            Section {
                if let url = backupURL { ShareLink(item: url) { Label("Share Backup (ZIP)", systemImage: "square.and.arrow.up") } }
                Button("Create Backup…", systemImage: "archivebox") { backupURL = makeBackup() }
                LabeledContent("Notes", value: "\(notes.count)")
                LabeledContent("Edit revisions", value: "\(revisions.count)")
                LabeledContent("Size on device", value: ByteCountFormatter.string(fromByteCount: Int64(notes.reduce(0) { $0 + $1.body.utf8.count + ($1.baseContent?.utf8.count ?? 0) }), countStyle: .file))
            } header: { Text("Backup & Storage") } footer: {
                Text("A backup is a ZIP of every note as a Markdown file, organized by folder or repository path. It includes unsynced edits. It does not include your GitHub credentials.")
            }

            Section {
                Button("Delete All Local Data…", role: .destructive) { confirmWipe = true }
            } header: { Text("Privacy & Security") } footer: {
                Text("Credentials are stored in the iOS Keychain. Note contents are never logged or sent anywhere except GitHub files you choose to commit. Local-only notes are never uploaded.")
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                Text("Notes: — Apple Notes meets GitHub.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Sign out of GitHub?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { app.signOut() }
        } message: {
            Text("Your notes and unsynced edits stay on this device. Nothing on GitHub is changed. To revoke the app's access entirely, visit github.com/settings/applications.")
        }
        .confirmationDialog("Delete all local data?", isPresented: $confirmWipe, titleVisibility: .visible) {
            Button("Delete Everything on This Device", role: .destructive) { wipe() }
        } message: {
            Text("Deletes all notes, folders, history and repository connections from this device, including unsynced edits. Create a backup first. GitHub is not affected.")
        }
    }

    private func makeBackup() -> URL? {
        var zip = ZipWriter()
        var used = Set<String>()
        let folderNames = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.name) })
        for n in notes where n.deletedAt == nil {
            let dir = n.repoFullName.map { "repositories/\($0)" } ?? "notes/" + (n.folderID.flatMap { folderNames[$0] } ?? "Unfiled")
            var name = n.path ?? (String(n.title.prefix(60)).replacingOccurrences(of: "/", with: "-") + ".md")
            var full = "\(dir)/\(name)"
            var i = 2
            while used.contains(full) { name = "\(i)-" + ((name as NSString).lastPathComponent); full = "\(dir)/\(name)"; i += 1 }
            used.insert(full)
            zip.add(path: full, data: Data(n.body.utf8))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Notes-Backup-\(Int(Date().timeIntervalSince1970)).zip")
        return (try? zip.finish().write(to: url, options: .atomic)) != nil ? url : nil
    }

    private func wipe() {
        try? context.delete(model: Note.self); try? context.delete(model: Folder.self)
        try? context.delete(model: LocalRevision.self); try? context.delete(model: RepoConnection.self)
        try? context.save()
    }
}
