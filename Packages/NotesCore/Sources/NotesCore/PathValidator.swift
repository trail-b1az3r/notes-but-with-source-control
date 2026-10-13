import Foundation

public enum PathValidationError: Error, Equatable {
    case empty, traversal, absolute, invalidCharacters, tooLong
}

public enum RepoPath {
    public static let noteExtensions: Set<String> = ["md", "markdown", "txt"]
    public static let maxNoteBytes = 1_000_000 // GitHub contents API limit for inline content

    /// Normalizes and validates a repository-relative path. Rejects traversal, absolute paths and control characters.
    public static func validate(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw PathValidationError.empty }
        guard trimmed.count <= 1024 else { throw PathValidationError.tooLong }
        guard !trimmed.hasPrefix("/") else { throw PathValidationError.absolute }
        guard !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0 == "\\" }) else {
            throw PathValidationError.invalidCharacters
        }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { throw PathValidationError.empty }
        guard !parts.contains(where: { $0 == ".." || $0 == "." || $0.lowercased() == ".git" }) else {
            throw PathValidationError.traversal
        }
        return parts.joined(separator: "/")
    }

    public static func isNote(_ path: String) -> Bool {
        noteExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    public static func percentEncoded(_ path: String) -> String {
        path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? String($0)
        }.joined(separator: "/")
    }

    /// Parses "owner/name", "https://github.com/owner/name(.git)" and similar. Validates the characters GitHub allows.
    public static func parseRepository(_ input: String) -> (owner: String, name: String)? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://github.com/", "http://github.com/", "github.com/", "git@github.com:"] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count); break
        }
        if s.hasSuffix(".git") { s.removeLast(4) }
        let parts = s.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let ok = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        for p in parts.prefix(2) {
            guard !p.isEmpty, p.unicodeScalars.allSatisfy({ ok.contains($0) }) else { return nil }
        }
        return (parts[0], parts[1])
    }
}
