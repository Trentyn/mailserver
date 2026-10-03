#!/bin/bash
# Delete mailbox
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

grep -q "^${EMAIL}:" /etc/dovecot/users || die "Mailbox '${EMAIL}' was not found"

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
echo "  • entry from /etc/postfix/vmailbox"
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
sed -i "/^${EMAIL}:/d" /etc/dovecot/users
ok "Removed from /etc/dovecot/users"

# Postfix vmailbox
if grep -q "^${EMAIL}" /etc/postfix/vmailbox 2>/dev/null; then
    sed -i "/^${EMAIL}/d" /etc/postfix/vmailbox
    postmap /etc/postfix/vmailbox
    ok "Removed from vmailbox"
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
