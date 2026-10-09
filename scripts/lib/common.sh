# Shared helpers for the mail server scripts. Source it, do not run it:
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck shell=bash

# shellcheck disable=SC2034  # Colors are used by the scripts that source this file.
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# "su" without "-" keeps the user's PATH, which on Debian lacks the sbin
# directories that hold postconf, postmap, doveadm and ufw.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step()  { echo -e "\n${BOLD}${CYAN}══ $* ${NC}"; }
ask()   { echo -en "${YELLOW}[?]${NC} $* "; }

require_root() {
    [[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
}

# Public IPv4 of this server; falls back to the first local address.
public_ipv4() {
    local url ip
    for url in https://api.ipify.org https://ifconfig.me; do
        ip=$(curl -4fsS --max-time 5 "$url" 2>/dev/null || true)
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            echo "$ip"
            return
        fi
    done
    hostname -I | awk '{print $1}'
}

# Exact-match helpers. Addresses and domains contain regex metacharacters
# ('.', '+'), so grep/sed patterns could match a different mailbox or domain
# (example.com would also match example.com.au). Compare whole fields instead.

# has_user EMAIL: the mailbox exists in the Dovecot users file.
has_user() {
    awk -F: -v k="$1" '$1 == k {f=1} END {exit !f}' /etc/dovecot/users 2>/dev/null
}

# filter_file FILE AWK_ARGS...: rewrite FILE through awk in place. cat keeps
# the original owner and mode, which mv from a temp file would not.
filter_file() {
    local file="$1"; shift
    [[ -f "$file" ]] || return 0
    awk "$@" "$file" > "${file}.tmp"
    cat "${file}.tmp" > "$file"
    rm -f "${file}.tmp"
}

# dkim_selector DOMAIN: the selector configured for DOMAIN, or nothing.
dkim_selector() {
    awk -v d="$1" '$1 == d {print $2; exit}' /etc/rspamd/dkim_selectors.map 2>/dev/null || true
}

# IN_DOMAIN: awk function for "-v d=DOMAIN" programs; in_domain(f) is true
# only when f is exactly "<user>@DOMAIN".
IN_DOMAIN='function in_domain(f) { n = split(f, a, "@"); return n == 2 && a[2] == d }'

# domain_of DOMAIN: print the first-column addresses on stdin that belong to DOMAIN.
domain_of() {
    awk -v d="$1" "$IN_DOMAIN"' in_domain($1) {print $1}'
}
