import XCTest
@testable import NotesCore

final class GitHubClientTests: XCTestCase {
    func testDecodeRepos() async throws {
        let json = """
        [{"id":1,"name":"n","full_name":"o/n","owner":{"login":"o"},"private":true,"description":null,
          "default_branch":"main","permissions":{"admin":false,"push":true,"pull":true},
          "pushed_at":"2024-01-02T03:04:05Z","html_url":"https://github.com/o/n"}]
        """
        let (c, t) = client([.init(status: 200, body: json)])
        let repos = try await c.listRepositories()
        XCTAssertEqual(repos.first?.fullName, "o/n")
        XCTAssertTrue(repos[0].canPush)
        XCTAssertEqual(repos[0].defaultBranch, "main")
        XCTAssertEqual(t.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
    }

    func testFileDecodesBase64WithNewlines() async throws {
        let body = #"{"name":"a.md","path":"a.md","sha":"abc","size":5,"type":"file","encoding":"base64","content":"aGVs\nbG8=\n"}"#
        let (c, _) = client([.init(status: 200, body: body)])
        let f = try await c.file(owner: "o", name: "n", path: "a.md", ref: "main")
        XCTAssertEqual(f.text, "hello")
        XCTAssertEqual(f.sha, "abc")
    }

    func testFileTooLarge() async {
        let body = #"{"name":"a.md","path":"a.md","sha":"abc","size":5000000,"type":"file","encoding":"none","content":""}"#
        let (c, _) = client([.init(status: 200, body: body)])
        do { _ = try await c.file(owner: "o", name: "n", path: "a.md", ref: nil); XCTFail() }
        catch { XCTAssertEqual(error as? GitHubError, .tooLarge) }
    }

    func testPutFileSendsBlobSHAAndReturnsCommit() async throws {
        let (c, t) = client([.init(status: 200, body: #"{"commit":{"sha":"c1"},"content":{"sha":"b2"}}"#)])
        let r = try await c.putFile(owner: "o", name: "n", path: "dir/a b.md", message: "msg", content: Data("hi".utf8), blobSHA: "b1", branch: "main")
        XCTAssertEqual(r, GHWriteResult(commitSHA: "c1", blobSHA: "b2"))
        let req = t.requests[0]
        XCTAssertEqual(req.httpMethod, "PUT")
        XCTAssertEqual(req.url?.path, "/repos/o/n/contents/dir/a b.md")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        XCTAssertEqual(body["sha"] as? String, "b1")
        XCTAssertEqual(body["content"] as? String, "aGk=")
    }

    func testStaleShaMapsToConflict() async {
        let (c, _) = client([.init(status: 409, body: #"{"message":"is at abc but expected def"}"#)])
        do { _ = try await c.putFile(owner: "o", name: "n", path: "a.md", message: "m", content: Data(), blobSHA: "x", branch: "main"); XCTFail() }
        catch { XCTAssertEqual(error as? GitHubError, .conflict) }
    }

    func testRateLimit() async {
        let (c, _) = client([.init(status: 403, body: #"{"message":"API rate limit exceeded"}"#,
                                   headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1700000000"])])
        do { _ = try await c.currentUser(); XCTFail() }
        catch { XCTAssertEqual(error as? GitHubError, .rateLimited(resetAt: Date(timeIntervalSince1970: 1_700_000_000))) }
    }

    func testForbiddenIsNotRateLimit() async {
        let (c, _) = client([.init(status: 403, body: #"{"message":"Resource not accessible"}"#)])
        do { _ = try await c.currentUser(); XCTFail() }
        catch { XCTAssertEqual(error as? GitHubError, .forbidden("Resource not accessible")) }
    }

    func testUnauthorized() async {
        let (c, _) = client([.init(status: 401, body: "{}")])
        do { _ = try await c.currentUser(); XCTFail() }
        catch { XCTAssertEqual(error as? GitHubError, .unauthorized) }
    }

    func testGetRetriesServerErrors() async throws {
        let (c, t) = client([.init(status: 502, body: "{}"), .init(status: 200, body: #"{"login":"me","id":1}"#)])
        let u = try await c.currentUser()
        XCTAssertEqual(u.login, "me")
        XCTAssertEqual(t.requests.count, 2)
    }

    func testPutIsNotRetried() async {
        let (c, t) = client([.init(status: 502, body: "{}"), .init(status: 200, body: #"{"commit":{"sha":"c"}}"#)])
        do { _ = try await c.putFile(owner: "o", name: "n", path: "a.md", message: "m", content: Data(), blobSHA: nil, branch: "main"); XCTFail() }
        catch { XCTAssertEqual(error as? GitHubError, .server(502)) }
        XCTAssertEqual(t.requests.count, 1)
    }

    func testTraversalPathRejectedBeforeNetwork() async {
        let (c, t) = client([])
        do { _ = try await c.file(owner: "o", name: "n", path: "../x.md", ref: nil); XCTFail() }
        catch { XCTAssertEqual(error as? PathValidationError, .traversal) }
        XCTAssertTrue(t.requests.isEmpty)
    }

    func testDecodeCommits() async throws {
        let json = """
        [{"sha":"1234567890","commit":{"message":"Title\\n\\nbody","author":{"name":"A","date":"2024-01-02T03:04:05Z"}},"author":{"login":"alice"}}]
        """
        let (c, _) = client([.init(status: 200, body: json)])
        let cs = try await c.commits(owner: "o", name: "n", branch: "main", path: "a.md")
        XCTAssertEqual(cs[0].headline, "Title")
        XCTAssertEqual(cs[0].shortSHA, "1234567")
        XCTAssertEqual(cs[0].authorName, "alice")
        XCTAssertNotNil(cs[0].date)
    }
}
