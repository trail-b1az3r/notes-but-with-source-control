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
    @AppStorage("appearance") private var appearance = 0
    @State private var confirmWipe = false
    @State private var backupURL: URL?

    var body: some View {
        @Bindable var app = app
        List {
            Section {
                GitHubConnectView()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                Toggle(isOn: $autoSync) { SettingsLabel("Sync automatically", "arrow.triangle.2.circlepath", .green) }
                NavigationLink { CommitTemplateView(template: $template) } label: {
                    SettingsLabel("Commit message", "text.bubble", .blue)
                }
            } header: { Text("Sync") } footer: {
                Text(autoSync
                     ? "Edits are committed to GitHub shortly after you stop typing, when you're online."
                     : "Edits stay on this device until you commit them from a note's menu or Pending Changes.")
            }

            Section("Editor") {
                Toggle(isOn: $mono) { SettingsLabel("Monospaced font", "textformat", .orange) }
                Toggle(isOn: $counts) { SettingsLabel("Word count", "number", .teal) }
                Picker(selection: $appearance) {
                    Text("System").tag(0); Text("Light").tag(1); Text("Dark").tag(2)
                } label: { SettingsLabel("Appearance", "circle.lefthalf.filled", .indigo) }
            }

            Section {
                Button { backupURL = makeBackup() } label: { SettingsLabel("Create Backup", "archivebox", .brown) }
                    .foregroundStyle(.primary)
                if let url = backupURL {
                    ShareLink(item: url) { Label("Share Backup (ZIP)", systemImage: "square.and.arrow.up") }
                }
                LabeledContent("Notes", value: "\(notes.count)")
                LabeledContent("Edit revisions", value: "\(revisions.count)")
                LabeledContent("Size on device", value: ByteCountFormatter.string(fromByteCount: Int64(notes.reduce(0) { $0 + $1.body.utf8.count + ($1.baseContent?.utf8.count ?? 0) }), countStyle: .file))
            } header: { Text("Backup & Storage") } footer: {
                Text("A backup is a ZIP of every note as a Markdown file, organized by folder or repository. It includes unsynced edits and never your GitHub credentials.")
            }

            Section {
                DisclosureGroup {
                    TextField(app.bundledClientID.isEmpty ? "Client ID" : "Using build default", text: $app.customClientID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))
                    Text("Overrides the Client ID built into the app. Leave empty to use the default.")
                        .font(.caption).foregroundStyle(.secondary)
                } label: { SettingsLabel("GitHub Client ID", "key.horizontal", .gray) }
                Button(role: .destructive) { confirmWipe = true } label: { SettingsLabel("Delete All Local Data", "trash", .red) }
                    .foregroundStyle(.red)
            } header: { Text("Advanced") } footer: {
                Text("Credentials live in the iOS Keychain. Note contents are never logged and only leave your device when you commit them to GitHub. Local-only notes are never uploaded.")
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
            }
        }
        .navigationTitle("Settings")
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nbwsc-backup-\(Int(Date().timeIntervalSince1970)).zip")
        return (try? zip.finish().write(to: url, options: .atomic)) != nil ? url : nil
    }

    private func wipe() {
        try? context.delete(model: Note.self); try? context.delete(model: Folder.self)
        try? context.delete(model: LocalRevision.self); try? context.delete(model: RepoConnection.self)
        try? context.save()
    }
}

struct CommitTemplateView: View {
    @Binding var template: String
    var body: some View {
        Form {
            Section {
                TextField(Prefs.defaultTemplate, text: $template).textInputAutocapitalization(.never)
            } header: { Text("Template") } footer: {
                Text("Used when a commit message isn't typed by hand.")
            }
            Section("Placeholders") {
                LabeledContent("{{file}}", value: "File name")
                LabeledContent("{{title}}", value: "Note title")
                LabeledContent("{{date}}", value: "Date and time")
            }
            Section("Example") {
                Text((template.isEmpty ? Prefs.defaultTemplate : template)
                    .replacingOccurrences(of: "{{file}}", with: "ideas.md")
                    .replacingOccurrences(of: "{{title}}", with: "Ideas")
                    .replacingOccurrences(of: "{{date}}", with: Date.now.formatted(date: .abbreviated, time: .shortened)))
                    .foregroundStyle(.secondary)
            }
            if !template.isEmpty { Section { Button("Reset to Default", role: .destructive) { template = "" } } }
        }
        .navigationTitle("Commit Message")
        .navigationBarTitleDisplayMode(.inline)
    }
}
