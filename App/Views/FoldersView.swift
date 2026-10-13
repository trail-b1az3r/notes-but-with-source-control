import SwiftUI
import SwiftData

struct FoldersView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Folder.name) private var folders: [Folder]
    @Query private var connections: [RepoConnection]
    @Query private var notes: [Note]
    @State private var newName = ""
    @State private var showNew = false
    @State private var renaming: Folder?
    @State private var renameText = ""
    @State private var deleting: Folder?

    var body: some View {
        List {
            Section("Smart Folders") {
                link("All Notes", "tray.full", .all)
                link("Pinned", "pin", .pinned)
                link("Repository Notes", "arrow.triangle.branch", .repoLinked)
                link("Pending Changes", "arrow.triangle.2.circlepath", .pending)
                link("Conflicts", "exclamationmark.triangle", .conflicts)
            }
            if !connections.isEmpty {
                Section("Repositories") {
                    ForEach(connections) { link($0.fullName, "externaldrive", .repo($0.fullName)) }
                }
            }
            Section("Folders") {
                ForEach(folders.filter { $0.parentID == nil }) { f in folderTree(f, depth: 0) }
                if folders.isEmpty { Text("No folders yet").foregroundStyle(.secondary) }
            }
            Section { link("Recently Deleted", "trash", .trash) }
        }
        .navigationTitle("Folders")
        .toolbar { Button { showNew = true } label: { Image(systemName: "folder.badge.plus") }.accessibilityLabel("New Folder") }
        .alert("New Folder", isPresented: $showNew) {
            TextField("Name", text: $newName)
            Button("Create") { if !newName.isEmpty { context.insert(Folder(name: newName)); try? context.save() }; newName = "" }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .alert("Rename Folder", isPresented: .init(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if !renameText.isEmpty { renaming?.name = renameText; try? context.save() } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: .init(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Folder, Keep Notes", role: .destructive) { delete(deleting) }
        } message: {
            Text("Notes inside move to All Notes. Nothing on GitHub is deleted.")
        }
    }

    private func folderTree(_ f: Folder, depth: Int) -> AnyView {
        AnyView(Group {
            link(f.name, "folder", .folder(f.id), count: notes.filter { $0.folderID == f.id && $0.deletedAt == nil }.count)
                .padding(.leading, CGFloat(depth) * 14)
                .contextMenu {
                    Button("Rename", systemImage: "pencil") { renameText = f.name; renaming = f }
                    Button("New Subfolder", systemImage: "folder.badge.plus") { context.insert(Folder(name: "New Folder", parentID: f.id)); try? context.save() }
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = f }
                }
            ForEach(folders.filter { $0.parentID == f.id }) { folderTree($0, depth: depth + 1) }
        })
    }

    private func link(_ title: String, _ icon: String, _ filter: NoteFilter, count: Int? = nil) -> some View {
        NavigationLink {
            NotesListView(filter: filter, titleOverride: title)
        } label: {
            HStack { Label(title, systemImage: icon); if let count { Spacer(); Text("\(count)").foregroundStyle(.secondary) } }
        }
    }

    private func delete(_ f: Folder?) {
        guard let f else { return }
        for n in notes where n.folderID == f.id { n.folderID = nil }
        for c in folders where c.parentID == f.id { c.parentID = f.parentID }
        context.delete(f); try? context.save()
    }
}
