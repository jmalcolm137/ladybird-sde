#!/usr/bin/env bash
# The location bar must belong to the user while they type.
#
# Two regressions this covers:
#   1. A page that is still loading must not replace the text being typed (or
#      the URL that Enter then submits).
#   2. Enter must navigate what was typed, not the highlighted autocomplete row;
#      only an explicit arrow-key selection may substitute a suggestion. A title
#      match that is not a prefix of the query is the case that used to hijack
#      the URL and turn it into a search.
#
# The engine logs every user-initiated navigation as
# "engine navigate: '<input>' -> '<url>'" when LADYBIRD_SDE_TEST_LOG_NAVIGATION
# is set, so the assertions are on what actually reached the engine.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDE_ROOT="${SDE_ROOT:-$ROOT/../serenity-desktop-environment}"
LIBGUI_WAYLAND_ROOT="${LIBGUI_WAYLAND_ROOT:-$ROOT/../libgui-wayland}"
SERENITY="${SERENITY:-$LIBGUI_WAYLAND_ROOT/serenity}"
LAGOM="${LAGOM:-$LIBGUI_WAYLAND_ROOT/build/lagom}"
COMP="$SDE_ROOT/build/WindowServer/WindowServer"
VI="$SDE_ROOT/build/input-test/virtual-input-test"

