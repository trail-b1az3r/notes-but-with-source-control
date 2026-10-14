import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import NotesCore

final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Stub { var status: Int; var body: String; var headers: [String: String] = [:]; var failWithNetworkError = false }
    private let lock = NSLock()
    private var queue: [Stub]
    private(set) var requests: [URLRequest] = []
    init(_ stubs: [Stub]) { queue = stubs }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        guard !queue.isEmpty else { throw URLError(.notConnectedToInternet) }
        let s = queue.removeFirst()
        if s.failWithNetworkError { throw URLError(.networkConnectionLost) }
        let resp = HTTPURLResponse(url: request.url!, statusCode: s.status, httpVersion: nil, headerFields: s.headers)!
        return (Data(s.body.utf8), resp)
    }
}

func client(_ stubs: [MockTransport.Stub]) -> (GitHubClient, MockTransport) {
    let t = MockTransport(stubs)
    var c = GitHubClient(transport: t, token: { "test-token" })
    c.sleep = { _ in }
    return (c, t)
}
