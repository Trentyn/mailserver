#!/bin/bash
# Delete a domain and all of its mailboxes
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

CURRENT_DOMAINS=$(postconf -h virtual_mailbox_domains 2>/dev/null | tr ',' '\n' | xargs) \
    || die "Postfix is not configured. Run setup.sh first"

[[ -z "$CURRENT_DOMAINS" ]] && die "No domains are configured."

step "Delete domain"

echo
echo "Configured domains:"
echo "$CURRENT_DOMAINS" | tr ' ' '\n' | while read -r d; do echo "  • $d"; done
echo

ask "Domain to delete:"
read -r DEL_DOMAIN
DEL_DOMAIN="${DEL_DOMAIN,,}"

echo "$CURRENT_DOMAINS" | tr ' ' '\n' | grep -qx "$DEL_DOMAIN" \
    || die "Domain '${DEL_DOMAIN}' not found"

# Mailboxes for this domain
DOMAIN_MAILBOXES=$(grep "@${DEL_DOMAIN}:" /etc/dovecot/users 2>/dev/null | cut -d: -f1 || true)
MAIL_DIR="/var/mail/vhosts/${DEL_DOMAIN}"
MAIL_SIZE="no data"
[[ -d "$MAIL_DIR" ]] && MAIL_SIZE=$(du -sh "$MAIL_DIR" 2>/dev/null | cut -f1)

# Check whether this is the last domain
DOMAIN_COUNT=$(echo "$CURRENT_DOMAINS" | wc -w)
if [[ "$DOMAIN_COUNT" -eq 1 ]]; then
    warn "This is the LAST domain on the server!"
    warn "After deletion, Postfix will no longer accept mail."
fi

echo
echo -e "${RED}${BOLD}WARNING! This action is irreversible!${NC}"
echo
echo "  Domain : ${DEL_DOMAIN}"
echo "  Data: ${MAIL_DIR} (${MAIL_SIZE})"
if [[ -n "$DOMAIN_MAILBOXES" ]]; then
    echo
    echo "  Mailboxes that will be deleted:"
    echo "$DOMAIN_MAILBOXES" | while read -r m; do [[ -n "$m" ]] && echo "    • $m"; done
fi
echo
ask "Enter the domain again to confirm:"
read -r CONFIRM_DOMAIN

[[ "$CONFIRM_DOMAIN" == "$DEL_DOMAIN" ]] || { info "Domain does not match. Cancelled."; exit 0; }

step "Deleting"

# New domain list without the deleted domain
NEW_DOMAIN_LIST=$(echo "$CURRENT_DOMAINS" | tr ' ' '\n' | grep -vx "$DEL_DOMAIN" || true)
if [[ -z "$NEW_DOMAIN_LIST" ]]; then
    postconf -e "virtual_mailbox_domains ="
    warn "virtual_mailbox_domains is now empty — the server accepts mail for no domains"
else
    NEW_DOMAINS=$(echo "$NEW_DOMAIN_LIST" | paste -sd ',' | sed 's/,/, /g')
    postconf -e "virtual_mailbox_domains = ${NEW_DOMAINS}"
fi
ok "Removed from virtual_mailbox_domains"

# Dovecot users
if grep -q "@${DEL_DOMAIN}:" /etc/dovecot/users 2>/dev/null; then
    sed -i "/@${DEL_DOMAIN}:/d" /etc/dovecot/users
    ok "Mailboxes removed from /etc/dovecot/users"
fi

# Postfix vmailbox
if grep -qE "@${DEL_DOMAIN}|#.*${DEL_DOMAIN}" /etc/postfix/vmailbox 2>/dev/null; then
    sed -i "/@${DEL_DOMAIN}/d" /etc/postfix/vmailbox
    sed -i "/^#.*${DEL_DOMAIN}/d" /etc/postfix/vmailbox
    postmap /etc/postfix/vmailbox
    ok "Mailboxes removed from vmailbox"
fi

# Dovecot postmaster_address
if grep -q "postmaster@${DEL_DOMAIN}" /etc/dovecot/local.conf 2>/dev/null; then
    sed -i "s|postmaster_address = postmaster@${DEL_DOMAIN}|postmaster_address = postmaster@localhost|" /etc/dovecot/local.conf
    ok "postmaster_address reset in Dovecot"
fi

# DKIM
if grep -q "^${DEL_DOMAIN}" /etc/rspamd/dkim_selectors.map 2>/dev/null; then
    sed -i "/^${DEL_DOMAIN}/d" /etc/rspamd/dkim_selectors.map
    ok "Removed from dkim_selectors.map"
fi
DKIM_FILES=(/var/lib/rspamd/dkim/${DEL_DOMAIN}.*)
if [[ -e "${DKIM_FILES[0]}" ]]; then
    rm -f /var/lib/rspamd/dkim/${DEL_DOMAIN}.*
    ok "DKIM keys removed"
fi

# Maildir
if [[ -d "$MAIL_DIR" ]]; then
    rm -rf "$MAIL_DIR"
    ok "Maildir removed: ${MAIL_DIR}"
fi

systemctl reload postfix dovecot rspamd

ok "Domain ${DEL_DOMAIN} removed"
