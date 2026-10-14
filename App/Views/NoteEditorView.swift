import SwiftUI
import SwiftData
import NotesCore

struct NoteEditorView: View {
    @Bindable var note: Note
    @Environment(SyncService.self) private var sync
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @StateObject private var controller = EditorController()
    @AppStorage("monospacedEditor") private var mono = false
    @AppStorage("showCounts") private var showCounts = false
    @State private var preview = false
    @State private var sheet: Sheet?
    @State private var errorText: String?
    @State private var confirmDeleteRemote = false

    enum Sheet: String, Identifiable {
        case history, commit, conflict, link, move, localHistory, details
        var id: String { rawValue }
    }

    private var isMarkdown: Bool { note.path.map { $0.lowercased().hasSuffix(".txt") ? false : true } ?? true }

    var body: some View {
        VStack(spacing: 0) {
            banner
            if preview && isMarkdown {
                MarkdownPreview(source: note.body) { toggleCheckbox(line: $0) }
            } else {
                EditorTextView(text: $note.body, monospaced: mono || !isMarkdown, controller: controller) { sync.noteEdited(note) }
            }
            if showCounts { counts }
        }
        .navigationTitle(note.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button(preview ? "Edit" : "Read") { preview.toggle() }.disabled(!isMarkdown) }
            ToolbarItem(placement: .topBarTrailing) { menu }
            ToolbarItemGroup(placement: .keyboard) {
                Button { controller.undo() } label: { Image(systemName: "arrow.uturn.backward") }.accessibilityLabel("Undo")
                Button { controller.redo() } label: { Image(systemName: "arrow.uturn.forward") }.accessibilityLabel("Redo")
                Spacer()
                Button { controller.prefixLines("# ") } label: { Image(systemName: "textformat.size") }.accessibilityLabel("Heading")
                Button { controller.wrap("**") } label: { Image(systemName: "bold") }.accessibilityLabel("Bold")
                Button { controller.wrap("*") } label: { Image(systemName: "italic") }.accessibilityLabel("Italic")
                Button { controller.wrap("~~") } label: { Image(systemName: "strikethrough") }.accessibilityLabel("Strikethrough")
                Button { controller.prefixLines("- ") } label: { Image(systemName: "list.bullet") }.accessibilityLabel("Bulleted list")
                Button { controller.prefixLines("1. ") } label: { Image(systemName: "list.number") }.accessibilityLabel("Numbered list")
                Button { controller.prefixLines("- [ ] ") } label: { Image(systemName: "checklist") }.accessibilityLabel("Checklist")
                Button { controller.prefixLines("> ") } label: { Image(systemName: "text.quote") }.accessibilityLabel("Quote")
                Button { controller.codeBlock() } label: { Image(systemName: "chevron.left.forwardslash.chevron.right") }.accessibilityLabel("Code block")
                Button { controller.link() } label: { Image(systemName: "link") }.accessibilityLabel("Link")
                Button { controller.dismissKeyboard() } label: { Image(systemName: "keyboard.chevron.compact.down") }.accessibilityLabel("Dismiss keyboard")
            }
        }
        .sheet(item: $sheet) { s in
            NavigationStack {
                switch s {
                case .history: HistoryView(note: note)
                case .commit: CommitView(notes: [note])
                case .conflict: ConflictView(note: note)
                case .link: LinkNoteView(note: note)
                case .move: MoveFileView(note: note)
                case .localHistory: LocalHistoryView(note: note)
                case .details: RepoDetailsSheet(note: note)
                }
            }
        }
        .alert("Couldn't complete that", isPresented: .init(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
        .confirmationDialog("Delete this file from GitHub?", isPresented: $confirmDeleteRemote, titleVisibility: .visible) {
            Button("Delete File on GitHub", role: .destructive) {
                Task { do { try await sync.deleteRemote(note) } catch { errorText = AppModel.message(for: error) } }
            }
        } message: {
            Text("This creates a commit that deletes \(note.path ?? "the file") from \(note.branch ?? "the branch"). The note stays on this device as a local note.")
        }
        .onDisappear { try? context.save() }
    }

    // MARK: Status banner

    @ViewBuilder private var banner: some View {
        switch note.syncStatus {
        case .local: EmptyView()
        case .conflict:
            bannerRow("exclamationmark.triangle.fill", "Conflict with GitHub", .red) { sheet = .conflict } action: { "Resolve" }
        case .remoteDeleted:
            bannerRow("questionmark.folder", "File deleted on GitHub", .red) { sheet = .details } action: { "Options" }
        default:
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                Text("\(note.repoFullName ?? "") · \(note.branch ?? "")").lineLimit(1)
                Spacer()
                if sync.busy.contains(note.id) { ProgressView() }
                else if note.hasPendingChanges { Label("Pending", systemImage: "circle.fill").labelStyle(.titleAndIcon).foregroundStyle(.orange) }
                else { Label("Synced", systemImage: "checkmark").foregroundStyle(.secondary) }
            }
            .font(.caption).padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .padding(.horizontal).padding(.top, 4)
            .contentShape(Capsule())
            .onTapGesture { sheet = .details }
            if let e = note.lastSyncError {
                Text(e).font(.caption).foregroundStyle(.red).padding(.horizontal).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func bannerRow(_ icon: String, _ text: String, _ color: Color, tap: @escaping () -> Void, action: () -> String) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(color); Text(text).font(.subheadline)
            Spacer()
            Button(action(), action: tap).buttonStyle(.bordered).controlSize(.small)
        }.padding(.horizontal).padding(.vertical, 6).background(.bar)
    }

    private var counts: some View {
        let words = note.body.split { $0.isWhitespace || $0.isNewline }.count
        return Text("\(words) words · \(note.body.count) characters").font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding(6).background(.bar)
    }

    // MARK: Menu

    private var menu: some View {
        Menu {
            if !note.isLocal {
                Section("Source Control") {
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { Task { await sync.sync(note) } }
                    Button("Commit Changes…", systemImage: "checkmark.circle") { sheet = .commit }.disabled(!note.hasPendingChanges)
                    Button("GitHub History", systemImage: "clock.arrow.circlepath") { sheet = .history }
                    Button("Repository Details", systemImage: "info.circle") { sheet = .details }
                }
            } else {
                Button("Link to GitHub File…", systemImage: "link.badge.plus") { sheet = .link }
            }
            Button("Edit History (This Device)", systemImage: "clock") { sheet = .localHistory }
            Section {
                Button("Find in Note", systemImage: "magnifyingglass") { preview = false; controller.find() }
                Toggle("Monospaced Editor", isOn: $mono)
                Toggle("Word Count", isOn: $showCounts)
                ShareLink(item: exportURL) { Label("Export", systemImage: "square.and.arrow.up") }
            }
            if !note.isLocal {
                Section {
                    Button("Rename or Move File…", systemImage: "folder") { sheet = .move }
                    if let p = note.path, let u = githubURL(p) { Link(destination: u) { Label("Open on GitHub", systemImage: "safari") } }
                    Button("Delete File on GitHub…", systemImage: "trash", role: .destructive) { confirmDeleteRemote = true }
                }
            }
        } label: { Image(systemName: "ellipsis.circle") }
    }

    private func githubURL(_ path: String) -> URL? {
        guard let o = note.repoOwner, let r = note.repoName, let b = note.branch else { return nil }
        return URL(string: "https://github.com/\(o)/\(r)/blob/\(RepoPath.percentEncoded(b))/\(RepoPath.percentEncoded(path))")
    }

    private var exportURL: URL {
        let name = (note.path.map { ($0 as NSString).lastPathComponent }) ?? (String(note.title.prefix(60)).replacingOccurrences(of: "/", with: "-") + ".md")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? note.body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func toggleCheckbox(line: Int) {
        var lines = note.body.components(separatedBy: "\n")
        guard line < lines.count else { return }
        if let r = lines[line].range(of: "[ ]") { lines[line].replaceSubrange(r, with: "[x]") }
        else if let r = lines[line].range(of: "[x]", options: .caseInsensitive) { lines[line].replaceSubrange(r, with: "[ ]") }
        note.body = lines.joined(separator: "\n")
        sync.noteEdited(note)
    }
}
