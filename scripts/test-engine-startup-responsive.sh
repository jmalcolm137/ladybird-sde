#!/usr/bin/env bash
# The chrome must stay usable while the engine is starting.
#
# A slow engine (the real one, delayed by a wrapper) is launched with session
# restore enabled, which is the path that used to wait for the engine's launch
# plan before showing anything. The test asserts that:
#   1. the window maps while the engine has not started yet,
#   2. a URL typed during that window is queued, and
#   3. the queued navigation is delivered once the engine connects.
#
# Run: scripts/test-engine-startup-responsive.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDE_ROOT="${SDE_ROOT:-$ROOT/../serenity-desktop-environment}"
LIBGUI_WAYLAND_ROOT="${LIBGUI_WAYLAND_ROOT:-$ROOT/../libgui-wayland}"
SERENITY="${SERENITY:-$LIBGUI_WAYLAND_ROOT/serenity}"
LAGOM="${LAGOM:-$LIBGUI_WAYLAND_ROOT/build/lagom}"
COMP="$SDE_ROOT/build/WindowServer/WindowServer"
VI="$SDE_ROOT/build/input-test/virtual-input-test"
ENGINE="$ROOT/Build/release/libexec/LadybirdEngine"

for binary in "$COMP" "$VI" "$ENGINE" "$ROOT/build/chrome/Ladybird"; do
    [[ -x "$binary" ]] || { echo "error: missing $binary (build the SDE, the engine and the frontend first)" >&2; exit 1; }
done

RUNTIME="$(mktemp -d "${TMPDIR:-/tmp}/ladybird-startup-test.XXXXXX")"
chmod 700 "$RUNTIME"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export SDE_STATE_DIR="$RUNTIME"
export SDE_SESSION_DIR="$RUNTIME/session"
mkdir -p "$SDE_SESSION_DIR/portal" "$RUNTIME/data" "$RUNTIME/config"
export XDG_DATA_HOME="$RUNTIME/data"
export XDG_CONFIG_HOME="$RUNTIME/config"
SOCK="ladybird-startup-test-$$"

PROFILE="startup-responsive-$$"
mkdir -p "$RUNTIME/config/Ladybird/Profiles/$PROFILE"
# Session restore enabled: this is the path that used to stay windowless until
# the engine sent its launch plan.
printf '{"restorePreviousSession": true}\n' >"$RUNTIME/config/Ladybird/Profiles/$PROFILE/Settings.json"

# A real engine that takes 8 s to start. It records when it actually starts.
cat >"$RUNTIME/slow-engine.sh" <<EOF
#!/bin/sh
sleep 8
date +%s%N >"$RUNTIME/engine-exec"
exec "$ENGINE" "\$@"
EOF
chmod +x "$RUNTIME/slow-engine.sh"

cleanup() {
    kill "${CHROME_PID:-}" "${COMP_PID:-}" 2>/dev/null || true
    wait "${CHROME_PID:-}" "${COMP_PID:-}" 2>/dev/null || true
    rm -rf "$RUNTIME"
}
trap cleanup EXIT

env -u WAYLAND_DISPLAY -u DISPLAY \
    WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 \
    LIBWM_WM_PORTAL_PATH="$RUNTIME/wm" \
    SERENITY_RES_ROOT="$SERENITY/Base/res" \
    LD_LIBRARY_PATH="$LAGOM/lib" \
    "$COMP" -n "$SOCK" >"$RUNTIME/compositor.log" 2>&1 &
COMP_PID=$!
for _ in $(seq 1 100); do [[ -e "$XDG_RUNTIME_DIR/$SOCK" ]] && break; sleep 0.1; done

START_NS="$(date +%s%N)"
env -u LD_LIBRARY_PATH WAYLAND_DISPLAY="$SOCK" \
    SERENITY_RES_ROOT="$SERENITY/Base/res" \
    SDE_APP_BIN_DIR="$LAGOM/bin" \
    LADYBIRD_SOURCE_DIR="$ROOT" \
    LADYBIRD_ENGINE_HOST="$RUNTIME/slow-engine.sh" \
    LADYBIRD_SDE_PROFILE="$PROFILE" \
    LADYBIRD_SDE_TEST_LOG_NAVIGATION=1 \
    LIBWM_TRACE=1 \
    "$ROOT/build/chrome/Ladybird" about:newtab >"$RUNTIME/chrome.log" 2>&1 &
