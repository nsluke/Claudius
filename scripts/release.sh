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
  CODE_SIGN_IDENTITY="$DEVELOPER_ID" \
  CODE_SIGN_STYLE=Manual \
  OTHER_CODE_SIGN_FLAGS="--options runtime" \
  | tail -5

echo "==> Build succeeded."

# ---- Verify signature --------------------------------------------

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

# ---- Done --------------------------------------------------------

DMG_SIZE="$(du -h "$DMG_OUT" | cut -f1 | xargs)"
echo ""
echo "==> Done! DMG ready at:"
echo "    $DMG_OUT ($DMG_SIZE)"
echo ""
echo "To upload to a GitHub release:"
echo "    gh release upload v${VERSION} \"$DMG_OUT\" --clobber"
