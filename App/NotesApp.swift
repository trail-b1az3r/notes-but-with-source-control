import SwiftUI
import SwiftData

@main
struct NotesApp: App {
    let container: ModelContainer
    @State private var app: AppModel
    @State private var sync: SyncService

    init() {
        let c: ModelContainer
        do {
            c = try ModelContainer(for: Note.self, Folder.self, LocalRevision.self, RepoConnection.self)
        } catch {
            // Never discard the user's data: fall back to an in-memory store only so the app can show recovery guidance.
            c = try! ModelContainer(for: Note.self, Folder.self, LocalRevision.self, RepoConnection.self,
                                    configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
        let a = AppModel()
        container = c
        _app = State(initialValue: a)
        _sync = State(initialValue: SyncService(context: c.mainContext, app: a))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(sync)
        }
        .modelContainer(container)
    }
}
