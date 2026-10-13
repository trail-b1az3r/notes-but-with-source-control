import SwiftUI
import UIKit

/// Lets SwiftUI toolbars drive the underlying UITextView (selection-aware formatting, undo/redo, find).
@MainActor final class EditorController: ObservableObject {
    weak var textView: UITextView?

    func wrap(_ marker: String) {
        guard let tv = textView, let range = tv.selectedTextRange else { return }
        let selected = tv.text(in: range) ?? ""
        tv.replace(range, withText: marker + selected + marker)
        if selected.isEmpty, let pos = tv.position(from: range.start, offset: marker.count) {
            tv.selectedTextRange = tv.textRange(from: pos, to: pos)
        }
        notify()
    }

    /// Toggles a prefix on every selected line (e.g. "- ", "1. ", "> ", "# ", "- [ ] ").
    func prefixLines(_ prefix: String) {
        guard let tv = textView else { return }
        let ns = tv.text as NSString
        let lineRange = ns.lineRange(for: tv.selectedRange)
        let block = ns.substring(with: lineRange)
        let trailingNewline = block.hasSuffix("\n")
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let body = trailingNewline ? Array(lines.dropLast()) : lines
        let allHave = body.allSatisfy { $0.hasPrefix(prefix) }
        let out = body.map { allHave ? String($0.dropFirst(prefix.count)) : prefix + $0 }
            .joined(separator: "\n") + (trailingNewline ? "\n" : "")
        if let start = tv.position(from: tv.beginningOfDocument, offset: lineRange.location),
           let end = tv.position(from: start, offset: lineRange.length), let r = tv.textRange(from: start, to: end) {
            tv.replace(r, withText: out)
        }
        notify()
    }

    func codeBlock() {
        guard let tv = textView, let range = tv.selectedTextRange else { return }
        tv.replace(range, withText: "```\n" + (tv.text(in: range) ?? "") + "\n```")
        notify()
    }

    func link() {
        guard let tv = textView, let range = tv.selectedTextRange else { return }
        let sel = tv.text(in: range) ?? ""
        tv.replace(range, withText: "[\(sel.isEmpty ? "text" : sel)](https://)")
        notify()
    }

    func undo() { textView?.undoManager?.undo(); notify() }
    func redo() { textView?.undoManager?.redo(); notify() }
    func find() { textView?.findInteraction?.presentFindNavigator(showingReplace: false) }
    func dismissKeyboard() { textView?.resignFirstResponder() }
    private func notify() { textView.map { NotificationCenter.default.post(name: UITextView.textDidChangeNotification, object: $0) } }
}

struct EditorTextView: UIViewRepresentable {
    @Binding var text: String
    var monospaced: Bool
    var controller: EditorController
    var onChange: () -> Void

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.isFindInteractionEnabled = true
        tv.alwaysBounceVertical = true
        tv.keyboardDismissMode = .interactive
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 24, right: 12)
        tv.autocorrectionType = monospaced ? .no : .default
        tv.autocapitalizationType = monospaced ? .none : .sentences
        tv.adjustsFontForContentSizeCategory = true
        tv.font = Self.font(monospaced)
        tv.text = text
        tv.backgroundColor = .clear
        controller.textView = tv
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        controller.textView = tv
        if tv.text != text { tv.text = text } // external change (pull, restore, merge)
        tv.font = Self.font(monospaced)
    }

    static func font(_ mono: Bool) -> UIFont {
        mono ? UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular))
             : .preferredFont(forTextStyle: .body)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let parent: EditorTextView
        init(_ p: EditorTextView) { parent = p }
        func textViewDidChange(_ tv: UITextView) {
            if parent.text != tv.text { parent.text = tv.text; parent.onChange() }
        }
    }
}
