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
NEW_DOMAIN="${NEW_DOMAIN,,}"
[[ "$NEW_DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || die "Invalid domain: ${NEW_DOMAIN}"

CURRENT_DOMAINS=$(postconf -h virtual_mailbox_domains 2>/dev/null || echo "")
if echo "$CURRENT_DOMAINS" | tr ',' '\n' | xargs | tr ' ' '\n' | grep -Fxq "$NEW_DOMAIN"; then
    die "Domain ${NEW_DOMAIN} already exists"
fi

ask "DKIM selector [mail$(date +%Y)]:"
read -r DKIM_SELECTOR
DKIM_SELECTOR="${DKIM_SELECTOR:-mail$(date +%Y)}"
DKIM_SELECTOR="${DKIM_SELECTOR,,}"
[[ "$DKIM_SELECTOR" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Invalid DKIM selector: use letters, digits and hyphens"

# postmaster@ is required by RFC 5321 and receives DMARC reports, so it must
# deliver to an existing mailbox. Default to the primary domain's postmaster.
DEFAULT_POSTMASTER=$(awk '$1 ~ /^postmaster@/ {print $2; exit}' /etc/postfix/virtual 2>/dev/null || true)
[[ -n "$DEFAULT_POSTMASTER" ]] || DEFAULT_POSTMASTER=$(head -1 /etc/dovecot/users 2>/dev/null | cut -d: -f1)
ask "Mailbox for postmaster@${NEW_DOMAIN} and abuse@${NEW_DOMAIN} [${DEFAULT_POSTMASTER}]:"
read -r POSTMASTER_TARGET
POSTMASTER_TARGET="${POSTMASTER_TARGET:-$DEFAULT_POSTMASTER}"
POSTMASTER_TARGET="${POSTMASTER_TARGET,,}"
awk -F: -v k="$POSTMASTER_TARGET" '$1 == k {f=1} END {exit !f}' /etc/dovecot/users 2>/dev/null \
    || die "Mailbox '${POSTMASTER_TARGET}' does not exist. Create it with add-mailbox.sh first"

echo
echo "  Domain         : $NEW_DOMAIN"
echo "  DKIM selector : $DKIM_SELECTOR"
echo "  MX server     : $MAIL_HOSTNAME"
echo "  postmaster@   : $POSTMASTER_TARGET"
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

# Installations created before alias support have no virtual_alias_maps yet.
if ! postconf -h virtual_alias_maps | grep -Fq 'hash:/etc/postfix/virtual'; then
    CURRENT_ALIAS_MAPS=$(postconf -h virtual_alias_maps)
    postconf -e "virtual_alias_maps = ${CURRENT_ALIAS_MAPS:+${CURRENT_ALIAS_MAPS}, }hash:/etc/postfix/virtual"
fi
touch /etc/postfix/virtual
for alias in postmaster abuse; do
    awk -v k="${alias}@${NEW_DOMAIN}" '$1 == k {f=1} END {exit !f}' /etc/postfix/virtual \
        || printf '%s\t%s\n' "${alias}@${NEW_DOMAIN}" "$POSTMASTER_TARGET" >> /etc/postfix/virtual
done
postmap /etc/postfix/virtual
ok "postmaster@ and abuse@ deliver to ${POSTMASTER_TARGET}"

# ── DKIM ──────────────────────────────────────────────────────────────────────
step "DKIM key"

KEY_FILE="/var/lib/rspamd/dkim/${NEW_DOMAIN}.${DKIM_SELECTOR}.key"
PUB_FILE="/var/lib/rspamd/dkim/${NEW_DOMAIN}.${DKIM_SELECTOR}.pub"

mkdir -p /var/lib/rspamd/dkim
if [[ -s "$KEY_FILE" && -s "$PUB_FILE" ]]; then
    info "Reusing the existing DKIM key for ${DKIM_SELECTOR}"
else
    rspamadm dkim_keygen \
        -b 2048 \
        -s "$DKIM_SELECTOR" \
        -d "$NEW_DOMAIN" \
        -k "$KEY_FILE" \
        > "$PUB_FILE"
fi

chown _rspamd:_rspamd "$KEY_FILE" "$PUB_FILE"
chmod 440 "$KEY_FILE"

if ! awk -v d="$NEW_DOMAIN" '$1 == d {f=1} END {exit !f}' /etc/rspamd/dkim_selectors.map 2>/dev/null; then
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
    "\"v=DMARC1; p=quarantine; rua=mailto:postmaster@${NEW_DOMAIN}\""
echo

ok "Domain ${NEW_DOMAIN} added!"
echo
echo "  Add a mailbox: bash ${SCRIPT_DIR}/add-mailbox.sh"
