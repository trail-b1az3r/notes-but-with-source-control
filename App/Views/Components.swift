import SwiftUI
import NotesCore

/// Rounded colored symbol tile used for settings rows and banners.
struct IconTile: View {
    let symbol: String
    var color: Color = .accentColor
    var size: CGFloat = 30
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct SettingsLabel: View {
    let title: String
    let symbol: String
    var color: Color = .accentColor
    init(_ title: String, _ symbol: String, _ color: Color) { self.title = title; self.symbol = symbol; self.color = color }
    var body: some View { HStack(spacing: 12) { IconTile(symbol: symbol, color: color); Text(title) } }
}

struct Pill: View {
    let text: String
    var symbol: String?
    var color: Color
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// The single place GitHub is connected: setup, sign-in, device-code progress and the connected account.
struct GitHubConnectView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("privateAccess") private var privateAccess = true
    @State private var clientIDInput = ""
    @State private var confirmSignOut = false
    @State private var copied = false

    private static let repoURL = "https://github.com/trail-b1az3r/notes-but-with-source-control"
    private static let registerURL = URL(string: "https://github.com/settings/applications/new?oauth_application%5Bname%5D=nbwsc&oauth_application%5Burl%5D=\(repoURL)&oauth_application%5Bcallback_url%5D=\(repoURL)")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .animation(.snappy, value: app.isSignedIn)
            .animation(.snappy, value: app.isSigningIn)
            .animation(.snappy, value: app.isConfigured)
            .confirmationDialog("Sign out of GitHub?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { app.signOut() }
            } message: {
                Text("Your notes and unsynced edits stay on this device. Nothing on GitHub changes. To fully revoke access, visit github.com/settings/applications.")
            }
    }

    @ViewBuilder private var content: some View {
        if app.isSignedIn { account }
        else if app.isSigningIn { progress }
        else if !app.isConfigured { setup }
        else { signIn }
    }

    // MARK: Connected

    private var account: some View {
        HStack(spacing: 14) {
            AsyncImage(url: app.user?.avatarUrl) { $0.resizable().scaledToFill() } placeholder: {
                Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
            }
            .frame(width: 52, height: 52).clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(app.user?.name ?? app.user.map { "@\($0.login)" } ?? "GitHub").font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text(app.user.map { "Connected as @\($0.login)" } ?? "Connected").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Sign Out", role: .destructive) { confirmSignOut = true }.font(.subheadline).buttonStyle(.borderless)
        }
    }

    // MARK: Device-code progress

    private var progress: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let code = app.deviceCode {
                Text("Approve on GitHub").font(.headline)
                Text("Enter this code when GitHub asks for it.").font(.subheadline).foregroundStyle(.secondary)
                Text(code.userCode)
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .textSelection(.enabled)
                    .accessibilityLabel("Code \(code.userCode.map(String.init).joined(separator: " "))")
                HStack {
                    Button { UIPasteboard.general.string = code.userCode; copied = true } label: {
                        Label(copied ? "Copied" : "Copy Code", systemImage: copied ? "checkmark" : "doc.on.doc").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered)
                    Link(destination: code.verificationURI) {
                        Label("Open GitHub", systemImage: "safari").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting for approval…").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { app.cancelSignIn() }.font(.footnote)
                }
            } else {
                HStack(spacing: 10) { ProgressView(); Text("Contacting GitHub…") }
                Button("Cancel") { app.cancelSignIn() }.font(.footnote)
            }
        }
    }

    // MARK: Ready to sign in

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 14) {
            IconTile(symbol: "arrow.triangle.branch", color: .indigo, size: 44)
            Text("Connect GitHub").font(.title3.bold())
            Text("Open Markdown files from your repositories, commit your edits, and browse history. Local notes always work without an account.")
                .font(.subheadline).foregroundStyle(.secondary)
            Toggle(isOn: $privateAccess) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include private repositories")
                    Text(privateAccess ? "GitHub grants this as the “repo” permission." : "Public repositories only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button { app.signIn(privateAccess: privateAccess) } label: {
                Text("Sign in with GitHub").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            errorLine
        }
    }

    // MARK: One-time setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            IconTile(symbol: "key.horizontal", color: .orange, size: 44)
            Text("One-time setup").font(.title3.bold())
            Text("GitHub needs to know which app is asking. It takes about a minute and only has to be done once.")
                .font(.subheadline).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Register an app on GitHub (name and links are filled in).")
                Link(destination: Self.registerURL) { Label("Open GitHub", systemImage: "arrow.up.right.square") }
                    .buttonStyle(.bordered).padding(.leading, 30)
                step(2, "On its page, tick “Enable Device Flow” and save.")
                step(3, "Copy the Client ID and paste it here.")
            }
            TextField("Client ID", text: $clientIDInput)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .padding(12)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Button { if app.saveClientID(clientIDInput) { clientIDInput = "" } } label: {
                Text("Save and Continue").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).disabled(clientIDInput.trimmingCharacters(in: .whitespaces).isEmpty)
            Text("A Client ID is a public identifier, not a secret. No passwords are stored; your sign-in token stays in the iOS Keychain.")
                .font(.caption).foregroundStyle(.secondary)
            errorLine
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.caption.bold()).foregroundStyle(.white)
                .frame(width: 20, height: 20).background(Color.accentColor, in: Circle())
            Text(text).font(.subheadline)
        }
    }

    @ViewBuilder private var errorLine: some View {
        if let e = app.signInError {
            Label(e, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red)
        }
    }
}

/// Full-screen wrapper so any screen can offer GitHub sign-in in a sheet.
struct ConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    var body: some View {
        NavigationStack {
            ScrollView { GitHubConnectView().padding() }
                .background(Color(.systemGroupedBackground))
                .navigationTitle("GitHub")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(app.isSignedIn ? "Done" : "Not Now") { dismiss() } } }
        }
        .onChange(of: app.isSignedIn) { _, signedIn in if signedIn { dismiss() } }
    }
}
