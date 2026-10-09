#!/bin/bash
# Bring a server installed by an older setup.sh up to date. Safe to run
# repeatedly; every step is idempotent and changed files are backed up first.
#
#   - certbot hooks: port 80 opens only during renewal (the old permanent
#     "HTTP Lets Encrypt" UFW rule is removed);
#   - fail2ban: a Dovecot 2.4 filter, without which IMAP/POP3 password guessing
#     was never banned;
#   - rotation for /var/log/dovecot.log;
#   - Postfix maps for aliases, catch-all and send-as grants.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/tls.sh
. "$SCRIPT_DIR/lib/tls.sh"
# shellcheck source=lib/fail2ban.sh
. "$SCRIPT_DIR/lib/fail2ban.sh"
# shellcheck source=lib/maps.sh
. "$SCRIPT_DIR/lib/maps.sh"
require_root

[[ -f /etc/postfix/main.cf && -f /etc/dovecot/local.conf ]] \
    || die "No mail server installation found. Use setup.sh on a clean server."

BACKUP="/root/mailserver-upgrade-backup-$(date +%Y%m%d-%H%M%S)"
install -d -m 0700 "$BACKUP"
for f in /etc/fail2ban/jail.local /etc/postfix/main.cf /etc/postfix/virtual /etc/postfix/sender_login_maps; do
    [[ -f "$f" ]] && cp -a "$f" "$BACKUP/"
done
info "Backup of changed files: ${BACKUP}"

step "Certificate renewal"
install_certbot_hooks
if command -v ufw >/dev/null && ufw status | grep -Fq 'HTTP Lets Encrypt'; then
    ufw delete allow 80/tcp >/dev/null
    ok "Closed port 80; it now opens only during certificate renewal"
else
    ok "Renewal hooks installed"
fi

step "fail2ban"
write_fail2ban_config
install_dovecot_logrotate
systemctl restart fail2ban
ok "fail2ban recognises Dovecot 2.4 login failures"

step "Postfix maps"
sync_postfix_maps
postfix check
systemctl reload postfix
ok "Alias, catch-all and send-as maps are in place"

echo
ok "Upgrade complete. Run: sudo bash ${SCRIPT_DIR}/verify-mailserver.sh"
