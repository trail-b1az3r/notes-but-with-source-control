#!/usr/bin/env bash
# One-shot GitHub setup for releases. Requires the GitHub CLI (`gh auth login` with repo admin rights).
#
#   scripts/setup-github.sh [--client-id Iv1.xxxx] [--cert cert.p12 --cert-password PW --profile app.mobileprovision]
#
# With no arguments it opens the pre-filled OAuth App registration page and tells you what to do next.
# Nothing secret is stored in git: values go to GitHub Actions variables/secrets only.
set -euo pipefail

CLIENT_ID="" CERT="" CERT_PW="" PROFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --client-id) CLIENT_ID="$2"; shift 2 ;;
    --cert) CERT="$2"; shift 2 ;;
    --cert-password) CERT_PW="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

command -v gh >/dev/null || { echo "Install the GitHub CLI first: https://cli.github.com" >&2; exit 1; }
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
OWNER_URL="https://github.com/$REPO"

if [ -z "$CLIENT_ID" ]; then
  URL="https://github.com/settings/applications/new?oauth_application%5Bname%5D=nbwsc&oauth_application%5Burl%5D=$OWNER_URL&oauth_application%5Bcallback_url%5D=$OWNER_URL"
  echo "1. Open this page (name/URL are pre-filled) and click Register application:"
  echo "   $URL"
  echo "2. On the app's page, tick 'Enable Device Flow' and save."
  echo "3. Copy the Client ID and run:  scripts/setup-github.sh --client-id <ID>"
  command -v open >/dev/null && open "$URL" || true
  command -v xdg-open >/dev/null && xdg-open "$URL" >/dev/null 2>&1 || true
else
  [[ "$CLIENT_ID" =~ ^[A-Za-z0-9._-]{8,40}$ ]] || { echo "That doesn't look like a GitHub client ID." >&2; exit 1; }
  gh variable set NOTES_GITHUB_CLIENT_ID --body "$CLIENT_ID" --repo "$REPO"
  echo "Set NOTES_GITHUB_CLIENT_ID: released builds will include GitHub sign-in."
fi

if [ -n "$CERT" ] || [ -n "$PROFILE" ]; then
  [ -f "$CERT" ] && [ -f "$PROFILE" ] && [ -n "$CERT_PW" ] || { echo "Signing needs --cert, --cert-password and --profile together." >&2; exit 1; }
  base64 < "$CERT" | tr -d '\n' | gh secret set IOS_CERT_P12_BASE64 --repo "$REPO"
  gh secret set IOS_CERT_PASSWORD --body "$CERT_PW" --repo "$REPO"
  base64 < "$PROFILE" | tr -d '\n' | gh secret set IOS_PROFILE_BASE64 --repo "$REPO"
  echo "Stored signing secrets: releases will produce a signed nbwsc .ipa."
fi
