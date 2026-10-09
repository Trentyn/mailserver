#!/bin/bash
# Exempt trusted clients, such as a webmail server, from fail2ban bans.
#
#   trusted-client.sh add    IP|CIDR|HOSTNAME
#   trusted-client.sh remove IP|CIDR|HOSTNAME
#   trusted-client.sh list
#
# A webmail server logs every user in from its own IP address, so a few
# mistyped passwords would otherwise ban that address and cut off webmail for
# everyone. For a client on a dynamic IP (a home connection), add a DDNS
# hostname that follows the address; fail2ban re-resolves it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
require_root

LIST=/etc/mailserver/trusted-clients
JAIL=/etc/fail2ban/jail.d/mailserver-trusted.local
usage() { sed -n '2,6s/^# \{0,1\}//p' "$0"; }

valid_entry() {
    local e="$1"
    [[ "$e" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$ ]] && return 0
    [[ "$e" =~ ^[0-9a-f:]+(/[0-9]{1,3})?$ && "$e" == *:* ]] && return 0
    [[ "$e" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

# Addresses the entry stands for right now (a hostname resolves to several).
addresses_of() {
    if [[ "$1" =~ ^[0-9./]+$ || "$1" == *:* ]]; then
        echo "$1"
    else
        getent ahosts "$1" | awk '{print $1}' | sort -u
    fi
}

write_jail() {
    local entries
    entries=$(paste -sd' ' "$LIST")
    cat > "$JAIL" << EOF
# Managed by scripts/trusted-client.sh; edit with that script.
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1${entries:+ $entries}
EOF
    fail2ban-client reload >/dev/null
}

install -d -m 0755 /etc/mailserver
touch "$LIST"
ACTION="${1:-}"
case "$ACTION" in
    add)
        [[ $# -eq 2 ]] || { usage >&2; exit 2; }
        ENTRY="${2,,}"
        valid_entry "$ENTRY" || die "Not an IP address, network or hostname: ${ENTRY}"
        if grep -Fxq "$ENTRY" "$LIST"; then
            info "${ENTRY} is already trusted"
            exit 0
        fi
        ADDRESSES=$(addresses_of "$ENTRY")
        [[ -n "$ADDRESSES" ]] || die "${ENTRY} does not resolve"
        echo "$ENTRY" >> "$LIST"
        write_jail
        # Lift a ban that is already in place.
        while read -r ip; do
            [[ "$ip" == */* ]] || fail2ban-client unban "$ip" >/dev/null 2>&1 || true
        done <<< "$ADDRESSES"
        ok "fail2ban will never ban ${ENTRY} ($(echo "$ADDRESSES" | paste -sd' '))"
        ;;
    remove)
        [[ $# -eq 2 ]] || { usage >&2; exit 2; }
        ENTRY="${2,,}"
        grep -Fxq "$ENTRY" "$LIST" || die "${ENTRY} is not in the trusted list"
        filter_file "$LIST" -v e="$ENTRY" '$0 != e'
        write_jail
        ok "${ENTRY} is no longer exempt from fail2ban"
        ;;
    list)
        if [[ -s "$LIST" ]]; then
            while read -r entry; do
                echo "  ${entry}  ($(addresses_of "$entry" | paste -sd' '))"
            done < "$LIST"
        else
            echo "  No trusted clients"
        fi
        ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
esac
