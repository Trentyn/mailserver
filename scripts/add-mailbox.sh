#!/bin/bash
# Add mailbox
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/maps.sh
. "$SCRIPT_DIR/lib/maps.sh"
# shellcheck source=lib/password.sh
. "$SCRIPT_DIR/lib/password.sh"
require_root

# ── Current domains ────────────────────────────────────────────────────────────
CURRENT_DOMAINS=$(postconf -h virtual_mailbox_domains 2>/dev/null | tr ',' '\n' | xargs) \
    || die "Postfix is not configured. Run setup.sh first"

[[ -z "$CURRENT_DOMAINS" ]] && die "No domains are configured. Add a domain with add-domain.sh first"

step "Add mailbox"

echo
echo "Available domains:"
echo "$CURRENT_DOMAINS" | tr ' ' '\n' | while read -r d; do
    echo "  • $d"
done
echo

# ── Choose domain ──────────────────────────────────────────────────────────────
DOMAIN_COUNT=$(echo "$CURRENT_DOMAINS" | wc -w)
if [[ "$DOMAIN_COUNT" -eq 1 ]]; then
    MAIL_DOMAIN=$(echo "$CURRENT_DOMAINS" | xargs)
    info "Using the only configured domain: ${BOLD}${MAIL_DOMAIN}${NC}"
else
    ask "Domain for mailbox:"
    read -r MAIL_DOMAIN
    MAIL_DOMAIN="${MAIL_DOMAIN,,}"
    if ! echo "$CURRENT_DOMAINS" | tr ' ' '\n' | grep -Fxq "$MAIL_DOMAIN"; then
        die "Domain '${MAIL_DOMAIN}' not found. Add it with add-domain.sh first"
    fi
fi

# ── Email address ───────────────────────────────────────────────────────────────
ask "Username (before @):"
read -r USERNAME
USERNAME="${USERNAME,,}"
[[ -z "$USERNAME" ]] && die "Username cannot be empty"
[[ "$USERNAME" =~ ^[a-z0-9._+-]+$ ]] || die "Invalid characters in username"

EMAIL="${USERNAME}@${MAIL_DOMAIN}"

# Check whether the mailbox already exists
if has_user "$EMAIL"; then
    die "Mailbox ${EMAIL} already exists"
fi

# ── Password ────────────────────────────────────────────────────────────────────
read_new_password "Password for ${EMAIL}"

echo
echo "  Email : $EMAIL"
echo
ask "Create mailbox? [y/N]:"
read -r confirm
[[ "${confirm,,}" == "y" ]] || { info "Cancelled."; exit 0; }

# ── Create mailbox ──────────────────────────────────────────────────────────────
step "Creating mailbox"

# Password hash
HASH=$(hash_password "$NEW_PASSWORD")

# Dovecot users
echo "${EMAIL}:${HASH}" >> /etc/dovecot/users
ok "Added to /etc/dovecot/users"

# Postfix vmailbox
echo "${EMAIL}    ${MAIL_DOMAIN}/${USERNAME}/" >> /etc/postfix/vmailbox
postmap /etc/postfix/vmailbox
sync_postfix_maps
ok "Added to vmailbox"

# Maildir directory
mkdir -p "/var/mail/vhosts/${MAIL_DOMAIN}/${USERNAME}"/{cur,new,tmp}
chown -R vmail:vmail "/var/mail/vhosts/${MAIL_DOMAIN}/${USERNAME}"
chmod -R 700 "/var/mail/vhosts/${MAIL_DOMAIN}/${USERNAME}"
ok "Maildir created"

# Dovecot notices passwd-file changes by mtime with one-second resolution, so a
# mailbox added right after another one can briefly look unknown. Reload and
# wait until Dovecot resolves the new user before touching its mailboxes.
systemctl reload postfix dovecot
for _ in {1..20}; do
    doveadm user "$EMAIL" >/dev/null 2>&1 && break
    sleep 0.5
done
doveadm user "$EMAIL" >/dev/null 2>&1 || die "Dovecot does not see ${EMAIL} yet. Check: doveadm user ${EMAIL}"

# Dovecot may already have auto-created them on first access.
EXISTING_MAILBOXES=$(doveadm mailbox list -u "$EMAIL")
for mailbox in Sent Drafts Trash Junk Archive; do
    grep -Fxq "$mailbox" <<<"$EXISTING_MAILBOXES" || doveadm mailbox create -u "$EMAIL" "$mailbox"
done
ok "System mailboxes created: Sent, Drafts, Trash, Junk, Archive"
# ── Authentication check ───────────────────────────────────────────────────
sleep 1
if auth_ok "$EMAIL" "$NEW_PASSWORD"; then
    ok "Authentication for ${EMAIL} ✓"
else
    warn "Authentication failed — check: doveadm auth test '${EMAIL}'"
fi

# ── Summary ──────────────────────────────────────────────────────────────────────
MAIL_HOSTNAME=$(postconf -h myhostname)

step "Done!"
echo
echo -e "${GREEN}${BOLD}Mailbox ${EMAIL} created!${NC}"
echo
echo "Mail client settings:"
echo
printf "  %-10s %s\n" "IMAP:"   "${MAIL_HOSTNAME}:993  (SSL/TLS)"
printf "  %-10s %s\n" "POP3:"   "${MAIL_HOSTNAME}:995  (SSL/TLS)"
printf "  %-10s %s\n" "SMTP:"   "${MAIL_HOSTNAME}:587  (STARTTLS)"
printf "  %-10s %s\n" "Login:"    "${EMAIL}"
if [[ "$PASSWORD_GENERATED" == true ]]; then
    show_password_once "$EMAIL" "$NEW_PASSWORD"
fi
echo
