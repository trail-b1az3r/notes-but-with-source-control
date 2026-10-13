import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await session.data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw GitHubError.network("Invalid response") }
        return (data, http)
    }
}

public enum GitHubError: Error, Equatable, Sendable {
    case unauthorized
    case forbidden(String)
    case notFound
    /// The file changed remotely (409) or the supplied blob SHA is stale (422).
    case conflict
    case rateLimited(resetAt: Date?)
    case server(Int)
    case validation(String)
    case decoding(String)
    case network(String)
    case tooLarge
    case notUTF8

    public var userMessage: String {
        switch self {
        case .unauthorized: return "Your GitHub sign-in expired or was revoked. Sign in again in Settings."
        case .forbidden(let m): return "GitHub denied this request. You may not have write access to this repository. \(m)"
        case .notFound: return "GitHub couldn't find that item. It may have been deleted, renamed, or you may lack access."
        case .conflict: return "This file changed on GitHub after you started editing."
        case .rateLimited(let d):
            if let d { return "GitHub rate limit reached. Try again after \(d.formatted(date: .omitted, time: .shortened))." }
            return "GitHub rate limit reached. Try again in a few minutes."
        case .server(let c): return "GitHub is having trouble (HTTP \(c)). Your changes are safe locally; try again shortly."
        case .validation(let m): return "GitHub rejected the request: \(m)"
        case .decoding: return "GitHub returned data the app couldn't read."
        case .network(let m): return "Can't reach GitHub. \(m)"
        case .tooLarge: return "This file is too large to open as a note (limit 1 MB)."
        case .notUTF8: return "This file isn't UTF-8 text, so it can't be opened as a note."
        }
    }
}

