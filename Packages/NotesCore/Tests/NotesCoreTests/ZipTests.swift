import XCTest
@testable import NotesCore

final class ZipTests: XCTestCase {
    func testCRC32KnownVector() {
        XCTAssertEqual(ZipWriter.crc32(Data("123456789".utf8)), 0xCBF43926)
    }
    func testArchiveStructure() {
        var z = ZipWriter()
        z.add(path: "../evil/a.md", data: Data("hello".utf8))
        z.add(path: "b.md", data: Data("x".utf8))
        let d = z.finish()
        XCTAssertEqual(Array(d.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
        XCTAssertEqual(Array(d.suffix(22).prefix(4)), [0x50, 0x4b, 0x05, 0x06])
        XCTAssertEqual(d.suffix(22)[d.suffix(22).startIndex + 10], 2) // entry count
        XCTAssertNotNil(d.range(of: Data("evil/a.md".utf8)))
        XCTAssertNil(d.range(of: Data("../".utf8)))
    }
}
