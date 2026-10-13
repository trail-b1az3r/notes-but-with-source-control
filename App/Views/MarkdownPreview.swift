import SwiftUI

/// Readable rendering of Markdown source. Source stays untouched; checkbox taps edit only the tapped line.
struct MarkdownPreview: View {
    let source: String
    var toggleLine: (Int) -> Void

    private enum Block: Identifiable {
        case heading(Int, String, Int), bullet(String, Int), number(String, String, Int), check(Bool, String, Int)
        case quote(String, Int), code(String, Int), para(String, Int), rule(Int)
        var id: Int {
            switch self {
            case .heading(_, _, let i), .bullet(_, let i), .number(_, _, let i), .check(_, _, let i),
                 .quote(_, let i), .code(_, let i), .para(_, let i), .rule(let i): return i
            }
        }
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var inCode = false
        var code: [String] = [], codeStart = 0
        for (i, raw) in source.components(separatedBy: "\n").enumerated() {
            let line = raw
            if line.hasPrefix("```") {
                if inCode { out.append(.code(code.joined(separator: "\n"), codeStart)); code = []; inCode = false }
                else { inCode = true; codeStart = i }
                continue
            }
            if inCode { code.append(line); continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if let h = t.firstIndex(where: { $0 != "#" }), t.hasPrefix("#"), t[h] == " ", t.distance(from: t.startIndex, to: h) <= 6 {
                out.append(.heading(t.distance(from: t.startIndex, to: h), String(t[t.index(after: h)...]), i))
            } else if t.hasPrefix("- [ ] ") || t.hasPrefix("* [ ] ") { out.append(.check(false, String(t.dropFirst(6)), i)) }
            else if t.lowercased().hasPrefix("- [x] ") || t.lowercased().hasPrefix("* [x] ") { out.append(.check(true, String(t.dropFirst(6)), i)) }
            else if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") { out.append(.bullet(String(t.dropFirst(2)), i)) }
            else if let dot = t.firstIndex(of: "."), Int(t[..<dot]) != nil, t[t.index(after: dot)...].hasPrefix(" ") {
                out.append(.number(String(t[..<dot]), String(t[t.index(after: dot)...]).trimmingCharacters(in: .whitespaces), i))
            } else if t.hasPrefix(">") { out.append(.quote(String(t.dropFirst()).trimmingCharacters(in: .whitespaces), i)) }
            else if t == "---" || t == "***" { out.append(.rule(i)) }
            else { out.append(.para(t, i)) }
        }
        if inCode { out.append(.code(code.joined(separator: "\n"), codeStart)) }
        return out
    }

    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { return Text(a) }
        return Text(s)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(blocks) { b in
                    switch b {
                    case .heading(let l, let t, _):
                        inline(t).font(l == 1 ? .title.bold() : l == 2 ? .title2.bold() : .title3.bold()).accessibilityAddTraits(.isHeader)
                    case .bullet(let t, _): HStack(alignment: .firstTextBaseline) { Text("•"); inline(t) }
                    case .number(let n, let t, _): HStack(alignment: .firstTextBaseline) { Text("\(n)."); inline(t) }
                    case .check(let done, let t, let i):
                        Button { toggleLine(i) } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? Color.accentColor : .secondary)
                                inline(t).strikethrough(done).foregroundStyle(done ? .secondary : .primary)
                            }
                        }.buttonStyle(.plain).accessibilityLabel(t).accessibilityValue(done ? "Completed" : "Not completed")
                    case .quote(let t, _):
                        HStack { Rectangle().fill(.secondary.opacity(0.5)).frame(width: 3); inline(t).foregroundStyle(.secondary) }
                    case .code(let c, _):
                        ScrollView(.horizontal) { Text(c).font(.system(.callout, design: .monospaced)).padding(10) }
                            .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    case .para(let t, _): inline(t)
                    case .rule: Divider()
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
