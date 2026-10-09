#!/bin/bash
# Manage aliases and catch-all addresses of hosted domains.
#
#   alias.sh add    ALIAS TARGET     deliver ALIAS to TARGET (repeat to add targets)
#   alias.sh add    @DOMAIN TARGET   catch-all: deliver unknown addresses of DOMAIN
#   alias.sh remove ALIAS [TARGET]   remove one target, or the whole alias
#   alias.sh list   [DOMAIN]
#   alias.sh sync                    apply hand edits of /etc/postfix/virtual
#
# TARGET can be a local mailbox or an external address. Local mailboxes an
# alias delivers to may also send as the alias; a catch-all grants no sending
# rights (use send-as.sh for that).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/maps.sh
. "$SCRIPT_DIR/lib/maps.sh"
require_root

VIRTUAL=/etc/postfix/virtual
EMAIL_RE='^[a-z0-9._+-]+@[a-z0-9.-]+\.[a-z]{2,63}$'
usage() { sed -n '2,12s/^# \{0,1\}//p' "$0"; }

# targets_of ALIAS: the alias's targets, one per line.
targets_of() {
    awk -v a="$1" '$1 == a { sub(/^[^ \t]+[ \t]+/, ""); gsub(/[ \t]/, ""); n = split($0, t, ","); for (i = 1; i <= n; i++) print t[i] }' "$VIRTUAL"
}

# set_targets ALIAS TARGET...: replace the alias line, or drop it with no targets.
set_targets() {
    local alias="$1"; shift
    local joined
    joined=$(IFS=,; echo "$*")
    joined="${joined//,/, }"
    filter_file "$VIRTUAL" -v a="$alias" '$1 != a'
    [[ $# -gt 0 ]] && printf '%s\t%s\n' "$alias" "$joined" >> "$VIRTUAL"
    apply_postfix_maps
}

touch "$VIRTUAL"
ACTION="${1:-}"
case "$ACTION" in
    add)
        [[ $# -eq 3 ]] || { usage >&2; exit 2; }
        ALIAS="${2,,}" TARGET="${3,,}"
        if [[ "$ALIAS" == @* ]]; then
            DOMAIN="${ALIAS#@}"
        else
            [[ "$ALIAS" =~ $EMAIL_RE ]] || die "Invalid alias: ${ALIAS}"
            DOMAIN="${ALIAS#*@}"
            has_user "$ALIAS" && die "${ALIAS} is a mailbox; an alias with the same address would hide it"
        fi
        is_local_domain "$DOMAIN" || die "${DOMAIN} is not hosted on this server"
        [[ "$TARGET" =~ $EMAIL_RE ]] || die "Invalid target: ${TARGET}"
        if is_local_domain "${TARGET#*@}" && ! has_user "$TARGET" && [[ -z "$(targets_of "$TARGET")" ]]; then
            die "${TARGET} is neither a mailbox nor an alias on this server"
        fi

        mapfile -t TARGETS < <(targets_of "$ALIAS")
        for t in "${TARGETS[@]}"; do
            [[ "$t" == "$TARGET" ]] && { info "${ALIAS} already delivers to ${TARGET}"; exit 0; }
        done
        set_targets "$ALIAS" "${TARGETS[@]}" "$TARGET"
        ok "${ALIAS} now delivers to: $(targets_of "$ALIAS" | paste -sd' ')"
        ;;
    remove)
        [[ $# -eq 2 || $# -eq 3 ]] || { usage >&2; exit 2; }
        ALIAS="${2,,}" TARGET="${3:-}"
        TARGET="${TARGET,,}"
        mapfile -t TARGETS < <(targets_of "$ALIAS")
        [[ ${#TARGETS[@]} -gt 0 ]] || die "Alias ${ALIAS} does not exist"
        if [[ -z "$TARGET" ]]; then
            set_targets "$ALIAS"
            ok "Removed alias ${ALIAS}"
        else
            KEEP=()
            for t in "${TARGETS[@]}"; do [[ "$t" == "$TARGET" ]] || KEEP+=("$t"); done
            [[ ${#KEEP[@]} -lt ${#TARGETS[@]} ]] || die "${ALIAS} does not deliver to ${TARGET}"
            set_targets "$ALIAS" "${KEEP[@]}"
            if [[ ${#KEEP[@]} -eq 0 ]]; then
                ok "Removed alias ${ALIAS} (no targets left)"
            else
                ok "${ALIAS} now delivers to: ${KEEP[*]}"
            fi
        fi
        ;;
    list)
        DOMAIN="${2:-}"
        DOMAIN="${DOMAIN,,}"
        echo "Alias -> targets"
        awk -v d="$DOMAIN" '
            NF < 2 || $1 ~ /^#/ { next }
            { dom = $1; sub(/^[^@]*@/, "", dom) }
            d == "" || dom == d { a = $1; sub(/^[^ \t]+[ \t]+/, ""); printf "  %-40s %s\n", a, $0 }
        ' "$VIRTUAL"
        ;;
    sync)
        apply_postfix_maps
        ok "Postfix maps regenerated from /etc/postfix/virtual"
        ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
esac