public struct GitHubClient: Sendable {
    public let transport: HTTPTransport
    public let token: @Sendable () -> String?
    public let baseURL: URL
    public var maxRetries = 2
    public var sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }

    public init(transport: HTTPTransport = URLSessionTransport(),
                baseURL: URL = URL(string: "https://api.github.com")!,
                token: @escaping @Sendable () -> String?) {
        self.transport = transport; self.baseURL = baseURL; self.token = token
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Core request

    func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Encodable? = nil) throws -> URLRequest {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        comps.percentEncodedPath = path
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw GitHubError.validation("Invalid URL") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let t = token() { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        return req
    }

    func perform(_ req: URLRequest) async throws -> Data {
        let idempotent = req.httpMethod == "GET"
        var attempt = 0
        while true {
            do {
                try Task.checkCancellation()
                let (data, resp) = try await transport.send(req)
                if (200..<300).contains(resp.statusCode) { return data }
                let err = Self.map(resp, data)
                if idempotent, case .server = err, attempt < maxRetries {
                    attempt += 1; await sleep(Backoff.delay(attempt: attempt, base: 1)); continue
                }
                throw err
            } catch let e as GitHubError {
                throw e
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if idempotent, attempt < maxRetries {
                    attempt += 1; await sleep(Backoff.delay(attempt: attempt, base: 1)); continue
                }
                throw GitHubError.network((error as? URLError)?.localizedDescription ?? "Check your connection.")
            }
        }
    }

    static func map(_ resp: HTTPURLResponse, _ data: Data) -> GitHubError {
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? ""
        switch resp.statusCode {
        case 401: return .unauthorized
        case 403, 429:
            if resp.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" || resp.statusCode == 429
                || message.localizedCaseInsensitiveContains("rate limit") {
                let reset = resp.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
                return .rateLimited(resetAt: reset)
            }
            return .forbidden(message)
        case 404: return .notFound
        case 409: return .conflict
        case 422:
            if message.localizedCaseInsensitiveContains("sha") { return .conflict }
            return .validation(message)
        case 500...599: return .server(resp.statusCode)
        default: return .validation(message.isEmpty ? "HTTP \(resp.statusCode)" : message)
        }
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await perform(try request("GET", path, query: query))
        do { return try Self.decoder.decode(T.self, from: data) }
        catch { throw GitHubError.decoding(String(describing: type(of: error))) }
    }

    func send<T: Decodable>(_ method: String, _ path: String, body: Encodable) async throws -> T {
        let data = try await perform(try request(method, path, body: body))
        do { return try Self.decoder.decode(T.self, from: data) }
        catch { throw GitHubError.decoding(String(describing: type(of: error))) }
    }

    // MARK: Endpoints

    public func currentUser() async throws -> GHUser { try await get("/user") }

    public func listRepositories(page: Int = 1, perPage: Int = 50) async throws -> [GHRepo] {
        try await get("/user/repos", query: [
            .init(name: "sort", value: "pushed"), .init(name: "per_page", value: "\(perPage)"),
            .init(name: "page", value: "\(page)"),
            .init(name: "affiliation", value: "owner,collaborator,organization_member"),
        ])
    }

    public func repository(owner: String, name: String) async throws -> GHRepo {
        try await get("/repos/\(owner)/\(name)")
    }

    public func branches(owner: String, name: String, page: Int = 1) async throws -> [GHBranch] {
        try await get("/repos/\(owner)/\(name)/branches", query: [.init(name: "per_page", value: "100"), .init(name: "page", value: "\(page)")])
    }

    public func contents(owner: String, name: String, path: String = "", ref: String?) async throws -> [GHContentItem] {
        let p = path.isEmpty ? "" : "/" + RepoPath.percentEncoded(try RepoPath.validate(path))
        return try await get("/repos/\(owner)/\(name)/contents\(p)", query: ref.map { [.init(name: "ref", value: $0)] } ?? [])
    }

    public func file(owner: String, name: String, path: String, ref: String?) async throws -> RemoteFile {
        let clean = try RepoPath.validate(path)
        let r: GHFileResponse = try await get("/repos/\(owner)/\(name)/contents/\(RepoPath.percentEncoded(clean))",
                                              query: ref.map { [.init(name: "ref", value: $0)] } ?? [])
        guard r.type == "file" else { throw GitHubError.validation("Not a regular file") }
        guard r.size <= RepoPath.maxNoteBytes else { throw GitHubError.tooLarge }
        guard r.encoding == "base64", let c = r.content,
              let data = Data(base64Encoded: c, options: .ignoreUnknownCharacters) else { throw GitHubError.decoding("content") }
        return RemoteFile(path: r.path, sha: r.sha, size: r.size, data: data)
    }

    /// Creates a real commit. Pass the blob SHA the edit was based on when updating; omit for new files.
    public func putFile(owner: String, name: String, path: String, message: String,
                        content: Data, blobSHA: String?, branch: String) async throws -> GHWriteResult {
        struct Body: Encodable { let message: String; let content: String; let sha: String?; let branch: String }
        let clean = try RepoPath.validate(path)
        let r: GHWriteResponse = try await send("PUT", "/repos/\(owner)/\(name)/contents/\(RepoPath.percentEncoded(clean))",
            body: Body(message: message, content: content.base64EncodedString(), sha: blobSHA, branch: branch))
        return GHWriteResult(commitSHA: r.commit.sha, blobSHA: r.content?.sha)
    }

    public func deleteFile(owner: String, name: String, path: String, message: String, blobSHA: String, branch: String) async throws -> String {
        struct Body: Encodable { let message: String; let sha: String; let branch: String }
        let clean = try RepoPath.validate(path)
        let r: GHWriteResponse = try await send("DELETE", "/repos/\(owner)/\(name)/contents/\(RepoPath.percentEncoded(clean))",
            body: Body(message: message, sha: blobSHA, branch: branch))
        return r.commit.sha
    }

    public func commits(owner: String, name: String, branch: String, path: String?, page: Int = 1, perPage: Int = 30) async throws -> [GHCommitSummary] {
        var q: [URLQueryItem] = [.init(name: "sha", value: branch), .init(name: "per_page", value: "\(perPage)"), .init(name: "page", value: "\(page)")]
        if let path { q.append(.init(name: "path", value: try RepoPath.validate(path))) }
        return try await get("/repos/\(owner)/\(name)/commits", query: q)
    }

    public func commitDetail(owner: String, name: String, sha: String) async throws -> GHCommitDetail {
        try await get("/repos/\(owner)/\(name)/commits/\(sha)")
    }

    public func createBranch(owner: String, name: String, newBranch: String, from sourceBranch: String) async throws {
        let ref: GHRef = try await get("/repos/\(owner)/\(name)/git/ref/heads/\(RepoPath.percentEncoded(sourceBranch))")
        struct Body: Encodable { let ref: String; let sha: String }
        let _: GHRef = try await send("POST", "/repos/\(owner)/\(name)/git/refs", body: Body(ref: "refs/heads/\(newBranch)", sha: ref.object.sha))
    }

    public func createRepository(name: String, description: String?, isPrivate: Bool) async throws -> GHRepo {
        struct Body: Encodable { let name: String; let description: String?; let `private`: Bool; let autoInit: Bool
            enum CodingKeys: String, CodingKey { case name, description, `private`, autoInit = "auto_init" } }
        return try await send("POST", "/user/repos", body: Body(name: name, description: description, private: isPrivate, autoInit: true))
    }
}

struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ v: Encodable) { value = v }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
