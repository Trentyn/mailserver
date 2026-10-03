#!/bin/bash
# Preview or remove old messages from Junk and Trash for every virtual mailbox.
set -Eeuo pipefail

APPLY=false
DAYS=30
usage() { echo "Usage: sudo bash $0 [--apply] [--days N]"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true ;;
    --days) DAYS="${2:?Missing value for --days}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
[[ $EUID -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
[[ "$DAYS" =~ ^[1-9][0-9]*$ ]] || { echo 'Days must be a positive integer.' >&2; exit 2; }
[[ -s /etc/dovecot/users ]] || { echo 'No virtual mailboxes found in /etc/dovecot/users.' >&2; exit 1; }

$APPLY || echo "Preview only. Re-run with --apply to delete messages older than ${DAYS} days."
while IFS=: read -r email _; do
  [[ -n "$email" ]] || continue
  for folder in Junk Trash; do
    matches=$(doveadm search -u "$email" mailbox "$folder" before "${DAYS}d" 2>/dev/null || true)
    count=$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l)
    (( count > 0 )) || continue
    if $APPLY; then
      doveadm expunge -u "$email" mailbox "$folder" before "${DAYS}d"
      echo "Removed ${count} message(s) from ${folder} for ${email}."
    else
      echo "Would remove ${count} message(s) from ${folder} for ${email}."
    fi
  done
done < /etc/dovecot/users