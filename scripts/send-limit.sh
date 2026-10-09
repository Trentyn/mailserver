#!/bin/bash
# Limit how many recipients each mailbox may send to, so a stolen password
# cannot be used to send spam from this server.
#
#   send-limit.sh show                   limits, exempt mailboxes, recent hits
#   send-limit.sh set PER_HOUR PER_DAY   change the limits (default 100 and 500)
#   send-limit.sh off                    remove the limits
#   send-limit.sh exempt MAILBOX         no limit for MAILBOX (newsletters, scanners)
#   send-limit.sh unexempt MAILBOX
#
# A message to five recipients counts as five, and one message may not have
# more recipients than the hourly limit. Over the limit the server answers
# with a temporary error, and the mail client reports that it could not send.
# Limits apply to every mailbox, including webmail users.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/ratelimit.sh
. "$SCRIPT_DIR/lib/ratelimit.sh"
require_root

usage() { sed -n '2,14s/^# \{0,1\}//p' "$0"; }

apply() {
    write_rspamd_ratelimit_config
    rspamadm configtest >/dev/null || die "Rspamd rejected the new configuration"
    write_submission_recipient_limit
    systemctl reload rspamd postfix
}

is_exempt() { grep -Fxq "$1" "$SEND_LIMIT_EXEMPT_FILE" 2>/dev/null; }

ACTION="${1:-}"
case "$ACTION" in
    show)
        [[ $# -eq 1 ]] || { usage >&2; exit 2; }
        read -r hour day < <(send_limits)
        if [[ "$hour" == off ]]; then
            warn "Sending limits are off"
        else
            echo "Each mailbox may send to ${hour} recipients per hour and ${day} per day."
        fi
        echo "Exempt mailboxes:"
        grep -v '^#' "$SEND_LIMIT_EXEMPT_FILE" 2>/dev/null | sed 's/^/  /' | grep . || echo "  none"
        echo "Recent hits:"
        grep -h 'ratelimit "mailbox_' /var/log/rspamd/rspamd.log 2>/dev/null \
            | sed -E 's/^([0-9-]+ [0-9:]+).*ratelimit "mailbox_([a-z]+)\(([^)]*)\)".*/  \1  \3 (\2)/' \
            | tail -10 | grep . || echo "  none"
        ;;
    set)
        [[ $# -eq 3 ]] || { usage >&2; exit 2; }
        [[ "$2" =~ ^[1-9][0-9]*$ && "$3" =~ ^[1-9][0-9]*$ ]] || die "Limits must be positive whole numbers"
        (( $3 >= $2 )) || die "The daily limit must not be lower than the hourly one"
        install -d -m 0755 /etc/mailserver
        echo "$2 $3" > "$SEND_LIMIT_FILE"
        apply
        ok "Each mailbox may now send to $2 recipients per hour and $3 per day"
        ;;
    off)
        [[ $# -eq 1 ]] || { usage >&2; exit 2; }
        install -d -m 0755 /etc/mailserver
        echo off > "$SEND_LIMIT_FILE"
        apply
        warn "Sending limits are off; a stolen password can now send unlimited mail"
        ;;
    exempt|unexempt)
        [[ $# -eq 2 ]] || { usage >&2; exit 2; }
        MAILBOX="${2,,}"
        write_rspamd_ratelimit_config
        if [[ "$ACTION" == exempt ]]; then
            has_user "$MAILBOX" || die "Mailbox ${MAILBOX} does not exist"
            if is_exempt "$MAILBOX"; then
                info "${MAILBOX} is already exempt"
                exit 0
            fi
            echo "$MAILBOX" >> "$SEND_LIMIT_EXEMPT_FILE"
            apply
            ok "${MAILBOX} has no sending limit"
        else
            is_exempt "$MAILBOX" || die "${MAILBOX} is not exempt"
            filter_file "$SEND_LIMIT_EXEMPT_FILE" -v m="$MAILBOX" '$0 != m'
            apply
            ok "${MAILBOX} is limited again"
        fi
        ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
esac
