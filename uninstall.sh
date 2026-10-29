#!/usr/bin/env bash
#
# Remove the camera feed installed by install.sh.
#
#   ./uninstall.sh 192.168.1.50
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

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

IP="$PRINTER"
case "$IP" in
    *[!0-9.]*) IP="$(getent hosts "$PRINTER" 2>/dev/null | awk '{print $1; exit}' || true)" ;;
esac
[ -n "$IP" ] || { echo "could not resolve $PRINTER" >&2; exit 1; }

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
ssh_run() { ssh "${SSH_OPTS[@]}" "${SSH_USER}@${IP}" "$@"; }

say "Stopping and disabling go2rtc"
ssh_run "/etc/init.d/go2rtc stop 2>/dev/null || true"
ssh_run "/etc/init.d/go2rtc disable 2>/dev/null || true"
ssh_run "rm -f /etc/init.d/go2rtc"

say "Restoring Moonraker configuration"
ssh_run "if [ -f $REMOTE_DIR/moonraker.conf.orig ]; then \
             cp $REMOTE_DIR/moonraker.conf.orig /usr/share/moonraker/moonraker.conf; \
             echo '  restored'; else echo '  no backup found, leaving as is'; fi"

say "Removing the webcam entry"
UID_VAL="$(curl -fsS "http://${IP}:7125/server/webcams/list" 2>/dev/null \
    | tr '{' '\n' | grep -F "\"name\": \"${WEBCAM_NAME}\"" \
    | grep -F '"source": "database"' \
    | grep -o '"uid": "[^"]*"' | head -1 | cut -d'"' -f4 || true)"
if [ -n "$UID_VAL" ]; then
    curl -fsS -m 10 -X DELETE "http://${IP}:7125/server/webcams/item?uid=${UID_VAL}" > /dev/null \
        && echo "  removed $WEBCAM_NAME"
else
    echo "  no database webcam named $WEBCAM_NAME"
fi

say "Restarting Moonraker"
ssh_run "/etc/init.d/moonraker restart"

say "Removing files"
ssh_run "rm -rf $REMOTE_DIR"

say "Done - the camera feed has been removed"
