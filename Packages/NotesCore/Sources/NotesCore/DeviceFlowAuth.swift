import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct DeviceCode: Equatable, Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURI: URL
    public let interval: Int
    public let expiresIn: Int
}

public enum AuthError: Error, Equatable, Sendable {
    case notConfigured, expired, denied, deviceFlowDisabled, network(String), unexpected(String)
    public var userMessage: String {
        switch self {
        case .notConfigured: return "GitHub sign-in isn't configured in this build. Set GITHUB_CLIENT_ID (see docs/GITHUB_SETUP.md)."
        case .expired: return "The sign-in code expired. Start again."
        case .denied: return "Authorization was declined on GitHub."
        case .deviceFlowDisabled: return "Device flow isn't enabled for this GitHub OAuth app. Enable it in the app's settings on GitHub."
        case .network(let m): return "Can't reach GitHub. \(m)"
        case .unexpected(let m): return "Unexpected response from GitHub: \(m)"
        }
    }
}

/// GitHub's OAuth device flow: GitHub's supported flow for native apps that must not embed a client secret.
public struct DeviceFlowAuth: Sendable {
    public let clientID: String
    public let transport: HTTPTransport
    public var sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }

    public init(clientID: String, transport: HTTPTransport = URLSessionTransport()) {
        self.clientID = clientID; self.transport = transport
    }

    private func post(_ url: String, _ form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "&=+:")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        do {
            let (data, _) = try await transport.send(req)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AuthError.unexpected("not JSON")
            }
            return obj
        } catch let e as AuthError { throw e }
        catch { throw AuthError.network((error as? URLError)?.localizedDescription ?? "") }
    }

    /// `scope` is "repo" for private repository access or "public_repo" for public repositories only.
    public func start(scope: String) async throws -> DeviceCode {
        guard !clientID.isEmpty else { throw AuthError.notConfigured }
        let o = try await post("https://github.com/login/device/code", ["client_id": clientID, "scope": scope])
        if let err = o["error"] as? String {
            throw err == "device_flow_disabled" ? AuthError.deviceFlowDisabled : AuthError.unexpected(err)
        }
        guard let dc = o["device_code"] as? String, let uc = o["user_code"] as? String,
              let uri = (o["verification_uri"] as? String).flatMap(URL.init(string:)),
              let exp = o["expires_in"] as? Int else { throw AuthError.unexpected("missing fields") }
        return DeviceCode(deviceCode: dc, userCode: uc, verificationURI: uri, interval: o["interval"] as? Int ?? 5, expiresIn: exp)
    }

    /// Polls until the user authorizes. Returns the access token. Honors `slow_down` and cancellation.
    public func pollForToken(_ code: DeviceCode) async throws -> String {
        var interval = TimeInterval(code.interval)
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        while Date() < deadline {
            await sleep(interval)
            try Task.checkCancellation()
            let o = try await post("https://github.com/login/oauth/access_token", [
                "client_id": clientID, "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            if let token = o["access_token"] as? String { return token }
            switch o["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": interval = TimeInterval(o["interval"] as? Int ?? Int(interval) + 5)
            case "expired_token": throw AuthError.expired
            case "access_denied": throw AuthError.denied
            case let e?: throw AuthError.unexpected(e)
            case nil: throw AuthError.unexpected("empty response")
            }
        }
        throw AuthError.expired
    }
}
