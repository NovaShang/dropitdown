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
# uv pip install --python <embedded_python> -e <project>
# `--no-cache` avoids polluting the user's uv cache with these wheels.
uv pip install --python "$PY_BIN" --no-cache --prerelease=allow -e "$PROJ_ROOT"

# ----- 6. Drop the dropitdown launcher script ---------------------------
# The pip install will have placed a `dropitdown` script in the embedded
# bin/ directory pointing at the embedded python. Verify and make sure
# its shebang is portable enough for codesign + notarize.
test -f "$APP_BUNDLE/Contents/Resources/python/bin/dropitdown" || {
    echo "dropitdown launcher missing"; exit 1; }

# ----- 7. Strip cruft to slim the bundle --------------------------------
log "Slimming bundle"
find "$APP_BUNDLE" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
find "$APP_BUNDLE" -name '*.pyc' -delete 2>/dev/null || true
find "$APP_BUNDLE/Contents/Resources/python/lib" -name 'tests' -type d -exec rm -rf {} + 2>/dev/null || true
find "$APP_BUNDLE/Contents/Resources/python/lib" -name 'test' -type d -exec rm -rf {} + 2>/dev/null || true

# ----- 8. Report ---------------------------------------------------------
SIZE=$(du -sh "$APP_BUNDLE" | awk '{print $1}')
log "Built $APP_BUNDLE ($SIZE)"
echo "Launch with: open '$APP_BUNDLE'"
