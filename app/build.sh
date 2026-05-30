#!/usr/bin/env bash
# Build script: assembles DropItDown.app with embedded Python + the project's
# Python deps inside Contents/Resources/python/.
#
# Output: app/.build/DropItDown.app
#
# Requirements on the host machine:
#   - macOS 14+ with Xcode CLT (for swift, codesign)
#   - uv (https://docs.astral.sh/uv) — for dep install into the embedded venv
#   - curl
set -euo pipefail

cd "$(dirname "$0")"
APP_DIR="$(pwd)"
PROJ_ROOT="$(cd .. && pwd)"
BUILD_DIR="$APP_DIR/.build"
APP_BUNDLE="$BUILD_DIR/DropItDown.app"

# Pinned python-build-standalone release. Bump these together when upgrading.
PYTHON_VERSION="3.13.13"
PBS_RELEASE="20260510"
PBS_TARBALL="cpython-${PYTHON_VERSION}+${PBS_RELEASE}-aarch64-apple-darwin-install_only.tar.gz"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_RELEASE}/${PBS_TARBALL}"
PBS_CACHE="$BUILD_DIR/cache/$PBS_TARBALL"

mkdir -p "$BUILD_DIR/cache"

log() { printf "\033[36m== %s ==\033[0m\n" "$1"; }

# ----- 1. Compile the Swift binary --------------------------------------
log "Compiling Swift binary"
swift build -c release --arch arm64
SWIFT_BIN="$APP_DIR/.build/arm64-apple-macosx/release/DropItDown"
test -f "$SWIFT_BIN" || { echo "swift build did not produce $SWIFT_BIN"; exit 1; }

# ----- 2. Download python-build-standalone (cached) ---------------------
if [[ ! -f "$PBS_CACHE" ]]; then
    log "Downloading $PBS_TARBALL"
    curl -fSL "$PBS_URL" -o "$PBS_CACHE"
fi

# ----- 3. Assemble the .app bundle skeleton ------------------------------
log "Assembling .app bundle"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$APP_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$SWIFT_BIN" "$APP_BUNDLE/Contents/MacOS/DropItDown"
chmod +x "$APP_BUNDLE/Contents/MacOS/DropItDown"

# ----- 4. Extract embedded Python into Resources/python/ -----------------
log "Extracting embedded Python"
tar -xzf "$PBS_CACHE" -C "$APP_BUNDLE/Contents/Resources"
# python-build-standalone unpacks to a `python/` subdir — perfect.
test -d "$APP_BUNDLE/Contents/Resources/python/bin" || {
    echo "Embedded Python missing bin/"; exit 1; }

PY_BIN="$APP_BUNDLE/Contents/Resources/python/bin/python3"
ln -sf python3 "$APP_BUNDLE/Contents/Resources/python/bin/python" 2>/dev/null || true

# ----- 5. Install project + deps into the embedded Python ---------------
log "Installing project + deps into embedded Python"
# Non-editable install: copies dropitdown into site-packages so the bundle
# is fully self-contained (editable installs only drop a pointer back to
# the source dir, which doesn't exist on the user's machine).
# `--no-cache` avoids polluting the user's uv cache with these wheels.
uv pip install --python "$PY_BIN" --no-cache --prerelease=allow "$PROJ_ROOT"

# ----- 6. Drop the dropitdown launcher script ---------------------------
# `uv pip install` writes the entry-point script with an absolute shebang
# pointing at whatever Python was used at build time. On CI that's a path
# inside the runner's workspace, which doesn't exist on a user's Mac — so
# we replace it with a portable shell wrapper that resolves the bundled
# python3 relative to itself.
PY_BIN_DIR="$APP_BUNDLE/Contents/Resources/python/bin"
test -f "$PY_BIN_DIR/dropitdown" || { echo "dropitdown launcher missing"; exit 1; }

cat > "$PY_BIN_DIR/dropitdown" << 'EOF'
#!/bin/sh
# Portable launcher: works wherever the .app bundle is moved.
HERE="$(cd "$(dirname "$0")" && pwd)"
exec "$HERE/python3" -m dropitdown "$@"
EOF
chmod +x "$PY_BIN_DIR/dropitdown"

# Same fix for any other pip-generated entry point scripts (magika etc.).
# They all share the same broken shebang.
for script in "$PY_BIN_DIR"/*; do
    [ -f "$script" ] || continue
    case "$script" in
        */python*|*/pip*|*/dropitdown) continue ;;
    esac
    head -1 "$script" 2>/dev/null | grep -q "/Users/runner/" || continue
    name=$(basename "$script")
    cat > "$script" << EOF
#!/bin/sh
HERE="\$(cd "\$(dirname "\$0")" && pwd)"
exec "\$HERE/python3" -m $name "\$@"
EOF
    chmod +x "$script"
done

# ----- 7. Strip cruft to slim the bundle --------------------------------
log "Slimming bundle"
find "$APP_BUNDLE" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
find "$APP_BUNDLE" -name '*.pyc' -delete 2>/dev/null || true
find "$APP_BUNDLE/Contents/Resources/python/lib" -name 'tests' -type d -exec rm -rf {} + 2>/dev/null || true
find "$APP_BUNDLE/Contents/Resources/python/lib" -name 'test' -type d -exec rm -rf {} + 2>/dev/null || true
# speech_recognition ships an ancient pre-10.9-SDK FLAC binary that
# notarytool rejects. We don't use audio transcription (CU handles that),
# so it's safe to drop.
find "$APP_BUNDLE/Contents/Resources/python/lib" -name 'flac-mac' -delete 2>/dev/null || true
find "$APP_BUNDLE/Contents/Resources/python/lib" -name 'flac-linux*' -delete 2>/dev/null || true
find "$APP_BUNDLE/Contents/Resources/python/lib" -name 'flac-win32.exe' -delete 2>/dev/null || true

# ----- 8. Report ---------------------------------------------------------
SIZE=$(du -sh "$APP_BUNDLE" | awk '{print $1}')
log "Built $APP_BUNDLE ($SIZE)"
echo "Launch with: open '$APP_BUNDLE'"
