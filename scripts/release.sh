#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# release.sh — Build, sign, notarize, and package Claudius as a DMG
#
# Usage:
#   ./scripts/release.sh <version>
#
# Example:
#   ./scripts/release.sh 2.1
#
# Required environment variables (set them or export before running):
#   DEVELOPER_ID   — Your "Developer ID Application: ..." identity
#   APPLE_ID       — Apple ID email for notarytool
#   TEAM_ID        — 10-character Apple team ID
#   APP_PASSWORD   — App-specific password for notarytool
#
# You can also put these in a .env file next to this script:
#   source scripts/.env && ./scripts/release.sh 2.1
# ------------------------------------------------------------------

VERSION="${1:?Usage: release.sh <version>}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build/release"
APP_PATH="$BUILD_DIR/Build/Products/Release/Claudius.app"
DMG_STAGING="/tmp/claudius-dmg-$$"
DMG_OUT="$ROOT/build/Claudius-v${VERSION}.dmg"

# ---- Validate env ------------------------------------------------

: "${DEVELOPER_ID:?Set DEVELOPER_ID to your Developer ID Application identity}"
: "${APPLE_ID:?Set APPLE_ID to your Apple ID email}"
: "${TEAM_ID:?Set TEAM_ID to your 10-character Apple team ID}"
: "${APP_PASSWORD:?Set APP_PASSWORD to an app-specific password}"

# ---- Build -------------------------------------------------------

echo "==> Building Claudius (Release)..."
xcodebuild \
  -project "$ROOT/Claudius.xcodeproj" \
  -scheme Claudius \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  clean build \
  | tail -5

echo "==> Build succeeded."

# ---- Re-sign with Developer ID + hardened runtime ----------------

echo "==> Signing with Developer ID ($DEVELOPER_ID)..."
codesign --force --deep --options runtime \
  --sign "$DEVELOPER_ID" \
  "$APP_PATH"

echo "==> Verifying code signature..."
codesign --verify --deep --strict "$APP_PATH"
echo "    Signature OK."

# ---- Package DMG -------------------------------------------------

echo "==> Creating DMG..."
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
rm -f "$DMG_OUT"
hdiutil create \
  -volname "Claudius" \
  -srcfolder "$DMG_STAGING" \
  -ov -format UDZO \
  "$DMG_OUT"
rm -rf "$DMG_STAGING"

# ---- Sign the DMG ------------------------------------------------

echo "==> Signing DMG..."
codesign --force --sign "$DEVELOPER_ID" "$DMG_OUT"

# ---- Notarize ----------------------------------------------------

echo "==> Submitting for notarization (this may take a few minutes)..."
xcrun notarytool submit "$DMG_OUT" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_PASSWORD" \
  --wait

# ---- Staple ------------------------------------------------------

echo "==> Stapling notarization ticket..."
xcrun stapler staple "$DMG_OUT"

# ---- Sparkle EdDSA signature -------------------------------------

echo "==> Generating Sparkle EdDSA signature..."

# Try to locate sign_update from a built SPM artifact, then PATH, then ~/Sparkle/bin.
SIGN_UPDATE=""
for cand in \
  "$(command -v sign_update 2>/dev/null || true)" \
  "$HOME/Sparkle/bin/sign_update" \
  "$(/bin/ls -d "$HOME/Library/Developer/Xcode/DerivedData/"Claudius-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update 2>/dev/null | head -n1)"; do
  if [ -n "$cand" ] && [ -x "$cand" ]; then SIGN_UPDATE="$cand"; break; fi
done

if [ -z "$SIGN_UPDATE" ]; then
  echo "    sign_update not found — skipping Sparkle signature."
  echo "    Install Sparkle's tools (e.g. download the Sparkle release zip and put bin/ on PATH)."
  SIG_LINE=""
else
  # sign_update prints e.g.: sparkle:edSignature="abc..." length="12345"
  SIG_LINE="$("$SIGN_UPDATE" "$DMG_OUT")"
  echo "    $SIG_LINE"
fi

# ---- Done --------------------------------------------------------

DMG_SIZE_HUMAN="$(du -h "$DMG_OUT" | cut -f1 | xargs)"
DMG_SIZE_BYTES="$(stat -f%z "$DMG_OUT")"
PUBDATE="$(date -u "+%a, %d %b %Y %H:%M:%S +0000")"
DOWNLOAD_URL="https://github.com/nsluke/Claudius/releases/download/v${VERSION}/$(basename "$DMG_OUT")"

echo ""
echo "==> Done! DMG ready at:"
echo "    $DMG_OUT ($DMG_SIZE_HUMAN)"
echo ""
echo "To upload to a GitHub release:"
echo "    gh release upload v${VERSION} \"$DMG_OUT\" --clobber"
echo ""
echo "Appcast <item> entry to paste into docs/appcast.xml:"
echo "----------------------------------------------------"
cat <<EOF
        <item>
            <title>Version ${VERSION}</title>
            <pubDate>${PUBDATE}</pubDate>
            <sparkle:version>${VERSION}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <enclosure
                url="${DOWNLOAD_URL}"
                type="application/octet-stream"
                length="${DMG_SIZE_BYTES}"
                ${SIG_LINE} />
        </item>
EOF
echo "----------------------------------------------------"
