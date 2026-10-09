#!/bin/bash
# Manage which mailboxes may send as other addresses of hosted domains.
#
#   send-as.sh grant  MAILBOX ADDRESS   allow MAILBOX to send as ADDRESS
#   send-as.sh grant  MAILBOX @DOMAIN   allow MAILBOX to send as any address of DOMAIN
#   send-as.sh revoke MAILBOX ADDRESS|@DOMAIN
#   send-as.sh list   [MAILBOX]
#
# Every mailbox can always send as itself, and as every alias that delivers to
# it; those rights need no grant. Addresses of domains this server does not
# host cannot be granted: they would fail SPF, DKIM and DMARC anyway.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/maps.sh
. "$SCRIPT_DIR/lib/maps.sh"
require_root

usage() { sed -n '2,11s/^# \{0,1\}//p' "$0"; }

ACTION="${1:-}"
case "$ACTION" in
    grant|revoke)
        [[ $# -eq 3 ]] || { usage >&2; exit 2; }
        MAILBOX="${2,,}" TARGET="${3,,}"
        has_user "$MAILBOX" || die "Mailbox ${MAILBOX} does not exist"
        if [[ "$TARGET" == @* ]]; then
            DOMAIN="${TARGET#@}"
        else
            [[ "$TARGET" =~ ^[a-z0-9._+-]+@[a-z0-9.-]+$ ]] || die "Invalid address: ${TARGET}"
            DOMAIN="${TARGET#*@}"
        fi
        is_local_domain "$DOMAIN" || die "${DOMAIN} is not hosted on this server"
        [[ "$TARGET" != "$MAILBOX" ]] || die "A mailbox can always send as itself"

        install -d -m 0755 /etc/mailserver
        touch "$SEND_AS_FILE"
        if [[ "$ACTION" == grant ]]; then
            if awk -v a="$TARGET" -v m="$MAILBOX" '$1 == a && $2 == m {f=1} END {exit !f}' "$SEND_AS_FILE"; then
                info "${MAILBOX} may already send as ${TARGET}"
                exit 0
            fi
            printf '%s\t%s\n' "$TARGET" "$MAILBOX" >> "$SEND_AS_FILE"
            apply_postfix_maps
            ok "${MAILBOX} may now send as ${TARGET}"
        else
            awk -v a="$TARGET" -v m="$MAILBOX" '$1 == a && $2 == m {f=1} END {exit !f}' "$SEND_AS_FILE" \
                || die "${MAILBOX} has no grant for ${TARGET}"
            filter_file "$SEND_AS_FILE" -v a="$TARGET" -v m="$MAILBOX" '!($1 == a && $2 == m)'
            apply_postfix_maps
            ok "${MAILBOX} may no longer send as ${TARGET}"
        fi
        ;;
    list)
        FILTER="${2:-}"
        sync_postfix_maps
        echo "Address -> mailboxes allowed to send as it"
        awk -v m="${FILTER,,}" '
            m == "" { printf "  %-40s %s\n", $1, $2; next }
            { n = split($2, o, ","); for (i = 1; i <= n; i++) if (o[i] == m) { printf "  %-40s %s\n", $1, $2; break } }
        ' /etc/postfix/sender_login_maps
        ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
esac
