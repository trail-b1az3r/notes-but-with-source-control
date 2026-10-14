import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("onboarded") private var onboarded = false
    @AppStorage("appearance") private var appearance = 0

    var body: some View {
        TabView {
            NavigationStack { NotesListView(filter: .all) }
                .tabItem { Label("Notes", systemImage: "note.text") }
            NavigationStack { FoldersView() }
                .tabItem { Label("Folders", systemImage: "folder") }
            NavigationStack { RepositoriesView() }
                .tabItem { Label("GitHub", systemImage: "arrow.triangle.branch") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(.indigo)
        .preferredColorScheme(appearance == 1 ? .light : appearance == 2 ? .dark : nil)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !app.isOnline {
                Label("Offline — edits are saved on this device", systemImage: "wifi.slash")
                    .font(.footnote).frame(maxWidth: .infinity).padding(6)
                    .background(.bar)
                    .accessibilityElement(children: .combine)
            }
        }
        .fullScreenCover(isPresented: .init(get: { !onboarded }, set: { _ in })) {
            OnboardingView { onboarded = true }
        }
        .alert("Signed out", isPresented: .init(get: { app.sessionNotice != nil }, set: { if !$0 { app.sessionNotice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(app.sessionNotice ?? "") }
    }
}

struct OnboardingView: View {
    var done: () -> Void
    @State private var connecting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to nbwsc").font(.largeTitle.bold())
                Text("Notes with source control built in.").font(.title3).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 22) {
                row("iphone", .blue, "Start writing", "Notes stay on this device. No account needed.")
                row("arrow.triangle.branch", .indigo, "Connect GitHub", "Open Markdown files from your repositories and commit your edits.")
                row("clock.arrow.circlepath", .green, "Never lose work", "Every edit is saved locally, with history and conflict protection.")
            }
            Spacer()
            VStack(spacing: 12) {
                Button(action: done) { Text("Start with Local Notes").font(.headline).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button { connecting = true } label: { Text("Connect GitHub First").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large)
                Text("Nothing is ever published to GitHub unless you choose to.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .sheet(isPresented: $connecting) { ConnectSheet() }
    }
    private func row(_ icon: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            IconTile(symbol: icon, color: color, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
