#!/usr/bin/env bash
#
# Mainsail camera feed for the Creality K2 Pro.
#
# Run this from your computer, not on the printer. It pushes go2rtc to the
# printer, starts it as a service, and registers the camera in Moonraker.
#
#   ./install.sh 192.168.1.50
#   ./install.sh k2pro-c7cc.local
#
set -euo pipefail

PRINTER="${1:-}"
if [ -z "$PRINTER" ]; then
    echo "usage: $0 <printer-ip-or-hostname>"
    exit 1
fi

SSH_USER="${SSH_USER:-root}"
REMOTE_DIR="/mnt/UDISK/go2rtc"
WEBCAM_NAME="${WEBCAM_NAME:-K2 Pro}"
STREAM_NAME="${STREAM_NAME:-k2pro}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Resolve the printer address
IP="$PRINTER"
case "$IP" in
    *[!0-9.]*) IP="$(getent hosts "$PRINTER" 2>/dev/null | awk '{print $1; exit}' || true)" ;;
esac
[ -n "$IP" ] || die "could not resolve $PRINTER"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
ssh_run() { ssh "${SSH_OPTS[@]}" "${SSH_USER}@${IP}" "$@"; }
scp_to() { scp "${SSH_OPTS[@]}" "$1" "${SSH_USER}@${IP}:$2"; }
scp_from() { scp "${SSH_OPTS[@]}" "${SSH_USER}@${IP}:$1" "$2"; }

say "Printer: $IP (user: $SSH_USER)"
ssh_run "uname -n" || die "cannot reach the printer over SSH"

# The installer restarts Moonraker, so refuse to run while a job is active
PRINT_STATE="$(curl -fsS -m 10 "http://${IP}:7125/printer/objects/query?print_stats" 2>/dev/null \
    | grep -o '"state": *"[a-z]*"' | head -1 | cut -d'"' -f4 || true)"
case "$PRINT_STATE" in
    printing|paused)
        die "printer is '$PRINT_STATE' - this installs a service and restarts Moonraker. Re-run when idle."
        ;;
esac

# 1. Fetch go2rtc for ARMv7
BIN="$TMP/go2rtc"
if [ -n "${GO2RTC_BIN:-}" ]; then
    say "Using local binary: $GO2RTC_BIN"
    cp "$GO2RTC_BIN" "$BIN"
else
    say "Downloading go2rtc (linux/arm)"
    curl -fsSL -o "$BIN" \
        "https://github.com/AlexxIT/go2rtc/releases/latest/download/go2rtc_linux_arm" \
        || die "download failed"
fi
chmod +x "$BIN"

# 2. Configuration
say "Writing configuration"
cat > "$TMP/go2rtc.yaml" <<EOF
# go2rtc - Creality K2 Pro camera relay
log:
  level: info

api:
  listen: ":1984"

rtsp:
  listen: ""

webrtc:
  listen: ":8555"
  candidates:
    - ${IP}:8555

streams:
  ${STREAM_NAME}: webrtc:http://127.0.0.1:8000/call/webrtc_local#format=creality
EOF

# 3. Install files on the printer
say "Installing to $REMOTE_DIR"
ssh_run "mkdir -p $REMOTE_DIR"
scp_to "$BIN" "$REMOTE_DIR/go2rtc"
scp_to "$TMP/go2rtc.yaml" "$REMOTE_DIR/go2rtc.yaml"
scp_to "$HERE/files/go2rtc.init" "/etc/init.d/go2rtc"

say "Enabling service"
ssh_run "chmod +x /etc/init.d/go2rtc $REMOTE_DIR/go2rtc"
ssh_run "/etc/init.d/go2rtc enable"
ssh_run "/etc/init.d/go2rtc restart"
sleep 4
ssh_run "/etc/init.d/go2rtc status" || die "go2rtc did not start"