for binary in "$COMP" "$VI" "$ROOT/Build/release/libexec/LadybirdEngine" "$ROOT/build/chrome/Ladybird"; do
    [[ -x "$binary" ]] || { echo "error: missing $binary" >&2; exit 1; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ladybird-urlbar-test.XXXXXX")"
SOCK="ladybird-urlbar-$$"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
mkdir -p "$WORK/data" "$WORK/config" "$WORK/session/portal"
PASS=0
FAIL=0

cleanup() {
    kill "${CHROME_PID:-}" "${COMP_PID:-}" "${SERVER_PID:-}" 2>/dev/null || true
    wait 2>/dev/null
    if [[ "${KEEP:-0}" == 1 ]]; then
        echo "==> kept $WORK"
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

check() {
    local name="$1" result="$2"
    if [[ "$result" == 0 ]]; then
        echo "$name PASS"
        PASS=$((PASS + 1))
    else
        echo "$name FAIL"
        FAIL=$((FAIL + 1))
    fi
}

# A local server with a slow page, a normal page and a page whose title does not
# look like its URL (a title-only autocomplete match).
PORT_FILE="$WORK/port"
cat >"$WORK/server.py" <<'PY'
import http.server, socketserver, sys, time

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass
    def do_GET(self):
        with open(sys.argv[2], "a") as log:
            log.write(f"GET {self.path}\n")
        if self.path == "/slow.html":
            # A redirect that lands while the next URL is being typed: this is
            # what used to replace the text in the location bar.
            time.sleep(1.2)
            self.send_response(302)
            self.send_header("Location", "/target.html")
            self.end_headers()
            return
        elif self.path.startswith("/titled"):
            body = b"<title>Zebra Page</title>zebra"
        else:
            body = b"<title>Plain</title>plain"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

with socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler) as httpd:
    with open(sys.argv[1], "w") as f:
        f.write(str(httpd.server_address[1]))
    httpd.serve_forever()
PY
python3 "$WORK/server.py" "$PORT_FILE" "$WORK/server.log" &
SERVER_PID=$!
for _ in $(seq 1 100); do [[ -s "$PORT_FILE" ]] && break; sleep 0.1; done
PORT="$(cat "$PORT_FILE")"
BASE="127.0.0.1:$PORT"

start_compositor() {
    env -u WAYLAND_DISPLAY -u DISPLAY WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 \
        LIBWM_WM_PORTAL_PATH="$WORK/wm" SERENITY_RES_ROOT="$SERENITY/Base/res" \
        LD_LIBRARY_PATH="$LAGOM/lib" XDG_RUNTIME_DIR="$RUNTIME_DIR" \
        "$COMP" -n "$SOCK" >"$WORK/compositor.log" 2>&1 &
    COMP_PID=$!
    for _ in $(seq 1 100); do [[ -e "$RUNTIME_DIR/$SOCK" ]] && break; sleep 0.1; done
}

start_compositor
env -u LD_LIBRARY_PATH WAYLAND_DISPLAY="$SOCK" XDG_RUNTIME_DIR="$RUNTIME_DIR" \
    XDG_DATA_HOME="$WORK/data" XDG_CONFIG_HOME="$WORK/config" \
    SERENITY_RES_ROOT="$SERENITY/Base/res" SDE_APP_BIN_DIR="$LAGOM/bin" \
    LADYBIRD_SOURCE_DIR="$ROOT" LADYBIRD_ENGINE_HOST="$ROOT/Build/release/libexec/LadybirdEngine" \
    LADYBIRD_SDE_PROFILE="urlbar-test-$$" LADYBIRD_SDE_DISABLE_SESSION_RESTORE=1 \
    LADYBIRD_SDE_TEST_LOG_NAVIGATION=1 \
    "$ROOT/build/chrome/Ladybird" about:newtab >"$WORK/chrome.log" 2>&1 &
CHROME_PID=$!
for _ in $(seq 1 200); do
    grep -q "create_window id=.*'New Tab - Ladybird'" "$WORK/chrome.log" 2>/dev/null && break
    sleep 0.1
done
sleep 2

POSITION="$(grep -o "placed new window 'New Tab - Ladybird' at [0-9]*,[0-9]*" "$WORK/compositor.log" | tail -1)"
WIN_X=100
WIN_Y=100
if [[ -n "$POSITION" ]]; then
    COORDS="${POSITION##* at }"
    WIN_Y="${COORDS##*,}"
    WIN_X="${COORDS%%,*}"
fi

declare -A KEY_FOR_CHAR=(
    [a]=30 [b]=48 [c]=46 [d]=32 [e]=18 [f]=33 [g]=34 [h]=35 [i]=23 [j]=36 [k]=37 [l]=38
    [m]=50 [n]=49 [o]=24 [p]=25 [q]=16 [r]=19 [s]=31 [t]=20 [u]=22 [v]=47 [w]=17
    [x]=45 [y]=21 [z]=44
    [0]=11 [1]=2 [2]=3 [3]=4 [4]=5 [5]=6 [6]=7 [7]=8 [8]=9 [9]=10
    [.]=52 [/]=53 [-]=12
)

type_text() {
    local text="$1" args=() i ch code
    for ((i = 0; i < ${#text}; i++)); do
        ch="${text:i:1}"
        if [[ "$ch" == ":" ]]; then
            args+=(--key 42 press --sleep 20 --key 39 press --sleep 20 --key 39 release --sleep 20 --key 42 release --sleep 20)
        else
            code="${KEY_FOR_CHAR[$ch]:-}"
            [[ -n "$code" ]] || continue
            args+=(--key "$code" press --sleep 25 --key "$code" release --sleep 25)
        fi
    done
    env WAYLAND_DISPLAY="$SOCK" XDG_RUNTIME_DIR="$RUNTIME_DIR" "$VI" "${args[@]}" >/dev/null 2>&1
}

chord() {
    local modifier="$1" args=(--key "$1" press --sleep 40)
    shift
    for code in "$@"; do
        args+=(--key "$code" press --sleep 30 --key "$code" release --sleep 30)
    done
    args+=(--key "$modifier" release)
    env WAYLAND_DISPLAY="$SOCK" XDG_RUNTIME_DIR="$RUNTIME_DIR" "$VI" "${args[@]}" >/dev/null 2>&1
}

focus_location() { chord 29 38; sleep 0.4; }

wait_for_navigate() {
    local needle="$1" timeout_seconds="${2:-10}"
    for _ in $(seq 1 $((timeout_seconds * 20))); do
        grep -qF "engine navigate: '$needle'" "$WORK/chrome.log" && return 0
        sleep 0.05
    done
    return 1
}

# --- 1. A loading page must not overwrite what the user is typing -------------
focus_location
type_text "$BASE/slow.html"
chord 28 # Return
sleep 0.6

focus_location
type_text "$BASE/a.html"
chord 28 # Return

wait_for_navigate "$BASE/a.html" 10 || true
check "navigation typed during a load survives" $?
grep -qF "engine navigate: '$BASE/a.html' -> 'http://$BASE/a.html'" "$WORK/chrome.log"
check "typed URL reaches the engine unchanged" $?
for _ in $(seq 1 100); do grep -q 'GET /a.html' "$WORK/server.log" && break; sleep 0.05; done
grep -q 'GET /a.html' "$WORK/server.log"
check "typed URL is the page that loads" $?

# --- 2. A title-only autocomplete match must not hijack Enter -----------------
sleep 1
focus_location
type_text "$BASE/titled.html"
chord 28
sleep 2

focus_location
type_text "zebra"
sleep 1.2   # let the autocomplete rows for the title match arrive
chord 28

wait_for_navigate "zebra" 8 || true
check "Enter navigates the typed text, not the highlighted row" $?

if grep -qiE "VERIFICATION FAILED|ASSERTION FAILED|Segmentation fault|SIGSEGV" "$WORK/chrome.log"; then
    echo "  browser faulted"
    tail -40 "$WORK/chrome.log"
    FAIL=$((FAIL + 1))
fi

echo "==> $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
