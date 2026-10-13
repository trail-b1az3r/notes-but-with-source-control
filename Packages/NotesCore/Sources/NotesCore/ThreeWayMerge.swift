import Foundation

public enum MergeSegment: Equatable, Sendable {
    case resolved([String])
    case conflict(base: [String], local: [String], remote: [String])
}

public struct MergeResult: Equatable, Sendable {
    public let segments: [MergeSegment]
    public var hasConflicts: Bool {
        segments.contains { if case .conflict = $0 { return true } else { return false } }
    }
    /// The merged text; nil when conflicts remain.
    public var cleanText: String? {
        guard !hasConflicts else { return nil }
        return segments.flatMap { s -> [String] in
            if case .resolved(let l) = s { return l } else { return [] }
        }.joined(separator: "\n")
    }
    /// Text with git-style conflict markers, for manual resolution.
    public func textWithMarkers(localLabel: String = "Your changes", remoteLabel: String = "GitHub") -> String {
        segments.flatMap { s -> [String] in
            switch s {
            case .resolved(let l): return l
            case .conflict(_, let local, let remote):
                return ["<<<<<<< \(localLabel)"] + local + ["======="] + remote + [">>>>>>> \(remoteLabel)"]
            }
        }.joined(separator: "\n")
    }
}

public enum ThreeWayMerge {
    /// Line-based diff3. Overlapping or touching edits that differ are reported as conflicts;
    /// identical edits on both sides merge cleanly.
    public static func merge(base: String, local: String, remote: String) -> MergeResult {
        let b = TextLines.split(base)
        let lh = LineDiff.hunks(b, TextLines.split(local))
        let rh = LineDiff.hunks(b, TextLines.split(remote))
        let all = (lh.map { (0, $0) } + rh.map { (1, $0) })
            .sorted { ($0.1.start, $0.1.end, $0.0) < ($1.1.start, $1.1.end, $1.0) }

        var segments: [MergeSegment] = []
        var pending: [String] = []
        func flush() { if !pending.isEmpty { segments.append(.resolved(pending)); pending = [] } }

        var pos = 0, idx = 0
        while idx < all.count {
            var cluster = [all[idx]]
            var cEnd = all[idx].1.end
            idx += 1
            while idx < all.count, all[idx].1.start <= cEnd {
                cluster.append(all[idx]); cEnd = max(cEnd, all[idx].1.end); idx += 1
            }
            let cStart = cluster[0].1.start
            pending += b[pos..<cStart]
            let sides = Set(cluster.map(\.0))
            func apply(_ side: Int) -> [String] {
                var out: [String] = [], p = cStart
                for (s, h) in cluster where s == side {
                    out += b[p..<h.start]; out += h.lines; p = h.end
                }
                out += b[p..<cEnd]
                return out
            }
            if sides.count == 1 {
                pending += apply(sides.first!)
            } else {
                let l = apply(0), r = apply(1)
                if l == r {
                    pending += l
                } else {
                    flush()
                    segments.append(.conflict(base: Array(b[cStart..<cEnd]), local: l, remote: r))
                }
            }
            pos = cEnd
        }
        pending += b[pos...]
        flush()
        return MergeResult(segments: segments)
    }
}
