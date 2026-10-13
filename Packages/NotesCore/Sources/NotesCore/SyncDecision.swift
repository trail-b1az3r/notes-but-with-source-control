import Foundation

/// Everything needed to decide what to do with one file-linked note.
public struct FileSyncState: Equatable, Sendable {
    public var baseContent: String
    public var baseSHA: String?
    public var localContent: String
    /// nil means the file no longer exists remotely.
    public var remote: RemoteSnapshot?

    public init(baseContent: String, baseSHA: String?, localContent: String, remote: RemoteSnapshot?) {
        self.baseContent = baseContent; self.baseSHA = baseSHA
        self.localContent = localContent; self.remote = remote
    }
}

public struct RemoteSnapshot: Equatable, Sendable {
    public var sha: String
    public var content: String
    public init(sha: String, content: String) { self.sha = sha; self.content = content }
}

public enum SyncDecision: Equatable, Sendable {
    case upToDate
    /// Local edits only: safe to commit using the remote blob SHA as the base.
    case push
    /// Remote changes only: safe to fast-forward the local copy.
    case pull(RemoteSnapshot)
    /// Both sides changed to identical content; just advance the base.
    case adoptRemote(RemoteSnapshot)
    /// Both changed in non-overlapping ways. Apply `merged` locally, then push.
    case autoMerge(merged: String, remote: RemoteSnapshot)
    case conflict(MergeResult, remote: RemoteSnapshot)
    case remoteDeleted(hasLocalEdits: Bool)
}

public enum SyncPlanner {
    public static func decide(_ s: FileSyncState) -> SyncDecision {
        let localChanged = s.localContent != s.baseContent
        guard let remote = s.remote else { return .remoteDeleted(hasLocalEdits: localChanged) }
        let remoteChanged = remote.sha != s.baseSHA
        switch (localChanged, remoteChanged) {
        case (false, false): return .upToDate
        case (true, false): return .push
        case (false, true): return .pull(remote)
        case (true, true):
            if s.localContent == remote.content { return .adoptRemote(remote) }
            let m = ThreeWayMerge.merge(base: s.baseContent, local: s.localContent, remote: remote.content)
            if let text = m.cleanText { return .autoMerge(merged: text, remote: remote) }
            return .conflict(m, remote: remote)
        }
    }
}

/// Backoff schedule for retrying failed sync operations.
public enum Backoff {
    public static func delay(attempt: Int, base: TimeInterval = 2, cap: TimeInterval = 300) -> TimeInterval {
        min(cap, base * pow(2, Double(max(0, attempt))))
    }
}
