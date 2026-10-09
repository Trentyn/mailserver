#!/bin/bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "Run: sudo bash scripts/create-setup-summary.sh"; exit 2; }
MAIL_HOSTNAME=$(postconf -h myhostname)
MAIL_DOMAIN=$(postconf -h virtual_mailbox_domains | awk -F, '{gsub(/ /, "", $1); print $1}')
SERVER_IP=$(curl -4fsS --max-time 10 https://api.ipify.org || hostname -I | awk '{print $1}')
DKIM_SELECTOR=$(awk -v d="$MAIL_DOMAIN" '$1 == d {print $2; exit}' /etc/rspamd/dkim_selectors.map 2>/dev/null || true)
read -r -p "Mailbox email for the summary: " MAILBOX
grep -Fxq "$MAILBOX" <(cut -d: -f1 /etc/dovecot/users) || { echo "Mailbox not found."; exit 1; }
read -r -s -p "Password for $MAILBOX: " PASSWORD; echo
read -r -s -p "Repeat password: " CONFIRM; echo
[[ -n "$PASSWORD" && "$PASSWORD" == "$CONFIRM" ]] || { echo "Passwords do not match."; exit 1; }
DKIM_VALUE=""
[[ -n "$DKIM_SELECTOR" && -f "/var/lib/rspamd/dkim/$MAIL_DOMAIN.$DKIM_SELECTOR.pub" ]] && DKIM_VALUE=$(grep -oE '"[^"]*"' "/var/lib/rspamd/dkim/$MAIL_DOMAIN.$DKIM_SELECTOR.pub" | tr -d '"\n')
SUMMARY="/root/mailserver-setup-$MAIL_DOMAIN-$(date +%Y%m%d-%H%M%S).txt"
umask 077
cat > "$SUMMARY" <<EOF
MAIL SERVER SETUP SUMMARY
Generated: $(date -Is)

SERVER
Hostname: $MAIL_HOSTNAME
IPv4: $SERVER_IP

MAILBOX
Email: $MAILBOX
Password: $PASSWORD

CLIENT SETTINGS
IMAPS: $MAIL_HOSTNAME:993 (SSL/TLS)
SMTP submission: $MAIL_HOSTNAME:587 (STARTTLS)
SMTP SSL: $MAIL_HOSTNAME:465 (SSL/TLS)

DNS RECORDS - add in the DNS provider
$MAIL_HOSTNAME.  A    $SERVER_IP
$MAIL_DOMAIN.     MX   10 $MAIL_HOSTNAME.
$MAIL_DOMAIN.     TXT  "v=spf1 mx ~all"
$DKIM_SELECTOR._domainkey.$MAIL_DOMAIN. TXT "$DKIM_VALUE"
_dmarc.$MAIL_DOMAIN. TXT "v=DMARC1; p=quarantine; rua=mailto:postmaster@$MAIL_DOMAIN"

PTR - configure at the VPS provider
$SERVER_IP  PTR  $MAIL_HOSTNAME.

VERIFY AFTER DNS
sudo bash scripts/verify-mailserver.sh $MAIL_HOSTNAME $MAIL_DOMAIN $DKIM_SELECTOR

SECURITY
This file contains a mailbox password. Store it in a password manager, then delete this file.
EOF
chmod 600 "$SUMMARY"
echo "Created: $SUMMARY"