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

## Automated setup

`scripts/setup-github.sh` (needs the GitHub CLI, signed in with admin rights on the repo) does everything except the one step GitHub only allows in the browser:

```sh
scripts/setup-github.sh                         # opens the pre-filled OAuth App page; tick "Enable Device Flow"
scripts/setup-github.sh --client-id Iv1.xxxx    # stores NOTES_GITHUB_CLIENT_ID so every release bundles sign-in
scripts/setup-github.sh --cert c.p12 --cert-password PW --profile p.mobileprovision   # optional: signed .ipa
```

The Release workflow warns if the client ID is missing, and bakes it into the `nbwsc` bundle when present. Client IDs are public identifiers; secrets never enter git.

## Entering the Client ID inside the app

No rebuild needed: open **Settings** (or the **GitHub** tab), follow the three steps in the "One-time setup" card, and paste the Client ID. It's stored on the device and overrides any ID built into the app.
