import XCTest
@testable import NotesCore

final class DiffAndMergeTests: XCTestCase {
    func testDiffIdentical() {
        let d = LineDiff.diff(old: "a\nb", new: "a\nb")
        XCTAssertTrue(LineDiff.summary(d).isEmpty)
    }

    func testDiffAddRemove() {
        let d = LineDiff.diff(old: "a\nb\nc", new: "a\nc\nd")
        let s = LineDiff.summary(d)
        XCTAssertEqual(s.added, 1)
        XCTAssertEqual(s.removed, 1)
        XCTAssertEqual(d.filter { $0.kind == .removed }.map(\.text), ["b"])
        XCTAssertEqual(d.filter { $0.kind == .added }.map(\.text), ["d"])
    }

    func testDiffLineNumbers() {
        let d = LineDiff.diff(old: "a\nb", new: "a\nx\nb")
        let added = d.first { $0.kind == .added }
        XCTAssertEqual(added?.newNumber, 2)
        XCTAssertNil(added?.oldNumber)
    }

    func testCollapseKeepsContext() {
        let old = (1...20).map(String.init).joined(separator: "\n")
        let new = old.replacingOccurrences(of: "10", with: "ten")
        let c = LineDiff.collapse(LineDiff.diff(old: old, new: new), context: 2)
        XCTAssertEqual(c.count, 2 + 2 + 2) // 2 before, removed+added, 2 after
    }

    func testMergeNonOverlappingIsClean() {
        let base = "one\ntwo\nthree\nfour\nfive"
        let local = "ONE\ntwo\nthree\nfour\nfive"
        let remote = "one\ntwo\nthree\nfour\nFIVE"
        let r = ThreeWayMerge.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(r.cleanText, "ONE\ntwo\nthree\nfour\nFIVE")
    }

    func testMergeSameEditBothSidesIsClean() {
        let r = ThreeWayMerge.merge(base: "a\nb", local: "a\nX", remote: "a\nX")
        XCTAssertEqual(r.cleanText, "a\nX")
    }

    func testMergeOverlappingConflicts() {
        let r = ThreeWayMerge.merge(base: "a\nb\nc", local: "a\nL\nc", remote: "a\nR\nc")
        XCTAssertTrue(r.hasConflicts)
        XCTAssertNil(r.cleanText)
        XCTAssertTrue(r.textWithMarkers().contains("<<<<<<<"))
        XCTAssertEqual(r.segments.last, .resolved(["c"]))
    }

    func testMergeOneSideOnly() {
        let r = ThreeWayMerge.merge(base: "a\nb", local: "a\nb", remote: "a\nb\nc")
        XCTAssertEqual(r.cleanText, "a\nb\nc")
    }

    func testMergeInsertionsAtSamePointDiffer() {
        let r = ThreeWayMerge.merge(base: "a\nz", local: "a\nL\nz", remote: "a\nR\nz")
        XCTAssertTrue(r.hasConflicts)
    }

    func testLargeInputFallsBackWithoutHanging() {
        let a = (0..<3000).map { "a\($0)" }.joined(separator: "\n")
        let b = (0..<3000).map { "b\($0)" }.joined(separator: "\n")
        let d = LineDiff.diff(old: a, new: b)
        XCTAssertEqual(LineDiff.summary(d).added, 3000)
    }
}
