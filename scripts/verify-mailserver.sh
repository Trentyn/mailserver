#!/bin/bash
# Production readiness check for this mail server. Does not modify the system.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
bad()  { echo -e "${RED}[FAIL]${NC} $*"; failures=$((failures + 1)); }

[[ $EUID -eq 0 ]] || { echo 'Run as root: sudo bash verify-mailserver.sh'; exit 2; }

MAIL_HOSTNAME="${1:-$(postconf -h myhostname)}"
MAIL_DOMAIN="${2:-$(postconf -h virtual_mailbox_domains | awk -F, '{gsub(/ /, "", $1); print $1}')}"
DKIM_SELECTOR="${3:-mail$(date +%Y)}"
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
if doveconf -n | grep -Fq 'storage_size = 5G'; then
  ok 'Dovecot mailbox quota: 5 GiB'
else
  bad 'Dovecot mailbox quota is not set to 5 GiB'
fi
rspamadm configtest >/dev/null && ok 'Rspamd configuration' || bad 'Rspamd configuration'

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