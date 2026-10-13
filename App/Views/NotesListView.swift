import SwiftUI
import SwiftData
import UniformTypeIdentifiers

enum NoteFilter: Hashable {
    case all, pinned, repoLinked, pending, conflicts, trash
    case folder(UUID)
    case repo(String)

    var title: String {
        switch self {
        case .all: "All Notes"; case .pinned: "Pinned"; case .repoLinked: "Repository Notes"
        case .pending: "Pending Changes"; case .conflicts: "Conflicts"; case .trash: "Recently Deleted"
        case .folder: "Folder"; case .repo(let r): r
        }
    }
}

enum SortOrder: String, CaseIterable { case modified = "Date Edited", created = "Date Created", title = "Title" }

struct NotesListView: View {
    let filter: NoteFilter
    var titleOverride: String?
    @Environment(\.modelContext) private var context
    @Environment(SyncService.self) private var sync
    @Query private var allNotes: [Note]
    @AppStorage("sortOrder") private var sortRaw = SortOrder.modified.rawValue
    @AppStorage("showPreviews") private var showPreviews = true
    @State private var search = ""
    @State private var debounced = ""
    @State private var storageFilter: StorageMode?
    @State private var editing: Note?
    @State private var selection = Set<UUID>()
    @State private var editMode: EditMode = .inactive
    @State private var importing = false
    @State private var showPending = false

    private var order: SortOrder { SortOrder(rawValue: sortRaw) ?? .modified }

