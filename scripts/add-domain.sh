#!/bin/bash
# Add a mail domain
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step()  { echo -e "\n${BOLD}${CYAN}══ $* ${NC}"; }
ask()   { echo -en "${YELLOW}[?]${NC} $* "; }

[[ $EUID -eq 0 ]] || die "Run as root"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MAIL_HOSTNAME=$(postconf -h myhostname 2>/dev/null) \
    || die "Postfix is not configured. Run setup.sh first"
SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null \
    || curl -4 -s --max-time 5 api.ipify.org 2>/dev/null \
    || hostname -I | awk '{print $1}')

info "Server: ${BOLD}${MAIL_HOSTNAME}${NC} (${SERVER_IP})"

step "New domain settings"

ask "New domain (example.com):"
read -r NEW_DOMAIN
[[ "$NEW_DOMAIN" == *.* ]] || die "Invalid domain"
NEW_DOMAIN="${NEW_DOMAIN,,}"

CURRENT_DOMAINS=$(postconf -h virtual_mailbox_domains 2>/dev/null || echo "")
if echo "$CURRENT_DOMAINS" | tr ',' '\n' | xargs | tr ' ' '\n' | grep -qx "$NEW_DOMAIN"; then
    die "Domain ${NEW_DOMAIN} already exists"
fi

ask "DKIM selector [mail$(date +%Y)]:"
read -r DKIM_SELECTOR
DKIM_SELECTOR="${DKIM_SELECTOR:-mail$(date +%Y)}"

echo
echo "  Domain         : $NEW_DOMAIN"
echo "  DKIM selector : $DKIM_SELECTOR"
echo "  MX server     : $MAIL_HOSTNAME"
echo
ask "Continue? [y/N]:"
read -r confirm
[[ "${confirm,,}" == "y" ]] || { info "Cancelled."; exit 0; }

# ── DNS check ──────────────────────────────────────────────────────────────
step "Checking DNS for ${NEW_DOMAIN}"

# Use the first MX record and remove its trailing dot
MX_RESOLVED=$(dig +short MX "$NEW_DOMAIN" @8.8.8.8 2>/dev/null \
    | sort -n | head -1 | awk '{print $2}' | sed 's/\.$//' || true)

if [[ "${MX_RESOLVED,,}" == "${MAIL_HOSTNAME,,}" ]]; then
    ok "MX ${NEW_DOMAIN} → ${MAIL_HOSTNAME} ✓"
else
    warn "MX for ${NEW_DOMAIN} → '${MX_RESOLVED:-not found}', expected '${MAIL_HOSTNAME}'"
    warn "Add the DNS records after the script finishes"
fi

# ── Postfix ───────────────────────────────────────────────────────────────────
step "Postfix"

if [[ -z "$CURRENT_DOMAINS" ]]; then
    postconf -e "virtual_mailbox_domains = ${NEW_DOMAIN}"
else
    postconf -e "virtual_mailbox_domains = ${CURRENT_DOMAINS}, ${NEW_DOMAIN}"
fi
ok "Added to virtual_mailbox_domains"

# ── DKIM ──────────────────────────────────────────────────────────────────────
step "DKIM key"

KEY_FILE="/var/lib/rspamd/dkim/${NEW_DOMAIN}.${DKIM_SELECTOR}.key"
PUB_FILE="/var/lib/rspamd/dkim/${NEW_DOMAIN}.${DKIM_SELECTOR}.pub"

mkdir -p /var/lib/rspamd/dkim
rspamadm dkim_keygen \
    -s "$DKIM_SELECTOR" \
    -d "$NEW_DOMAIN" \
    -k "$KEY_FILE" \
    > "$PUB_FILE"

chown _rspamd:_rspamd "$KEY_FILE" "$PUB_FILE"
chmod 440 "$KEY_FILE"

if ! grep -q "^${NEW_DOMAIN}" /etc/rspamd/dkim_selectors.map 2>/dev/null; then
    echo "${NEW_DOMAIN}    ${DKIM_SELECTOR}" >> /etc/rspamd/dkim_selectors.map
fi
ok "DKIM key generated"

# ── Reloading services ──────────────────────────────────────────────────────────────
step "Reloading services"
systemctl reload postfix rspamd
ok "Postfix and rspamd reloaded"

# ── DNS records ────────────────────────────────────────────────────────────────
step "DNS records for ${NEW_DOMAIN}"

echo
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║         DNS RECORDS FOR: ${NEW_DOMAIN}${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo
echo -e "${CYAN}── MX ───────────────────────────────────────────────────────${NC}"
printf "  %-40s  MX     %s\n" "${NEW_DOMAIN}." "10 ${MAIL_HOSTNAME}."
echo
echo -e "${CYAN}── SPF ──────────────────────────────────────────────────────${NC}"
printf "  %-40s  TXT    %s\n" "${NEW_DOMAIN}." '"v=spf1 mx ~all"'
echo
echo -e "${CYAN}── DKIM ─────────────────────────────────────────────────────${NC}"
printf "  Name:   %s\n" "${DKIM_SELECTOR}._domainkey.${NEW_DOMAIN}."
printf "  Type:   TXT\n"
echo   "  Value:"
grep -oE '"[^"]*"' "$PUB_FILE" | tr -d '"\n'; echo
echo
echo -e "${CYAN}── DMARC ────────────────────────────────────────────────────${NC}"
printf "  %-40s  TXT    %s\n" "_dmarc.${NEW_DOMAIN}." \
    '"v=DMARC1; p=quarantine; rua=mailto:dmarc@'"${NEW_DOMAIN}"'"'
echo

ok "Domain ${NEW_DOMAIN} added!"
echo
echo "  Add a mailbox: bash ${SCRIPT_DIR}/add-mailbox.sh"
