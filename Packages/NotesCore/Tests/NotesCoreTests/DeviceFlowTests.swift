import XCTest
@testable import NotesCore

final class DeviceFlowTests: XCTestCase {
    func auth(_ stubs: [MockTransport.Stub], id: String = "cid") -> (DeviceFlowAuth, MockTransport) {
        let t = MockTransport(stubs)
        var a = DeviceFlowAuth(clientID: id, transport: t)
        a.sleep = { _ in }
        return (a, t)
    }
    let codeJSON = #"{"device_code":"dc","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#

    func testNotConfigured() async {
        let (a, _) = auth([], id: "")
        do { _ = try await a.start(scope: "repo"); XCTFail() } catch { XCTAssertEqual(error as? AuthError, .notConfigured) }
    }

    func testStartAndPollThroughPendingAndSlowDown() async throws {
        let (a, t) = auth([
            .init(status: 200, body: codeJSON),
            .init(status: 200, body: #"{"error":"authorization_pending"}"#),
            .init(status: 200, body: #"{"error":"slow_down","interval":10}"#),
            .init(status: 200, body: #"{"access_token":"gho_x","token_type":"bearer"}"#),
        ])
        let code = try await a.start(scope: "repo")
        XCTAssertEqual(code.userCode, "ABCD-1234")
        let token = try await a.pollForToken(code)
        XCTAssertEqual(token, "gho_x")
        let body = String(data: t.requests[0].httpBody!, encoding: .utf8)!
        XCTAssertTrue(body.contains("client_id=cid"))
        XCTAssertTrue(body.contains("scope=repo"))
    }

    func testDenied() async throws {
        let (a, _) = auth([.init(status: 200, body: codeJSON), .init(status: 200, body: #"{"error":"access_denied"}"#)])
        let code = try await a.start(scope: "repo")
        do { _ = try await a.pollForToken(code); XCTFail() } catch { XCTAssertEqual(error as? AuthError, .denied) }
    }

    func testDeviceFlowDisabled() async {
        let (a, _) = auth([.init(status: 200, body: #"{"error":"device_flow_disabled"}"#)])
        do { _ = try await a.start(scope: "repo"); XCTFail() } catch { XCTAssertEqual(error as? AuthError, .deviceFlowDisabled) }
    }
}
