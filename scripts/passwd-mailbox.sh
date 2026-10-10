#!/bin/bash
# Change mailbox password
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/password.sh
. "$SCRIPT_DIR/lib/password.sh"
require_root

[[ -f /etc/dovecot/users ]] || die "/etc/dovecot/users was not found. Is the server configured?"

step "Change password"

# Show existing mailboxes
MAILBOXES=$(cut -d: -f1 /etc/dovecot/users)
[[ -z "$MAILBOXES" ]] && die "No mailboxes exist."

echo
echo "Existing mailboxes:"
echo "$MAILBOXES" | while read -r m; do echo "  • $m"; done
echo

ask "Email address:"
read -r EMAIL
EMAIL="${EMAIL,,}"

has_user "$EMAIL" || die "Mailbox '${EMAIL}' was not found"

read_new_password "New password for ${EMAIL}"
HASH=$(hash_password "$NEW_PASSWORD")

# Replace this address in the users file
filter_file /etc/dovecot/users -F: -v k="$EMAIL" -v h="$HASH" '$1 == k {print k ":" h; next} {print}'

systemctl reload dovecot

sleep 1
if auth_ok "$EMAIL" "$NEW_PASSWORD"; then
    ok "Password for ${EMAIL} changed ✓"
else
    warn "Password was saved, but authentication failed — check: doveadm auth test '${EMAIL}'"
fi
if [[ "$PASSWORD_GENERATED" == true ]]; then
    show_password_once "$EMAIL" "$NEW_PASSWORD"
fi
