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
    @Environment(AppModel.self) private var app
    @AppStorage("dismissedConnectBanner") private var dismissedConnect = false
    @State private var showConnect = false
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
            if !app.isSignedIn, !dismissedConnect, filter == .all, search.isEmpty { connectBanner }
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
        .sheet(isPresented: $showConnect) { ConnectSheet() }
        .refreshable { await sync.syncAll() }
        .sensoryFeedback(.impact(weight: .light), trigger: allNotes.count)
    }

    private var connectBanner: some View {
        Section {
            HStack(spacing: 12) {
                IconTile(symbol: "arrow.triangle.branch", color: .indigo, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect GitHub").font(.headline)
                    Text("Keep notes in your repositories, with history.").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button { withAnimation { dismissedConnect = true } } label: { Image(systemName: "xmark").font(.footnote.bold()).foregroundStyle(.secondary) }
                    .buttonStyle(.borderless).accessibilityLabel("Dismiss")
            }
            .contentShape(Rectangle())
            .onTapGesture { showConnect = true }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
        }
    }

    private var currentFolder: UUID? { if case .folder(let id) = filter { return id } else { return nil } }

    @ViewBuilder private var emptyState: some View {
        let first = filter == .all && search.isEmpty
        ContentUnavailableView {
            Label(first ? "No Notes Yet" : "Nothing Here", systemImage: search.isEmpty ? "note.text" : "magnifyingglass")
        } description: {
            Text(first ? "Write your first note. It stays on this device unless you link it to GitHub."
                 : search.isEmpty ? "Notes you add here will show up in this list."
                 : "No notes match “\(search)”. Search covers notes on this device.")
        } actions: {
            if first { Button("New Note", systemImage: "square.and.pencil") { newNote() }.buttonStyle(.borderedProminent) }
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
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    if note.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                    Text(note.title).font(.headline).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(note.modifiedAt, format: .relative(presentation: .named)).foregroundStyle(.secondary).layoutPriority(1)
                    if showPreview, !note.preview.isEmpty { Text(note.preview).foregroundStyle(.tertiary).lineLimit(1) }
                }.font(.subheadline)
                if let repo = note.repoFullName, let path = note.path {
                    Label("\(repo) · \(path)", systemImage: "arrow.triangle.branch")
                        .font(.caption).foregroundStyle(.indigo).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            SyncBadge(note: note)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

struct SyncBadge: View {
    let note: Note
    var body: some View {
        switch note.syncStatus {
        case .local: EmptyView()
        case .synced: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green.opacity(0.8)).accessibilityLabel("Synced")
        case .modified: Pill(text: "Pending", color: .orange)
        case .newFile: Pill(text: "New", color: .blue)
        case .conflict: Pill(text: "Conflict", symbol: "exclamationmark.triangle.fill", color: .red)
        case .remoteDeleted: Pill(text: "Deleted", symbol: "questionmark.folder", color: .red)
        }
    }
}
