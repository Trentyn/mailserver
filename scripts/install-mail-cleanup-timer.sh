#!/bin/bash
# Install a daily timer that removes old Trash messages.
set -Eeuo pipefail
DAYS="${1:-30}"
[[ $EUID -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
[[ "$DAYS" =~ ^[1-9][0-9]*$ ]] || { echo 'Usage: sudo bash install-mail-cleanup-timer.sh [days]'; exit 2; }
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
install -m 0750 "$SCRIPT_DIR/cleanup-mailboxes.sh" /usr/local/sbin/mailserver-cleanup-mailboxes
cat >/etc/systemd/system/mailserver-mail-cleanup.service <<EOF
[Unit]
Description=Remove old Trash mail

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mailserver-cleanup-mailboxes --apply --days ${DAYS}
EOF
cat >/etc/systemd/system/mailserver-mail-cleanup.timer <<'EOF'
[Unit]
Description=Daily Trash cleanup

[Timer]
OnCalendar=daily
RandomizedDelaySec=20m
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now mailserver-mail-cleanup.timer
systemctl list-timers mailserver-mail-cleanup.timer --no-pager
echo "Daily cleanup installed: Trash messages older than ${DAYS} days."