# GitHub sign-in setup

Notes: uses GitHub's **OAuth device flow**: the supported flow for apps that cannot keep a client secret. The app shows a code, you approve it at github.com/login/device, and the app polls for a token. The token is stored in the iOS Keychain. No client secret exists in the app or repo.

1. GitHub → Settings → Developer settings → OAuth Apps → **New OAuth App**.
   - Name: anything. Homepage URL: your repo URL. Callback URL: any valid URL (unused by device flow), e.g. the homepage.
2. Open the app's page and tick **Enable Device Flow**.
3. Copy the **Client ID** (a public identifier, not a secret).
4. Local builds: put it in `Config/Local.xcconfig` as `GITHUB_CLIENT_ID = ...`.
   Released builds: add a repository *variable* `NOTES_GITHUB_CLIENT_ID`.

Scopes requested: `public_repo` (public repositories only) or `repo` (adds private repositories; GitHub offers no narrower scope for OAuth Apps). Users choose in Settings before signing in. Organizations with OAuth app restrictions must approve the app.

Sign out deletes the local token. To revoke the grant on GitHub, use github.com/settings/applications.