# 4. Confirm the relay actually produces a frame
say "Testing the relay"
if curl -fsS -m 40 -o "$TMP/frame.jpg" \
    "http://${IP}:1984/api/frame.jpeg?src=${STREAM_NAME}"; then
    echo "  frame received: $(wc -c < "$TMP/frame.jpg") bytes"
else
    die "go2rtc is running but produced no frame - check $REMOTE_DIR logs"
fi

# 5. Register the webcam in Moonraker (stored in its database, survives updates)
say "Registering webcam in Moonraker"
STREAM_URL="http://${IP}:1984/stream.html?src=${STREAM_NAME}&mode=webrtc"
SNAPSHOT_URL="http://${IP}:1984/api/frame.jpeg?src=${STREAM_NAME}"

EXISTING_UID="$(curl -fsS "http://${IP}:7125/server/webcams/list" \
    | tr '{' '\n' | grep -F "\"name\": \"${WEBCAM_NAME}\"" \
    | grep -o '"uid": "[^"]*"' | head -1 | cut -d'"' -f4 || true)"

BODY="{\"name\":\"${WEBCAM_NAME}\",\"service\":\"webrtc-go2rtc\",\"stream_url\":\"${STREAM_URL}\",\"snapshot_url\":\"${SNAPSHOT_URL}\",\"aspect_ratio\":\"16:9\",\"location\":\"printer\",\"target_fps\":15,\"target_fps_idle\":5"
if [ -n "$EXISTING_UID" ]; then
    echo "  updating existing entry ($EXISTING_UID)"
    BODY="${BODY},\"uid\":\"${EXISTING_UID}\"}"
else
    BODY="${BODY}}"
fi

curl -fsS -m 10 -X POST -H "Content-Type: application/json" -d "$BODY" \
    "http://${IP}:7125/server/webcams/item" > /dev/null \
    || die "Moonraker rejected the webcam entry"

# 6. Disable the stock iframe webcam, which would otherwise show a second panel
say "Checking for the stock Creality webcam entry"
scp_from "/usr/share/moonraker/moonraker.conf" "$TMP/moonraker.conf" 2>/dev/null || true
if [ -s "$TMP/moonraker.conf" ]; then
    cat > "$TMP/comment.awk" <<'AWK'
function flush() {
    if (n > 0) {
        if (is_iframe) { for (i = 1; i <= n; i++) print "# " buf[i] }
        else           { for (i = 1; i <= n; i++) print buf[i] }
    }
    n = 0; is_iframe = 0
}
/^\[/ {
    flush()
    if ($0 ~ /^\[webcam /) { n = 1; buf[n] = $0; next }
    print
    next
}
{
    if (n > 0) {
        n++; buf[n] = $0
        if ($0 ~ /^[ \t]*service:[ \t]*iframe/) is_iframe = 1
    } else print
}
END { flush() }
AWK
    awk -f "$TMP/comment.awk" "$TMP/moonraker.conf" > "$TMP/moonraker.new"
    if cmp -s "$TMP/moonraker.conf" "$TMP/moonraker.new"; then
        echo "  nothing to disable"
    else
        ssh_run "test -f $REMOTE_DIR/moonraker.conf.orig || cp /usr/share/moonraker/moonraker.conf $REMOTE_DIR/moonraker.conf.orig"
        scp_to "$TMP/moonraker.new" "/usr/share/moonraker/moonraker.conf"
        echo "  stock webcam disabled"
        say "Restarting Moonraker"
        ssh_run "/etc/init.d/moonraker restart"
        sleep 10
    fi
fi

say "Done"
cat <<EOF

  Mainsail:  http://${IP}:4408/
  Webcam:    ${WEBCAM_NAME} (${STREAM_URL})
  Snapshot:  ${SNAPSHOT_URL}

  Open Mainsail and expand the Webcam panel. If it stays black, reload the
  page once - the browser needs to complete the WebRTC handshake.
EOF
