import Foundation
import Network
import Observation
import UIKit
import NotesCore

@MainActor @Observable final class AppModel {
    nonisolated static let tokenAccount = "github.token"

    var user: GHUser?
    var isSignedIn: Bool
    var isOnline = true
    var deviceCode: DeviceCode?
    var isSigningIn = false
    var signInError: String?
    var sessionNotice: String?

    let client = GitHubClient(token: { Keychain.read(AppModel.tokenAccount) })
    private let monitor = NWPathMonitor()
    private var signInTask: Task<Void, Never>?
    var onReconnect: (() -> Void)?

    var clientID: String { (Bundle.main.object(forInfoDictionaryKey: "GitHubClientID") as? String) ?? "" }
    var isConfigured: Bool { !clientID.isEmpty && !clientID.hasPrefix("$(") }

    init() {
        isSignedIn = Keychain.read(Self.tokenAccount) != nil
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let was = self.isOnline
                self.isOnline = path.status == .satisfied
                if !was, self.isOnline { self.onReconnect?() }
            }
        }
        monitor.start(queue: .global(qos: .utility))
        if isSignedIn { Task { await refreshUser() } }
    }

    /// `privateAccess` requests the `repo` scope; otherwise only `public_repo`.
    func signIn(privateAccess: Bool) {
        signInError = nil
        guard isConfigured else { signInError = AuthError.notConfigured.userMessage; return }
        isSigningIn = true
        signInTask = Task {
            defer { isSigningIn = false; deviceCode = nil }
            do {
                let auth = DeviceFlowAuth(clientID: clientID)
                let code = try await auth.start(scope: privateAccess ? "repo" : "public_repo")
                deviceCode = code
                UIPasteboard.general.string = code.userCode
                let token = try await auth.pollForToken(code)
                guard Keychain.save(token, account: Self.tokenAccount) else {
                    signInError = "Couldn't store your credentials securely."; return
                }
                isSignedIn = true; sessionNotice = nil
                await refreshUser()
            } catch is CancellationError {
            } catch let e as AuthError { signInError = e.userMessage }
            catch { signInError = "Sign-in failed." }
        }
    }

    func cancelSignIn() { signInTask?.cancel() }

    /// Removes the local credential. Remote data and local notes are untouched.
    /// (GitHub only lets an OAuth app revoke with its client secret, which this app never holds;
    /// users can revoke access at github.com/settings/applications.)
    func signOut() {
        Keychain.delete(Self.tokenAccount)
        isSignedIn = false; user = nil
    }

    func refreshUser() async {
        do { user = try await client.currentUser() }
        catch { report(error) }
    }

    /// Central error hook: expired credentials sign the user out gracefully.
    func report(_ error: Error) {
        if let e = error as? GitHubError, e == .unauthorized {
            signOut()
            sessionNotice = e.userMessage
        }
    }

    static func message(for error: Error) -> String {
        if let e = error as? GitHubError { return e.userMessage }
        if let e = error as? PathValidationError { return "That path isn't allowed (\(e))." }
        if error is CancellationError { return "Cancelled." }
        return "Something went wrong."
    }
}
