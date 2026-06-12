#!/usr/bin/env bash
# Sign and notarize the built DropItDown.app, then package it into a DMG.
#
# Required environment variables:
#   APPLE_DEV_ID         — "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_KEY_PATH      — absolute path to App Store Connect .p8 file
#   NOTARY_KEY_ID        — 10-char Key ID from App Store Connect
#   NOTARY_ISSUER_ID     — UUID of the issuer (same dashboard page)
#
# Run `./build.sh` first to produce the unsigned .app bundle.
set -euo pipefail

cd "$(dirname "$0")"
APP_DIR="$(pwd)"
APP_BUNDLE="$APP_DIR/.build/DropItDown.app"

: "${APPLE_DEV_ID:?Set APPLE_DEV_ID to your signing identity}"
: "${NOTARY_KEY_PATH:?Set NOTARY_KEY_PATH to path of the .p8 key}"
: "${NOTARY_KEY_ID:?Set NOTARY_KEY_ID to the Key ID}"
: "${NOTARY_ISSUER_ID:?Set NOTARY_ISSUER_ID to the issuer UUID}"

test -d "$APP_BUNDLE" || { echo "Run ./build.sh first"; exit 1; }

log() { printf "\033[36m== %s ==\033[0m\n" "$1"; }

ENTITLEMENTS="$APP_DIR/.build/entitlements.plist"
cat > "$ENTITLEMENTS" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Required: embedded Python needs JIT + unsigned executable memory -->
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <!-- Network access for the LLM + CU calls -->
    <key>com.apple.security.network.client</key>
    <true/>
    <!-- Subprocess execution (Python CLI) -->
    <key>com.apple.security.cs.allow-dyld-environment-variables</key>
    <true/>
</dict>
</plist>
EOF

log "Signing embedded binaries"
# Sign every native binary inside Resources/python: .so / .dylib anywhere,
# plus every executable file in bin/ (python3, magika, dropitdown, etc.).
# Filter to regular files so we don't try to codesign directories.
PY_ROOT="$APP_BUNDLE/Contents/Resources/python"
find "$PY_ROOT" -type f \( -name '*.so' -o -name '*.dylib' \) \
    -exec codesign --force --options runtime --timestamp \
        --sign "$APPLE_DEV_ID" --entitlements "$ENTITLEMENTS" {} +
# Every executable in bin/ — these are the launchers for CLI tools that
# ship inside Python deps. They need hardened runtime + Developer ID sign.
find "$PY_ROOT/bin" -type f -perm +111 \
    -exec codesign --force --options runtime --timestamp \
        --sign "$APPLE_DEV_ID" --entitlements "$ENTITLEMENTS" {} +

log "Signing the .app bundle"
codesign --force --options runtime --timestamp --deep \
    --sign "$APPLE_DEV_ID" --entitlements "$ENTITLEMENTS" \
    "$APP_BUNDLE"

log "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
spctl --assess --type execute --verbose "$APP_BUNDLE" || true

log "Packaging for notarization"
ZIP="$APP_DIR/.build/DropItDown.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP"

log "Submitting to Apple notarytool (this can take a few minutes)"
xcrun notarytool submit "$ZIP" \
    --key "$NOTARY_KEY_PATH" \
    --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" \
    --wait

log "Stapling notarization ticket"
xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"

log "Building DMG"
DMG="$APP_DIR/.build/DropItDown.dmg"
rm -f "$DMG"
# Stage the (signed + stapled) app next to an /Applications alias so the
# DMG offers the standard drag-to-install layout. ditto preserves the
# bundle's signature and the stapled notarization ticket.
DMG_STAGE="$APP_DIR/.build/dmg-stage"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
ditto "$APP_BUNDLE" "$DMG_STAGE/DropItDown.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "DropItDown" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG"
rm -rf "$DMG_STAGE"

# Also sign the DMG for good measure.
codesign --force --sign "$APPLE_DEV_ID" --timestamp "$DMG"

log "Done"
echo "Signed app: $APP_BUNDLE"
echo "DMG:        $DMG"