    private var notes: [Note] {
        var list = allNotes.filter { n in
            switch filter {
            case .trash: return n.deletedAt != nil
            default: if n.deletedAt != nil { return false }
            }
            switch filter {
            case .all, .trash: return true
            case .pinned: return n.isPinned
            case .repoLinked: return !n.isLocal
            case .pending: return n.hasPendingChanges
            case .conflicts: return n.syncStatus == .conflict
            case .folder(let id): return n.folderID == id
            case .repo(let r): return n.repoFullName == r
            }
        }
        if let m = storageFilter { list = list.filter { $0.mode == m } }
        if !debounced.isEmpty {
            list = list.filter {
                $0.body.localizedCaseInsensitiveContains(debounced) || ($0.path ?? "").localizedCaseInsensitiveContains(debounced)
                    || ($0.repoFullName ?? "").localizedCaseInsensitiveContains(debounced)
            }
        }
        switch order {
        case .modified: list.sort { $0.modifiedAt > $1.modifiedAt }
        case .created: list.sort { $0.createdAt > $1.createdAt }
        case .title: list.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        return list
    }

    var body: some View {
        let list = notes
        let pinned = list.filter(\.isPinned), rest = list.filter { !$0.isPinned }
        List(selection: $selection) {
            if list.isEmpty { emptyState }
            if !pinned.isEmpty, filter != .pinned {
                Section("Pinned") { ForEach(pinned) { row($0) } }
                Section("Notes") { ForEach(rest) { row($0) } }
            } else {
                ForEach(list) { row($0) }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, $editMode)
        .navigationTitle(titleOverride ?? filter.title)
        .searchable(text: $search, prompt: "Search notes, paths, repositories")
        .task(id: search) {
            try? await Task.sleep(nanoseconds: 200_000_000) // debounce
            if !Task.isCancelled { debounced = search }
        }
        .navigationDestination(item: $editing) { NoteEditorView(note: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort By", selection: $sortRaw) { ForEach(SortOrder.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) } }
                    Toggle("Show Previews", isOn: $showPreviews)
                    Picker("Storage", selection: $storageFilter) {
                        Text("All Notes").tag(StorageMode?.none)
                        Text("Local Only").tag(StorageMode?.some(.local))
                        Text("Linked File").tag(StorageMode?.some(.file))
                        Text("Workspace").tag(StorageMode?.some(.workspace))
                    }
                    Button("Import Markdown…", systemImage: "square.and.arrow.down") { importing = true }
                    Button("Pending Changes", systemImage: "arrow.triangle.2.circlepath") { showPending = true }
                } label: { Label("Options", systemImage: "ellipsis.circle") }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if editMode.isEditing {
                    Button("Pin") { act(selection) { $0.isPinned.toggle() } }.disabled(selection.isEmpty)
                    Spacer()
                    Button("Delete", role: .destructive) { act(selection) { $0.deletedAt = .now } }.disabled(selection.isEmpty)
                } else {
                    Text("\(list.count) Notes").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button { newNote() } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("New Note")
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, UTType(filenameExtension: "md") ?? .plainText], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for u in urls where u.startAccessingSecurityScopedResource() {
                defer { u.stopAccessingSecurityScopedResource() }
                if let text = try? String(contentsOf: u, encoding: .utf8) { context.insert(Note(body: text, folderID: currentFolder)) }
            }
            try? context.save()
        }
        .sheet(isPresented: $showPending) { NavigationStack { PendingChangesView() } }
    }

    private var currentFolder: UUID? { if case .folder(let id) = filter { return id } else { return nil } }

    @ViewBuilder private var emptyState: some View {
        ContentUnavailableView {
            Label(filter == .all && search.isEmpty ? "No Notes" : "Nothing Here", systemImage: "note.text")
        } description: {
            Text(search.isEmpty ? "Tap the compose button to write your first note. Notes stay on this device unless you link them to GitHub." : "No notes match “\(search)”. Results cover notes on this device.")
        }
        .listRowBackground(Color.clear)
    }

    private func row(_ n: Note) -> some View {
        Button { if !editMode.isEditing { editing = n } } label: { NoteRow(note: n, showPreview: showPreviews) }
            .buttonStyle(.plain)
            .tag(n.id)
            .swipeActions(edge: .leading) {
                Button { n.isPinned.toggle(); try? context.save() } label: { Label(n.isPinned ? "Unpin" : "Pin", systemImage: "pin") }.tint(.orange)
            }
            .swipeActions(edge: .trailing) {
                if n.deletedAt != nil {
                    Button("Restore") { n.deletedAt = nil; try? context.save() }.tint(.blue)
                    Button("Delete Forever", role: .destructive) { context.delete(n); try? context.save() }
                } else {
                    Button(role: .destructive) { n.deletedAt = .now; try? context.save() } label: { Label("Delete", systemImage: "trash") }
                }
            }
            .contextMenu {
                Button(n.isPinned ? "Unpin" : "Pin", systemImage: "pin") { n.isPinned.toggle(); try? context.save() }
                ShareLink(item: n.body) { Label("Share", systemImage: "square.and.arrow.up") }
                Button("Delete", systemImage: "trash", role: .destructive) { n.deletedAt = .now; try? context.save() }
            }
    }

    private func act(_ ids: Set<UUID>, _ f: (Note) -> Void) {
        allNotes.filter { ids.contains($0.id) }.forEach(f)
        try? context.save(); selection = []; editMode = .inactive
    }

    private func newNote() {
        let n = Note(folderID: currentFolder)
        context.insert(n); try? context.save(); editing = n
    }
}

struct NoteRow: View {
    let note: Note
    var showPreview = true
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                if note.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                Text(note.title).font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                SyncBadge(note: note)
            }
            HStack(spacing: 6) {
                Text(note.modifiedAt, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                if showPreview, !note.preview.isEmpty { Text(note.preview).foregroundStyle(.secondary).lineLimit(1) }
            }.font(.subheadline)
            if let repo = note.repoFullName, let path = note.path {
                Label("\(repo)/\(path)", systemImage: "arrow.triangle.branch")
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct SyncBadge: View {
    let note: Note
    var body: some View {
        switch note.syncStatus {
        case .local: EmptyView()
        case .synced: Image(systemName: "checkmark.circle").foregroundStyle(.secondary).accessibilityLabel("Synced")
        case .modified, .newFile: Image(systemName: "circle.fill").font(.caption2).foregroundStyle(.orange).accessibilityLabel("Pending changes")
        case .conflict: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).accessibilityLabel("Conflict")
        case .remoteDeleted: Image(systemName: "questionmark.folder").foregroundStyle(.red).accessibilityLabel("Deleted on GitHub")
        }
    }
}
