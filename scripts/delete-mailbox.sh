#!/bin/bash
# Delete mailbox
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
require_root

[[ -f /etc/dovecot/users ]] || die "/etc/dovecot/users was not found. Is the server configured?"

step "Delete mailbox"

MAILBOXES=$(cut -d: -f1 /etc/dovecot/users)
[[ -z "$MAILBOXES" ]] && die "No mailboxes exist."

echo
echo "Existing mailboxes:"
echo "$MAILBOXES" | while read -r m; do echo "  • $m"; done
echo

ask "Email address to delete:"
read -r EMAIL
EMAIL="${EMAIL,,}"

has_user "$EMAIL" || die "Mailbox '${EMAIL}' was not found"

# Determine data path
DOMAIN="${EMAIL#*@}"
USERNAME="${EMAIL%@*}"
MAIL_DIR="/var/mail/vhosts/${DOMAIN}/${USERNAME}"

MAIL_SIZE="no data"
if [[ -d "$MAIL_DIR" ]]; then
    MAIL_SIZE=$(du -sh "$MAIL_DIR" 2>/dev/null | cut -f1)
fi

echo
echo -e "${RED}${BOLD}WARNING! This action is irreversible!${NC}"
echo
echo "  Mailbox: ${EMAIL}"
echo "  Data: ${MAIL_DIR} (${MAIL_SIZE})"
echo
echo "The following will be deleted:"
echo "  • entry from /etc/dovecot/users"
echo "  • entries from /etc/postfix/vmailbox and sender_login_maps"
echo "  • aliases in /etc/postfix/virtual that deliver to this mailbox"
echo "  • all mail in ${MAIL_DIR}"
echo
ask "Enter the email again to confirm:"
read -r CONFIRM_EMAIL

if [[ "$CONFIRM_EMAIL" != "$EMAIL" ]]; then
    info "Email does not match. Cancelled."
    exit 0
fi

step "Deleting"

# Dovecot users
filter_file /etc/dovecot/users -F: -v k="$EMAIL" '$1 != k'
ok "Removed from /etc/dovecot/users"

# Postfix maps
for map in /etc/postfix/vmailbox /etc/postfix/sender_login_maps; do
    [[ -f "$map" ]] || continue
    filter_file "$map" -v k="$EMAIL" '$1 != k'
    postmap "$map"
done
ok "Removed from vmailbox and sender_login_maps"

if [[ -f /etc/postfix/virtual ]]; then
    ORPHANED=$(awk -v e="$EMAIL" '$2 == e {print $1}' /etc/postfix/virtual)
    if [[ -n "$ORPHANED" ]]; then
        filter_file /etc/postfix/virtual -v e="$EMAIL" '$1 != e && $2 != e'
        postmap /etc/postfix/virtual
        warn "Removed aliases that delivered to ${EMAIL}: $(echo "$ORPHANED" | paste -sd' ')"
        warn "Point them to another mailbox in /etc/postfix/virtual, then run: postmap /etc/postfix/virtual"
    fi
fi

# Maildir
if [[ -d "$MAIL_DIR" ]]; then
    rm -rf "$MAIL_DIR"
    ok "Maildir removed: ${MAIL_DIR}"
else
    warn "Directory ${MAIL_DIR} was not found (already deleted?)"
fi

systemctl reload postfix dovecot

ok "Mailbox ${EMAIL} removed"
