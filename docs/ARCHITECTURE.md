# Architecture

```
Packages/NotesCore   pure Swift, no UI, unit-tested (swift test)
  Diff.swift            LCS line diff, summary, context collapsing
  ThreeWayMerge.swift   diff3 merge; conflicts only when edits overlap/touch and differ
  SyncDecision.swift    SyncPlanner: (base, local, remote) -> upToDate/push/pull/adopt/autoMerge/conflict/remoteDeleted; Backoff
  GitHubClient.swift    REST client over an HTTPTransport protocol (mockable); error mapping, rate limits, GET retry
  DeviceFlowAuth.swift  OAuth device flow
  PathValidator.swift   repo path/URL validation (no traversal, .git, control chars)
  ZipWriter.swift       store-only ZIP for backups
App/                  SwiftUI + SwiftData
  Support/Models.swift  Note, Folder, LocalRevision, RepoConnection (@Model)
  Support/SyncService   local-first sync, conflict resolution, file operations
  Support/AppModel      auth state, connectivity, Keychain-backed client
  Views/                Notes, Folders, Repositories, Settings, editor, history/diff/commit/conflict
```

## Key decisions

- **Local DB is the source of truth for unsynced edits.** A note's repo state is `baseSHA` + `baseContent` (what GitHub last confirmed) next to `body` (local). "Pending" is simply `body != baseContent`; nothing is marked synced until GitHub returns the new blob SHA.
- **Safe writes:** every update sends the remote blob SHA it was based on. Before pushing, the current remote is fetched and `SyncPlanner` decides; a stale SHA (409/422) triggers one re-plan, never an overwrite.
- **Conflicts:** both sides kept (`conflictRemoteContent/SHA`), a recovery `LocalRevision` is written first, and the user picks mine / GitHub's / manual merge. Discarding edits needs confirmation.
- **Stable identity:** `Note.id` is a UUID; path/branch are mutable fields, repo ID is stored.
- **Commits:** Contents API (one commit per file). History is `GET /commits?path=`, versions are fetched at a commit SHA, restore sets the content and creates a new commit.
- **Auth:** device flow, token in Keychain (`AfterFirstUnlockThisDeviceOnly`), 401 signs out gracefully.
- **Editor:** UITextView wrapped for SwiftUI (selection-aware formatting, undo, system find). Notes are Markdown source; files keep their original bytes/format (no reformatting).
- **Safety:** note contents are never logged; repository paths validated before any request; non-UTF-8 and >1 MB files are refused with an explanation; disconnect/detach never deletes remote data.
