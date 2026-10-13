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
                .tabItem { Label("Repositories", systemImage: "externaldrive.connected.to.line.below") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer()
            Text("Notes:").font(.largeTitle.bold())
            Text("Apple Notes, with source control built in.").font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 18) {
                row("iphone", "Start with local notes", "Everything stays on this device. No account needed.")
                row("person.crop.circle.badge.checkmark", "Connect GitHub", "Link a note to a file in any repository you can access. Sign in from Settings whenever you like.")
                row("externaldrive.connected.to.line.below", "Use a repository as a workspace", "Browse a repo, open Markdown files as notes, and commit your edits.")
            }
            Text("Nothing is published to GitHub unless you choose to.").font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button(action: done) { Text("Get Started").frame(maxWidth: .infinity).padding(.vertical, 6) }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }
    private func row(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