CHROME_PID=$!

# 1. The window must map while the engine is still sleeping.
for _ in $(seq 1 300); do
    grep -q "create_window id=.*'New Tab - Ladybird'" "$RUNTIME/chrome.log" 2>/dev/null && break
    sleep 0.1
done
MAP_NS="$(date +%s%N)"
MAP_MS=$(( (MAP_NS - START_NS) / 1000000 ))
if ! grep -q "create_window id=.*'New Tab - Ladybird'" "$RUNTIME/chrome.log"; then
    echo "  FAIL: no browser window was created"
    tail -40 "$RUNTIME/chrome.log"
    exit 1
fi
if [[ -e "$RUNTIME/engine-exec" ]]; then
    echo "  FAIL: the engine had already started when the window appeared"
    exit 1
fi
if (( MAP_MS > 3000 )); then
    echo "  FAIL: the window took ${MAP_MS}ms to appear while the engine was starting"
    exit 1
fi
echo "  ok: window mapped after ${MAP_MS}ms, before the engine started"

# 2. Type a URL into the location bar and submit it while the engine is down.
POSITION="$(grep -o "placed new window 'New Tab - Ladybird' at [0-9]*,[0-9]*" "$RUNTIME/compositor.log" | tail -1)"
WIN_X=100
WIN_Y=100
if [[ -n "$POSITION" ]]; then
    COORDS="${POSITION##* at }"
    WIN_Y="${COORDS##*,}"
    WIN_X="${COORDS%%,*}"
fi

# Ctrl+L focuses and selects the location bar (Mod_Ctrl, Key_L). The window is
# deliberately not clicked: the point is that the chrome responds to input.
TYPE_ARGS=(--key 29 press --sleep 40 --key 38 press --sleep 40 --key 38 release --sleep 40 --key 29 release --sleep 200)
# "example.com" and Return, US evdev keycodes.
for code in 18 45 30 50 25 38 18 52 46 24 50 28; do
    TYPE_ARGS+=(--key "$code" press --sleep 25 --key "$code" release --sleep 25)
done
env WAYLAND_DISPLAY="$SOCK" "$VI" --extent 1280 720 \
    --move "$((WIN_X + 600))" "$((WIN_Y + 81))" --sleep 100 \
    "${TYPE_ARGS[@]}" >/dev/null 2>&1 || true

for _ in $(seq 1 100); do
    grep -q 'navigation queued: example.com' "$RUNTIME/chrome.log" 2>/dev/null && break
    sleep 0.1
done
if ! grep -q 'navigation queued: example.com' "$RUNTIME/chrome.log"; then
    echo "  FAIL: a URL typed while the engine was starting was not queued"
    tail -40 "$RUNTIME/chrome.log"
    exit 1
fi
if [[ -e "$RUNTIME/engine-exec" ]]; then
    echo "  FAIL: the engine started before the URL was typed"
    exit 1
fi
echo "  ok: URL typed while the engine was starting was queued"

# 3. Once the engine connects, the queued navigation must be delivered.
for _ in $(seq 1 400); do
    grep -q 'navigation sent: example.com' "$RUNTIME/chrome.log" 2>/dev/null && break
    sleep 0.1
done
if ! grep -q 'navigation sent: example.com' "$RUNTIME/chrome.log"; then
    echo "  FAIL: the queued navigation was never sent to the engine"
    tail -60 "$RUNTIME/chrome.log"
    exit 1
fi
echo "  ok: queued navigation delivered after the engine connected"

if grep -qiE "VERIFICATION FAILED|ASSERTION FAILED|Segmentation fault|SIGSEGV" "$RUNTIME/chrome.log"; then
    echo "  FAIL: the browser faulted"
    exit 1
fi
echo "==> engine startup responsiveness test PASSED"
