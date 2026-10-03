#!/bin/bash
# Change mailbox password
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

grep -q "^${EMAIL}:" /etc/dovecot/users || die "Mailbox '${EMAIL}' was not found"

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
sed -i "s|^${EMAIL}:.*|${EMAIL}:${HASH}|" /etc/dovecot/users

systemctl reload dovecot

sleep 1
AUTH_RESULT=$(doveadm auth test "$EMAIL" "$NEW_PASS" 2>&1 || true)
if echo "$AUTH_RESULT" | grep -q "auth succeeded"; then
    ok "Password for ${EMAIL} changed ✓"
else
    warn "Password was saved, but authentication failed — check: doveadm auth test '${EMAIL}' 'password'"
fi
