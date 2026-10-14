#!/usr/bin/env bash
# Selects the newest stable Xcode on the runner and picks the iOS deployment target:
# 27.0 once the toolchain ships an iOS 27+ SDK, otherwise 26.0 (the newest SDK available).
set -euo pipefail

best=$(ls -d /Applications/Xcode_*.app 2>/dev/null \
  | sed -E 's#^/Applications/Xcode_([0-9]+(\.[0-9]+)*)\.app$#\1 &#' \
  | grep -E '^[0-9]' | sort -V | tail -n1 | cut -d' ' -f2- || true)
[ -n "$best" ] || { echo "No stable Xcode found in /Applications" >&2; exit 1; }

sudo xcode-select -s "$best/Contents/Developer"
xcodebuild -version

sdk=$(xcrun --sdk iphoneos --show-sdk-version)
if [ "${sdk%%.*}" -ge 27 ]; then target="27.0"; else target="26.0"; fi
echo "iPhoneOS SDK $sdk -> deployment target $target"
[ -z "${GITHUB_ENV:-}" ] || echo "DEPLOY_TARGET=$target" >> "$GITHUB_ENV"
