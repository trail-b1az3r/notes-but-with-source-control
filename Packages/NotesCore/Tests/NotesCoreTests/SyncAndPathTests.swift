import XCTest
@testable import NotesCore

final class SyncAndPathTests: XCTestCase {
    func state(local: String, remote: RemoteSnapshot?, base: String = "a\nb", sha: String = "s1") -> FileSyncState {
        FileSyncState(baseContent: base, baseSHA: sha, localContent: local, remote: remote)
    }

    func testUpToDate() {
        XCTAssertEqual(SyncPlanner.decide(state(local: "a\nb", remote: .init(sha: "s1", content: "a\nb"))), .upToDate)
    }
    func testPush() {
        XCTAssertEqual(SyncPlanner.decide(state(local: "a\nB", remote: .init(sha: "s1", content: "a\nb"))), .push)
    }
    func testPull() {
        let r = RemoteSnapshot(sha: "s2", content: "a\nb\nc")
        XCTAssertEqual(SyncPlanner.decide(state(local: "a\nb", remote: r)), .pull(r))
    }
    func testAdoptIdentical() {
        let r = RemoteSnapshot(sha: "s2", content: "a\nX")
        XCTAssertEqual(SyncPlanner.decide(state(local: "a\nX", remote: r)), .adoptRemote(r))
    }
    func testAutoMerge() {
        let r = RemoteSnapshot(sha: "s2", content: "a\nb\nc")
        guard case .autoMerge(let m, _) = SyncPlanner.decide(state(local: "A\nb", remote: r)) else { return XCTFail() }
        XCTAssertEqual(m, "A\nb\nc")
    }
    func testConflictNeverOverwrites() {
        let r = RemoteSnapshot(sha: "s2", content: "a\nR")
        guard case .conflict(let m, _) = SyncPlanner.decide(state(local: "a\nL", remote: r)) else { return XCTFail() }
        XCTAssertTrue(m.hasConflicts)
    }
    func testRemoteDeleted() {
        XCTAssertEqual(SyncPlanner.decide(state(local: "a\nb", remote: nil)), .remoteDeleted(hasLocalEdits: false))
        XCTAssertEqual(SyncPlanner.decide(state(local: "x", remote: nil)), .remoteDeleted(hasLocalEdits: true))
    }
    func testBackoff() {
        XCTAssertEqual(Backoff.delay(attempt: 0), 2)
        XCTAssertEqual(Backoff.delay(attempt: 3), 16)
        XCTAssertEqual(Backoff.delay(attempt: 20), 300)
    }

    func testPathValidation() throws {
        XCTAssertEqual(try RepoPath.validate("docs//a.md"), "docs/a.md")
        XCTAssertThrowsError(try RepoPath.validate("../etc/passwd"))
        XCTAssertThrowsError(try RepoPath.validate("/abs.md"))
        XCTAssertThrowsError(try RepoPath.validate("a/.git/config"))
        XCTAssertThrowsError(try RepoPath.validate(""))
        XCTAssertThrowsError(try RepoPath.validate("a\u{0}b.md"))
    }
    func testIsNote() {
        XCTAssertTrue(RepoPath.isNote("a/B.MD"))
        XCTAssertTrue(RepoPath.isNote("x.txt"))
        XCTAssertFalse(RepoPath.isNote("x.png"))
    }
    func testParseRepository() {
        XCTAssertEqual(RepoPath.parseRepository("https://github.com/apple/swift.git")?.name, "swift")
        XCTAssertEqual(RepoPath.parseRepository("apple/swift")?.owner, "apple")
        XCTAssertEqual(RepoPath.parseRepository("git@github.com:a/b")?.name, "b")
        XCTAssertNil(RepoPath.parseRepository("justone"))
        XCTAssertNil(RepoPath.parseRepository("a/b c"))
    }
}
