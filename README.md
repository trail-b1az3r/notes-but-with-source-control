# Notes:

Apple Notes meets GitHub. A native SwiftUI iPhone app (iOS 26 and newer; targets iOS 27 automatically once the build machine has the iOS 27 SDK) for local-first notes that can be linked to files in GitHub repositories, with real commits, history, diffs, offline editing and conflict resolution.

> **Status:** the source was written without access to Xcode, so it has **not yet been compiled or run on a device**. The first CI run on a macOS runner is the first real build — see [Status](#status).

## Releasing (GitHub Actions)

The bundle is always named `nbwsc-vX.Y.Z.ipa` (plus a `.sha256`). Two ways to get it:

- **Automatic bundle on release:** publish a release on GitHub (Releases → Draft a new release, with a tag like `v1.2.0`) and the workflow builds that tag and attaches the bundle to your release.
- **One-click release:** Actions → **Release** → *Run workflow*. It will:

1. compute the next version from the latest `vX.Y.Z` tag (patch/minor/major, or type an explicit version) and refuse to reuse a tag,
2. run the unit tests,
3. archive the app and package an `.ipa`,
4. create the git tag and a GitHub Release with generated release notes, the `.ipa`, and its SHA-256.

**Unsigned by default.** Without signing secrets the `.ipa` is unsigned; re-sign it with AltStore/Sideloadly or build in Xcode. To produce a signed `.ipa`, add these (Settings → Secrets and variables → Actions):

| Kind | Name | Value |
|---|---|---|
| secret | `IOS_CERT_P12_BASE64` | `base64 -i cert.p12` of your signing certificate |
| secret | `IOS_CERT_PASSWORD` | password of the `.p12` |
| secret | `IOS_PROFILE_BASE64` | `base64 -i profile.mobileprovision` |
| variable | `NOTES_BUNDLE_ID` | bundle ID matching the profile (default `app.notes.Notes`) |
| variable | `NOTES_EXPORT_METHOD` | `ad-hoc` (default), `development`, `app-store` |
| variable | `NOTES_SIGNING_IDENTITY` | default `Apple Distribution` (use `Apple Development` for development profiles) |
| variable | `NOTES_GITHUB_CLIENT_ID` | OAuth client ID so sign-in works in released builds |

`CI` (`.github/workflows/ci.yml`) runs the tests and an unsigned build on every push and PR.

## Build and run locally

Requires Xcode 26+ (Xcode 27 for the iOS 27 SDK) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # set GITHUB_CLIENT_ID, APP_BUNDLE_ID, DEVELOPMENT_TEAM
xcodegen generate
open Notes.xcodeproj
```

Run on an iPhone: plug it in, enable Developer Mode, pick it as the destination, and set your Team under *Signing & Capabilities* (or in `Local.xcconfig`). A free Apple ID works (7-day certificates). Installing on a device needs a signing identity; none is included.

Tests: `swift test --package-path Packages/NotesCore` (no GitHub account needed; all HTTP is mocked).

## GitHub sign-in setup

Quickest: `scripts/setup-github.sh` (see below / docs).

See [docs/GITHUB_SETUP.md](docs/GITHUB_SETUP.md). Short version: register an OAuth App, tick **Enable Device Flow**, put its client ID in `Local.xcconfig`. No secret is ever in the app. Without a client ID the app works fully offline and says so in Settings.

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Status

Implemented (written, unit-tested in logic, not yet compiled):

- Local notes, folders (nested, smart folders), pin, search (debounced), sort, multi-select, trash, import/export Markdown, ZIP backup
- Markdown source editor (UITextView): toolbar, undo/redo, find, word count; rendered reading mode with tappable checklists
- GitHub device-flow sign-in, token in Keychain, graceful expiry handling
- Repo picker / URL entry / create repository (explicit public/private confirmation), directory browser, branches (list/switch/create), commits and per-commit file patches
- File-linked notes and repository workspaces; base snapshot + remote blob SHA stored per note
- Real commits via the Contents API; manual (review + message) and automatic (idle-debounced) workflows; commit message template
- Three-way merge, auto-merge of non-overlapping edits, conflict screen (keep mine / use GitHub's / manual merge), recovery revisions
- Offline editing, reconnect-triggered sync, exponential backoff, rate-limit/auth error mapping
- History per file, diff viewer, restore-by-new-commit, separate local edit history
- Move/rename (create + delete), delete remote file (confirmed), disconnect without deleting anything

Not implemented / limitations:

- **Rich text and attachments:** notes are Markdown text; no inline images/files or tables UI. Formatting is Markdown syntax, with a reading mode.
- **Multi-file commits:** each file is its own commit (Contents API). A single atomic multi-file commit would need the Git Data API.
- **Rename** is two commits (create + delete); no `git mv` history link.
- **Token revocation:** GitHub only allows revoking with a client secret, so Sign Out removes the local token; revoke access at github.com/settings/applications.
- **Remote search** (GitHub code search) is not implemented; search covers notes on the device.
- **Private repos** require the `repo` scope (GitHub has no narrower one for OAuth Apps).
- No background sync (iOS doesn't guarantee it); pending changes sync while the app is open.
- No UI tests; app-layer (SwiftUI/SwiftData) code is not unit-tested, only `NotesCore`.
- Large repositories: directory listings are fetched per folder (lazy), not paginated within a folder.
