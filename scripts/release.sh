#!/usr/bin/env bash
# Usage: ./scripts/release.sh 0.1.1
set -euo pipefail

VERSION="${1:?Usage: $0 <version>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="/tmp/coucou-release-$VERSION"
APP="$BUILD_DIR/Coucou.app"
ZIP="$BUILD_DIR/Coucou.zip"

# ── 1. Find Developer ID identity ─────────────────────────────────────────────
IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(Developer ID Application[^"]*\)".*/\1/')
if [ -z "$IDENTITY" ]; then
  echo "error: No 'Developer ID Application' certificate found. Install it via Xcode → Settings → Accounts." >&2
  exit 1
fi
echo "Signing with: $IDENTITY"

# ── 2. xcodegen + Release build ───────────────────────────────────────────────
cd "$REPO_ROOT/NotchBuddy"
xcodegen generate
rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"

xcodebuild \
  -project NotchBuddy.xcodeproj \
  -scheme NotchBuddy \
  -configuration Release \
  build \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR"

# ── 3. Zip + notarize ─────────────────────────────────────────────────────────
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile coucou-notary --wait

# ── 4. Staple + verify ────────────────────────────────────────────────────────
xcrun stapler staple "$APP"
spctl -a -vv "$APP"

# ── 5. Re-zip (with stapled app) + SHA-256 ─────────────────────────────────────
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHASUM=$(shasum -a 256 "$ZIP" | awk '{print $1}')
echo "Release zip ready: $ZIP"
echo "SHA-256: $SHASUM"

# ── 6. DMG (optional, for drag-and-drop install) ──────────────────────────────
DMG="$BUILD_DIR/Coucou-$VERSION.dmg"
if command -v create-dmg >/dev/null 2>&1; then
  create-dmg \
    --volname "Coucou $VERSION" \
    --volicon "$REPO_ROOT/NotchBuddy/Resources/MenuBarIcon.icns" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "Coucou.app" 150 200 \
    --hide-extension "Coucou.app" \
    --app-drop-link 450 200 \
    "$DMG" "$APP" >/dev/null 2>&1 || true
  echo "DMG ready: $DMG"
fi

# ── 6. Tag + GitHub release ───────────────────────────────────────────────────
cd "$REPO_ROOT"
git tag "v$VERSION"
git push origin "v$VERSION"

gh release create "v$VERSION" "$ZIP" \
  --repo Louis-CFM/coucou \
  --title "Coucou $VERSION" \
  --notes "$(cat <<EOF
## Install

Download **Coucou.zip**, unzip and move **Coucou.app** to \`/Applications\`. Launch — no extra steps needed.

## Build from source

\`\`\`bash
brew install xcodegen
git clone https://github.com/Louis-CFM/coucou.git
cd coucou/NotchBuddy && xcodegen && open NotchBuddy.xcodeproj
\`\`\`
EOF
)"

echo "✓ v$VERSION released: https://github.com/Louis-CFM/coucou/releases/tag/v$VERSION"
