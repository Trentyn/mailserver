#!/bin/bash
# Delete a domain and all of its mailboxes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/maps.sh
. "$SCRIPT_DIR/lib/maps.sh"
require_root

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

echo "$CURRENT_DOMAINS" | tr ' ' '\n' | grep -Fxq "$DEL_DOMAIN" \
    || die "Domain '${DEL_DOMAIN}' not found"

# Mailboxes for this domain
DOMAIN_MAILBOXES=$(cut -d: -f1 /etc/dovecot/users 2>/dev/null | domain_of "$DEL_DOMAIN" || true)
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
filter_file /etc/dovecot/users -F: -v d="$DEL_DOMAIN" "$IN_DOMAIN"' !in_domain($1)'
ok "Mailboxes removed from /etc/dovecot/users"

# Postfix maps: mailboxes, sender ownership, and aliases from or to this domain
filter_file /etc/postfix/vmailbox -v d="$DEL_DOMAIN" "$IN_DOMAIN"' !in_domain($1)'
postmap /etc/postfix/vmailbox
ORPHANED=$(prune_aliases "@${DEL_DOMAIN}")
[[ -n "$ORPHANED" ]] && warn "Removed aliases that only delivered into ${DEL_DOMAIN}: $(echo "$ORPHANED" | paste -sd' ')"
# Send-as grants for the domain (address or @domain) or held by its mailboxes
filter_file "$SEND_AS_FILE" -v d="$DEL_DOMAIN" "$IN_DOMAIN"' !in_domain($1) && $1 != "@" d && !in_domain($2)'
filter_file /etc/mailserver/send-limit-exempt -v d="$DEL_DOMAIN" "$IN_DOMAIN"' !in_domain($0)'
sync_postfix_maps
ok "Mailboxes, aliases and send-as grants removed"

# Dovecot postmaster_address
if grep -q "postmaster@${DEL_DOMAIN}" /etc/dovecot/local.conf 2>/dev/null; then
    sed -i "s|postmaster_address = postmaster@${DEL_DOMAIN}|postmaster_address = postmaster@localhost|" /etc/dovecot/local.conf
    ok "postmaster_address reset in Dovecot"
fi

# DKIM
DEL_SELECTORS=$(awk -v d="$DEL_DOMAIN" '$1 == d {print $2}' /etc/rspamd/dkim_selectors.map 2>/dev/null || true)
filter_file /etc/rspamd/dkim_selectors.map -v d="$DEL_DOMAIN" '$1 != d'
for selector in $DEL_SELECTORS; do
    rm -f "/var/lib/rspamd/dkim/${DEL_DOMAIN}.${selector}.key" "/var/lib/rspamd/dkim/${DEL_DOMAIN}.${selector}.pub"
done
[[ -n "$DEL_SELECTORS" ]] && ok "DKIM selector and keys removed"

# Maildir
if [[ -d "$MAIL_DIR" ]]; then
    rm -rf "$MAIL_DIR"
    ok "Maildir removed: ${MAIL_DIR}"
fi

systemctl reload postfix dovecot rspamd

ok "Domain ${DEL_DOMAIN} removed"
