#!/bin/bash
# Production readiness check for this mail server. Does not modify the system.
set -euo pipefail
# sbin directories are missing from PATH under "su" without "-".
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
bad()  { echo -e "${RED}[FAIL]${NC} $*"; failures=$((failures + 1)); }

[[ $EUID -eq 0 ]] || { echo 'Run as root: sudo bash verify-mailserver.sh'; exit 2; }

MAIL_HOSTNAME="${1:-$(postconf -h myhostname)}"
MAIL_DOMAIN="${2:-$(postconf -h virtual_mailbox_domains | awk -F, '{gsub(/ /, "", $1); print $1}')}"
DKIM_SELECTOR="${3:-$(awk -v d="$MAIL_DOMAIN" '$1 == d {print $2; exit}' /etc/rspamd/dkim_selectors.map 2>/dev/null || true)}"
DKIM_SELECTOR="${DKIM_SELECTOR:-mail$(date +%Y)}"
SERVER_IP=$(curl -4fsS --max-time 10 https://api.ipify.org || true)
failures=0

[[ -n "$MAIL_HOSTNAME" && -n "$MAIL_DOMAIN" && -n "$SERVER_IP" ]] \
  || { echo 'Unable to determine hostname, domain, or public IPv4.'; exit 2; }

echo "Checking ${MAIL_HOSTNAME} for ${MAIL_DOMAIN} (IPv4 ${SERVER_IP})"

for svc in postfix dovecot rspamd redis-server fail2ban; do
  systemctl is-active --quiet "$svc" && ok "service $svc" || bad "service $svc is not active"
done

postfix check >/dev/null 2>&1 && ok 'Postfix configuration' || bad 'Postfix configuration'
doveconf -n >/dev/null && ok 'Dovecot configuration' || bad 'Dovecot configuration'
if doveconf -n | grep -Eq '^mail_inbox_path = /var/mail/'; then
  bad 'Dovecot INBOX path points to system mail instead of virtual Maildir'
else
ok 'Dovecot virtual Maildir INBOX path'
fi
QUOTA_SIZE=$(doveconf -n | sed -n '/quota "User quota" {/,/}/s/^[[:space:]]*storage_size = //p' | head -1)
if [[ -n "$QUOTA_SIZE" ]]; then
  ok "Dovecot mailbox quota: ${QUOTA_SIZE}"
else
  bad 'Dovecot mailbox quota is not configured'
fi

DOVECOT_CONFIG=$(doveconf -n)
if grep -Fq 'special_use = "\\Sent"' <<<"$DOVECOT_CONFIG" \
  && grep -Fq 'special_use = "\\Drafts"' <<<"$DOVECOT_CONFIG" \
  && grep -Fq 'special_use = "\\Trash"' <<<"$DOVECOT_CONFIG" \
  && grep -Fq 'special_use = "\\Junk"' <<<"$DOVECOT_CONFIG" \
  && grep -Fq 'special_use = "\\Archive"' <<<"$DOVECOT_CONFIG" \
  && grep -Fq 'sieve_extprograms = yes' <<<"$DOVECOT_CONFIG" \
  && grep -Fq 'sieve_imapsieve = yes' <<<"$DOVECOT_CONFIG"; then
  ok 'Dovecot system mailboxes, Junk delivery and IMAPSieve training'
else
  bad 'Dovecot system mailbox, Junk delivery or IMAPSieve configuration is missing'
fi

missing_system_mailboxes=0
while IFS=: read -r mailbox _; do
  [[ -n "$mailbox" ]] || continue
  for system_mailbox in Sent Drafts Trash Junk Archive; do
    if ! doveadm mailbox list -u "$mailbox" | grep -Fxq "$system_mailbox"; then
      bad "${system_mailbox} mailbox is missing for ${mailbox}"
      missing_system_mailboxes=1
    fi
  done
done < /etc/dovecot/users
(( missing_system_mailboxes == 0 )) && ok 'System mailboxes exist for every user'

if [[ -f /etc/rspamd/local.d/redis.conf ]] \
  && grep -Fq '127.0.0.1:6379' /etc/rspamd/local.d/redis.conf \
  && redis-cli -h 127.0.0.1 ping 2>/dev/null | grep -Fxq PONG; then
  ok 'Rspamd Redis Bayes backend'
else
  bad 'Rspamd Redis Bayes backend'
fi

rspamadm configtest >/dev/null && ok 'Rspamd configuration' || bad 'Rspamd configuration'
# Retention 0 during setup deliberately skips the timer, so its absence is not a failure.
if systemctl is-active --quiet mailserver-mail-cleanup.timer; then
  ok 'Trash and Junk cleanup timer'
elif [[ -f /etc/systemd/system/mailserver-mail-cleanup.timer ]]; then
  bad 'Trash and Junk cleanup timer is installed but not active'
else
  warn 'Trash and Junk cleanup is disabled (install-mail-cleanup-timer.sh enables it)'
fi

# Not "apt-config dump | grep -q": with pipefail, grep stopping early makes
# apt-config die of SIGPIPE and the check fail on a working server.
if [[ "$(apt-config shell v APT::Periodic::Unattended-Upgrade 2>/dev/null)" != "v='1'" ]]; then
  warn 'Automatic security updates are off (upgrade.sh turns them on)'
elif ! systemctl is-enabled --quiet apt-daily-upgrade.timer 2>/dev/null; then
  warn 'Automatic security updates are configured, but apt-daily-upgrade.timer is not enabled'
else
  ok 'Automatic security updates'
fi
if grep -q 'mailbox_hourly' /etc/rspamd/local.d/ratelimit.conf 2>/dev/null; then
  ok 'Sending limit per mailbox'
else
  warn 'No sending limit per mailbox (send-limit.sh set, or upgrade.sh)'
fi

if [[ ! -f /etc/mailserver/backup.env ]]; then
  warn 'No backups are set up (backup.sh setup)'
elif [[ -f /etc/mailserver/backup-last ]] \
  && (( $(date +%s) - $(date -d "$(cat /etc/mailserver/backup-last)" +%s) <= 172800 )); then
  ok "Backup within the last 48 hours ($(cat /etc/mailserver/backup-last))"
else
  bad 'No successful backup in the last 48 hours: journalctl -u mailserver-backup'
fi

A=$(dig +short A "$MAIL_HOSTNAME" @1.1.1.1 | tail -1)
[[ "$A" == "$SERVER_IP" ]] && ok "A ${MAIL_HOSTNAME} -> ${SERVER_IP}" || bad "A ${MAIL_HOSTNAME} is '${A:-missing}', expected ${SERVER_IP}"

MX=$(dig +short MX "$MAIL_DOMAIN" @1.1.1.1 | awk '{print $2}' | sed 's/\.$//' | tr '[:upper:]' '[:lower:]')
printf '%s\n' "$MX" | grep -Fxqi "$MAIL_HOSTNAME" && ok "MX ${MAIL_DOMAIN} -> ${MAIL_HOSTNAME}" || bad "MX for ${MAIL_DOMAIN} does not contain ${MAIL_HOSTNAME}"

SPF=$(dig +short TXT "$MAIL_DOMAIN" @1.1.1.1 | tr -d '"')
printf '%s\n' "$SPF" | grep -qi '^v=spf1' && ok 'SPF record' || bad "SPF record for ${MAIL_DOMAIN} is missing"

DKIM=$(dig +short TXT "${DKIM_SELECTOR}._domainkey.${MAIL_DOMAIN}" @1.1.1.1 | tr -d '"')
printf '%s\n' "$DKIM" | grep -qi 'v=DKIM1' && ok "DKIM ${DKIM_SELECTOR}" || bad "DKIM record ${DKIM_SELECTOR}._domainkey.${MAIL_DOMAIN} is missing"

DMARC=$(dig +short TXT "_dmarc.${MAIL_DOMAIN}" @1.1.1.1 | tr -d '"')
printf '%s\n' "$DMARC" | grep -qi '^v=DMARC1' && ok 'DMARC record' || bad "DMARC record for ${MAIL_DOMAIN} is missing"

PTR=$(dig +short -x "$SERVER_IP" @1.1.1.1 | sed 's/\.$//' | tr '[:upper:]' '[:lower:]')
[[ "$PTR" == "$MAIL_HOSTNAME" ]] && ok "PTR ${SERVER_IP} -> ${MAIL_HOSTNAME}" || bad "PTR is '${PTR:-missing}', expected ${MAIL_HOSTNAME}"

if openssl s_client -connect 127.0.0.1:993 -servername "$MAIL_HOSTNAME" -verify_return_error </dev/null 2>/dev/null | grep -q 'Verify return code: 0 (ok)'; then
  ok 'IMAPS TLS certificate'
else
  bad 'IMAPS TLS certificate'
fi

if (( failures > 0 )); then
  echo -e "${RED}${failures} check(s) failed. Do not consider this server production-ready yet.${NC}"
  exit 1
fi

echo -e "${GREEN}All checks passed. DNS and local mail services are ready for production validation.${NC}"
