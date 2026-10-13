import Foundation

public enum DiffLineKind: Sendable { case context, added, removed }

public struct DiffLine: Equatable, Sendable, Identifiable {
    public let id: Int
    public let kind: DiffLineKind
    public let text: String
    public let oldNumber: Int?
    public let newNumber: Int?
}

public struct DiffSummary: Equatable, Sendable {
    public let added: Int
    public let removed: Int
    public var isEmpty: Bool { added == 0 && removed == 0 }
    public var description: String {
        isEmpty ? "No changes" : "+\(added) −\(removed)"
    }
}

enum Edit: Equatable {
    case equal(Int, Int)
    case delete(Int)
    case insert(Int)
}

/// A replacement of `base[start..<end]` with `lines`.
struct Hunk: Equatable {
    var start: Int
    var end: Int
    var lines: [String]
}

public enum TextLines {
    public static func split(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}

public enum LineDiff {
    /// Maximum LCS table size before falling back to a whole-block replace.
    static let tableLimit = 4_000_000

    static func edits(_ a: [String], _ b: [String]) -> [Edit] {
        var pre = 0
        while pre < a.count, pre < b.count, a[pre] == b[pre] { pre += 1 }
        var suf = 0
        while suf < a.count - pre, suf < b.count - pre,
              a[a.count - 1 - suf] == b[b.count - 1 - suf] { suf += 1 }
        let am = Array(a[pre..<(a.count - suf)])
        let bm = Array(b[pre..<(b.count - suf)])
        let n = am.count, m = bm.count
        var out: [Edit] = (0..<pre).map { .equal($0, $0) }

        if n * m > tableLimit {
            out += (0..<n).map { .delete(pre + $0) }
            out += (0..<m).map { .insert(pre + $0) }
        } else {
            let w = m + 1
            var t = [UInt32](repeating: 0, count: (n + 1) * w)
            if n > 0, m > 0 {
                for i in stride(from: n - 1, through: 0, by: -1) {
                    for j in stride(from: m - 1, through: 0, by: -1) {
                        t[i * w + j] = am[i] == bm[j]
                            ? t[(i + 1) * w + j + 1] + 1
                            : max(t[(i + 1) * w + j], t[i * w + j + 1])
                    }
                }
            }
            var i = 0, j = 0
            while i < n, j < m {
                if am[i] == bm[j] {
                    out.append(.equal(pre + i, pre + j)); i += 1; j += 1
                } else if t[(i + 1) * w + j] >= t[i * w + j + 1] {
                    out.append(.delete(pre + i)); i += 1
                } else {
                    out.append(.insert(pre + j)); j += 1
                }
            }
            while i < n { out.append(.delete(pre + i)); i += 1 }
            while j < m { out.append(.insert(pre + j)); j += 1 }
        }
        for k in 0..<suf { out.append(.equal(a.count - suf + k, b.count - suf + k)) }
        return out
    }

    static func hunks(_ base: [String], _ other: [String]) -> [Hunk] {
        var result: [Hunk] = []
        var cur: Hunk?
        var aPos = 0
        for e in edits(base, other) {
            switch e {
            case .delete(let i):
                if cur == nil { cur = Hunk(start: i, end: i, lines: []) }
                cur!.end = i + 1
                aPos = i + 1
            case .insert(let j):
                if cur == nil { cur = Hunk(start: aPos, end: aPos, lines: []) }
                cur!.lines.append(other[j])
            case .equal(let i, _):
                if let c = cur { result.append(c); cur = nil }
                aPos = i + 1
            }
        }
        if let c = cur { result.append(c) }
        return result
    }

    public static func diff(old: String, new: String) -> [DiffLine] {
        let a = TextLines.split(old), b = TextLines.split(new)
        var lines: [DiffLine] = []
        var n = 0
        for e in edits(a, b) {
            switch e {
            case .equal(let i, let j):
                lines.append(DiffLine(id: n, kind: .context, text: a[i], oldNumber: i + 1, newNumber: j + 1))
            case .delete(let i):
                lines.append(DiffLine(id: n, kind: .removed, text: a[i], oldNumber: i + 1, newNumber: nil))
            case .insert(let j):
                lines.append(DiffLine(id: n, kind: .added, text: b[j], oldNumber: nil, newNumber: j + 1))
            }
            n += 1
        }
        return lines
    }

    public static func summary(_ lines: [DiffLine]) -> DiffSummary {
        DiffSummary(added: lines.filter { $0.kind == .added }.count,
                    removed: lines.filter { $0.kind == .removed }.count)
    }

    /// Keeps only changed lines plus `context` unchanged lines around them.
    public static func collapse(_ lines: [DiffLine], context: Int = 3) -> [DiffLine] {
        var keep = [Bool](repeating: false, count: lines.count)
        for (i, l) in lines.enumerated() where l.kind != .context {
            for k in max(0, i - context)...min(lines.count - 1, i + context) { keep[k] = true }
        }
        return lines.enumerated().filter { keep[$0.offset] }.map(\.element)
    }
}
