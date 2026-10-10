#!/bin/bash
# Turn POP3 (ports 110 and 995) on or off. IMAP is not affected.
#
#   pop3.sh status
#   pop3.sh on
#   pop3.sh off
#
# Most mail clients use IMAP, which keeps mail on the server and in sync
# between devices. POP3 is only needed by old clients that download mail.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/pop3.sh
. "$SCRIPT_DIR/lib/pop3.sh"
require_root

usage() { sed -n '2,9s/^# \{0,1\}//p' "$0"; }

[[ $# -eq 1 ]] || { usage >&2; exit 2; }
case "$1" in
    status)
        if pop3_enabled; then ok "POP3 is on (ports 110 and 995)"; else info "POP3 is off"; fi
        ;;
    on|off)
        set_pop3 "$1"
        doveconf -n >/dev/null || die "Dovecot rejected the configuration"
        systemctl restart dovecot
        if [[ "$1" == on ]]; then ok "POP3 is on (ports 110 and 995)"; else ok "POP3 is off; ports 110 and 995 are closed"; fi
        ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
esac
