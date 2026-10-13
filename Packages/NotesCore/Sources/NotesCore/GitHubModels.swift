import Foundation

public struct GHUser: Codable, Equatable, Sendable {
    public let login: String
    public let id: Int
    public let name: String?
    public let avatarUrl: URL?
}

public struct GHRepo: Codable, Equatable, Sendable, Identifiable {
    public struct Owner: Codable, Equatable, Sendable { public let login: String }
    public struct Permissions: Codable, Equatable, Sendable {
        public let admin: Bool?, push: Bool?, pull: Bool?
    }
    public let id: Int
    public let name: String
    public let fullName: String
    public let owner: Owner
    public let `private`: Bool
    public let description: String?
    public let defaultBranch: String?
    public let permissions: Permissions?
    public let pushedAt: Date?
    public let htmlUrl: URL?
    public var canPush: Bool { permissions?.push ?? false }
}

public struct GHBranch: Codable, Equatable, Sendable, Identifiable {
    public struct Commit: Codable, Equatable, Sendable { public let sha: String }
    public let name: String
    public let commit: Commit
    public var id: String { name }
}

public struct GHContentItem: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let path: String
    public let sha: String
    public let size: Int
    public let type: String // file, dir, symlink, submodule
    public var id: String { path }
    public var isDirectory: Bool { type == "dir" }
    public var isRegularFile: Bool { type == "file" }
}

struct GHFileResponse: Codable {
    let name: String, path: String, sha: String, size: Int, type: String
    let content: String?
    let encoding: String?
}

public struct RemoteFile: Equatable, Sendable {
    public let path: String
    public let sha: String
    public let size: Int
    public let data: Data
    /// nil when the file is not valid UTF-8 (binary or unsupported encoding).
    public var text: String? { String(data: data, encoding: .utf8) }
}

public struct GHCommitSummary: Codable, Equatable, Sendable, Identifiable {
    public struct Inner: Codable, Equatable, Sendable {
        public struct Person: Codable, Equatable, Sendable { public let name: String; public let date: Date? }
        public let message: String
        public let author: Person?
    }
    public struct Author: Codable, Equatable, Sendable { public let login: String? }
    public let sha: String
    public let commit: Inner
    public let author: Author?
    public var id: String { sha }
    public var shortSHA: String { String(sha.prefix(7)) }
    public var headline: String { commit.message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "" }
    public var authorName: String { author?.login ?? commit.author?.name ?? "Unknown" }
    public var date: Date? { commit.author?.date }
}

public struct GHCommitDetail: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public let filename: String
        public let status: String
        public let additions: Int
        public let deletions: Int
        public let patch: String?
        public let previousFilename: String?
    }
    public let sha: String
    public let files: [File]?
}

public struct GHWriteResult: Equatable, Sendable {
    public let commitSHA: String
    public let blobSHA: String?
}

struct GHWriteResponse: Codable {
    struct Commit: Codable { let sha: String }
    struct Content: Codable { let sha: String }
    let commit: Commit
    let content: Content?
}

struct GHRef: Codable { struct Obj: Codable { let sha: String }; let object: Obj }
