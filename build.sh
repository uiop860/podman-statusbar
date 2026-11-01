#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
CONFIG="${1:-release}"
case "$CONFIG" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 1;; esac
ARCH="${PODMAN_STATUSBAR_ARCH:-$(uname -m)}"
APP="$ROOT/build/PodmanStatusbar.app"
echo "==> Building ($ARCH, $CONFIG)"
swift build -c "$CONFIG" --arch "$ARCH"
BIN_DIR="$(swift build -c "$CONFIG" --arch "$ARCH" --show-bin-path)"
[[ -x "$BIN_DIR/PodmanStatusbar" ]] || { echo "Build output missing" >&2; exit 1; }
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PodmanStatusbar" "$APP/Contents/MacOS/PodmanStatusbar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
SIGN_ID="${PODMAN_STATUSBAR_SIGN_ID:-}"
if [[ -z "$SIGN_ID" ]]; then
    SIGN_ID="$(echo "$IDENTITIES" | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | head -1)"
fi
if [[ -z "$SIGN_ID" ]]; then
    SIGN_ID="$(echo "$IDENTITIES" | sed -nE 's/.*"(Apple Development: [^"]+)".*/\1/p' | head -1)"
fi
echo "==> Signing (${SIGN_ID:-ad-hoc})"
if [[ -n "$SIGN_ID" ]]; then
    codesign --force --options runtime --sign "$SIGN_ID" "$APP"
else
    codesign --force --sign - "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"
RUN_APP="$APP"
# Match the reference script's local install-and-launch workflow; opt out for CI.
if [[ "${PODMAN_STATUSBAR_INSTALL:-1}" == 1 && "${CI:-false}" != true ]]; then
    INSTALL_ROOT="${PODMAN_STATUSBAR_INSTALL_DIR:-/Applications}"
    mkdir -p "$INSTALL_ROOT"
    STAGE="$(mktemp -d "$INSTALL_ROOT/.podman-statusbar-install.XXXXXX")"
    trap 'rm -rf "$STAGE"' EXIT
    ditto "$APP" "$STAGE/PodmanStatusbar.app"
    if pgrep -x PodmanStatusbar >/dev/null; then
        osascript -e 'tell application id "local.podman-statusbar" to quit'
    fi
    RUN_APP="$INSTALL_ROOT/PodmanStatusbar.app"
    rm -rf "$RUN_APP"
    mv "$STAGE/PodmanStatusbar.app" "$RUN_APP"
    rmdir "$STAGE"
    trap - EXIT
    open "$RUN_APP"
fi
echo "Built: $APP"
echo "Run: open '$RUN_APP'"
