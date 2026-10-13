import Foundation

/// Minimal store-only (uncompressed) ZIP writer, used for backups and exports.
public struct ZipWriter {
    private struct Entry { let name: [UInt8]; let crc: UInt32; let size: UInt32; let offset: UInt32 }
    private var body = Data()
    private var entries: [Entry] = []

    public init() {}

    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    private static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }

    /// Adds a file. `path` is sanitized so archives can't contain traversal entries.
    public mutating func add(path: String, data: Data) {
        let safe = path.split(separator: "/").map(String.init).filter { $0 != ".." && $0 != "." && !$0.isEmpty }.joined(separator: "/")
        let name = Array(safe.utf8)
        let crc = Self.crc32(data)
        let e = Entry(name: name, crc: crc, size: UInt32(data.count), offset: UInt32(body.count))
        var h: [UInt8] = Self.le32(0x04034b50) + Self.le16(20) + Self.le16(0x0800) + Self.le16(0)
        h += Self.le16(0) + Self.le16(0x0021) + Self.le32(crc) + Self.le32(e.size) + Self.le32(e.size)
        h += Self.le16(UInt16(name.count)) + Self.le16(0)
        body.append(contentsOf: h); body.append(contentsOf: name); body.append(data)
        entries.append(e)
    }

    public func finish() -> Data {
        var out = body
        let cdStart = out.count
        for e in entries {
            var h: [UInt8] = Self.le32(0x02014b50) + Self.le16(20) + Self.le16(20) + Self.le16(0x0800) + Self.le16(0)
            h += Self.le16(0) + Self.le16(0x0021) + Self.le32(e.crc) + Self.le32(e.size) + Self.le32(e.size)
            h += Self.le16(UInt16(e.name.count)) + Self.le16(0) + Self.le16(0) + Self.le16(0) + Self.le16(0)
            h += Self.le32(0) + Self.le32(e.offset)
            out.append(contentsOf: h); out.append(contentsOf: e.name)
        }
        let cdSize = out.count - cdStart
        var end: [UInt8] = Self.le32(0x06054b50) + Self.le16(0) + Self.le16(0)
        end += Self.le16(UInt16(entries.count)) + Self.le16(UInt16(entries.count))
        end += Self.le32(UInt32(cdSize)) + Self.le32(UInt32(cdStart)) + Self.le16(0)
        out.append(contentsOf: end)
        return out
    }
}
