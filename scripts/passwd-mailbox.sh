#!/bin/bash
# Change mailbox password
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
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

while true; do
    ask "New password:"
    read -rs NEW_PASS; echo
    [[ -z "$NEW_PASS" ]] && warn "Password cannot be empty" && continue
    ask "Repeat password:"
    read -rs CONFIRM; echo
    [[ "$NEW_PASS" == "$CONFIRM" ]] && break
    warn "Passwords do not match"
done

HASH=$(doveadm pw -s SHA512-CRYPT -p "$NEW_PASS")

# Replace this address in the users file
filter_file /etc/dovecot/users -F: -v k="$EMAIL" -v h="$HASH" '$1 == k {print k ":" h; next} {print}'

systemctl reload dovecot

sleep 1
AUTH_RESULT=$(doveadm auth test "$EMAIL" "$NEW_PASS" 2>&1 || true)
if echo "$AUTH_RESULT" | grep -q "auth succeeded"; then
    ok "Password for ${EMAIL} changed ✓"
else
    warn "Password was saved, but authentication failed — check: doveadm auth test '${EMAIL}' 'password'"
fi
