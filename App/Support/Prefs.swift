import Foundation

enum Prefs {
    static let autoSyncKey = "autoSync"
    static let templateKey = "commitTemplate"
    static let defaultTemplate = "Update {{file}} from Notes:"

    static var autoSync: Bool { UserDefaults.standard.bool(forKey: autoSyncKey) }
    static var commitTemplate: String {
        let t = UserDefaults.standard.string(forKey: templateKey) ?? ""
        return t.isEmpty ? defaultTemplate : t
    }

    /// Placeholders: {{file}}, {{title}}, {{date}}
    static func commitMessage(for note: Note) -> String {
        commitTemplate
            .replacingOccurrences(of: "{{file}}", with: note.path.map { ($0 as NSString).lastPathComponent } ?? note.title)
            .replacingOccurrences(of: "{{title}}", with: note.title)
            .replacingOccurrences(of: "{{date}}", with: Date.now.formatted(date: .abbreviated, time: .shortened))
    }
}
