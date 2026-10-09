#!/bin/bash
# Mail server status — services, domains, mailboxes, queue, fail2ban
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()    { echo -e "  ${GREEN}●${NC} $*"; }
fail()  { echo -e "  ${RED}●${NC} $*"; }
warn()  { echo -e "  ${YELLOW}●${NC} $*"; }
header(){ echo -e "\n${BOLD}${CYAN}── $* ${NC}"; }
ask()   { echo -en "${YELLOW}[?]${NC} $* "; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root"

clear 2>/dev/null || true
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗"
echo -e "║            Mail Server Status                            ║"
echo -e "╚══════════════════════════════════════════════════════════╝${NC}"

MAIL_HOSTNAME=$(postconf -h myhostname 2>/dev/null || echo "not configured")
SERVER_IP=$(curl -4 -s --max-time 3 ifconfig.me 2>/dev/null \
    || curl -4 -s --max-time 3 api.ipify.org 2>/dev/null \
    || hostname -I | awk '{print $1}')
echo
echo -e "  Server : ${BOLD}${MAIL_HOSTNAME}${NC}"
echo "  IP     : ${SERVER_IP}"
echo "  Time  : $(date '+%Y-%m-%d %H:%M:%S')"

# ── Services ───────────────────────────────────────────────────────────────────
header "Services"
for svc in postfix dovecot rspamd redis-server fail2ban; do
    if systemctl is-active --quiet "$svc"; then
        ok "$svc"
    else
        fail "$svc — STOPPED"
    fi
done

# ── TLS certificate ────────────────────────────────────────────────────────────
header "TLS certificate"
CERT_FILE="/etc/letsencrypt/live/${MAIL_HOSTNAME}/fullchain.pem"
if [[ -f "$CERT_FILE" ]]; then
    EXPIRY=$(openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null | cut -d= -f2)
    EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
    if [[ $DAYS_LEFT -gt 14 ]]; then
        ok "${MAIL_HOSTNAME} — expires in ${DAYS_LEFT} days"
    else
        warn "${MAIL_HOSTNAME} — EXPIRING SOON: ${DAYS_LEFT} days!"
    fi
else
    fail "Certificate not found: ${CERT_FILE}"
fi

# ── Domains ────────────────────────────────────────────────────────────────────
header "Domains"
DOMAINS=$(postconf -h virtual_mailbox_domains 2>/dev/null | tr ',' '\n' | xargs || true)
if [[ -z "$DOMAINS" ]]; then
    warn "No domains are configured"
else
    for d in $DOMAINS; do
        SELECTOR=$(awk -v d="$d" '$1 == d {print $2; exit}' /etc/rspamd/dkim_selectors.map 2>/dev/null || true)
        if [[ -n "$SELECTOR" && -f "/var/lib/rspamd/dkim/${d}.${SELECTOR}.key" ]]; then
            ok "${d}  (DKIM: ${SELECTOR})"
        else
            warn "${d}  (DKIM key not found!)"
        fi
    done
fi

# ── Mailboxes ─────────────────────────────────────────────────────────────────────
header "Mailboxes"
if [[ -f /etc/dovecot/users ]] && [[ -s /etc/dovecot/users ]]; then
    while IFS=: read -r email _rest; do
        [[ -z "$email" ]] && continue
        domain="${email#*@}"
        user="${email%@*}"
        maildir="/var/mail/vhosts/${domain}/${user}"
        if [[ -d "$maildir" ]]; then
            size=$(du -sh "$maildir" 2>/dev/null | cut -f1)
            ok "${email}  (${size})"
        else
            warn "${email}  (directory not found)"
        fi
    done < /etc/dovecot/users
else
    warn "No mailboxes exist"
fi

# ── Postfix queue ───────────────────────────────────────────────────────────
header "Postfix queue"
# grep -c returns exit 1 when there are no matches; suppress it with || true
QUEUE_COUNT=$(mailq 2>/dev/null | grep -c '^[A-F0-9]' || true)
QUEUE_COUNT="${QUEUE_COUNT:-0}"
if [[ "$QUEUE_COUNT" -eq 0 ]]; then
    ok "Queue is empty"
else
    warn "${QUEUE_COUNT} messages in queue"
    mailq 2>/dev/null | head -20 | sed 's/^/  /'
fi

# ── fail2ban ──────────────────────────────────────────────────────────────────
header "fail2ban"
if systemctl is-active --quiet fail2ban; then
    # Read the jail list; || true prevents an empty list from stopping the script
    JAILS=$(fail2ban-client status 2>/dev/null \
        | grep "Jail list:" \
        | sed 's/.*Jail list:\s*//' \
        | tr ',' ' ' \
        | xargs || true)

    if [[ -z "$JAILS" ]]; then
        warn "No active jails"
    else
        for jail in $JAILS; do
            BANNED=$(fail2ban-client status "$jail" 2>/dev/null \
                | grep "Currently banned:" \
                | awk '{print $NF}' || echo 0)
            if [[ "${BANNED:-0}" -gt 0 ]]; then
                warn "${jail}: banned ${BANNED} IP"
                fail2ban-client status "$jail" 2>/dev/null \
                    | grep "Banned IP list:" \
                    | sed 's/.*Banned IP list:\s*//' \
                    | tr ' ' '\n' \
                    | while read -r ip; do [[ -n "$ip" ]] && echo "    ${ip}"; done || true
            else
                ok "${jail}: no bans"
            fi
        done
    fi
else
    fail "fail2ban is not running"
fi

# ── Actions menu ─────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗"
echo -e "║                      Actions                           ║"
echo -e "╚══════════════════════════════════════════════════════════╝${NC}"
echo
echo "  1) Unban an IP in fail2ban"
echo "  2) Clear the Postfix queue (deferred)"
echo "  3) Renew TLS certificate manually"
echo "  4) Show domain DKIM key"
echo "  0) Exit"
echo
ask "Choice [0-4]:"
read -r CHOICE

case "$CHOICE" in
1)
    echo
    echo "Available jails:"
    fail2ban-client status 2>/dev/null \
        | grep "Jail list:" \
        | sed 's/.*Jail list:\s*//' \
        | tr ',' '\n' \
        | xargs -I{} echo "  • {}" || true
    echo
    ask "Jail (postfix-sasl / dovecot / sshd):"
    read -r JAIL
    ask "IP to unban:"
    read -r UNBAN_IP
    if fail2ban-client set "$JAIL" unbanip "$UNBAN_IP" 2>&1; then
        echo -e "${GREEN}[OK]${NC}    ${UNBAN_IP} unbanned in ${JAIL}"
    else
        echo -e "${RED}[ERROR]${NC} Could not unban — check the jail and IP"
    fi
    ;;
2)
    echo
    echo "Current queue:"
    mailq | head -30
    echo
    ask "Delete all deferred messages? [y/N]:"
    read -r confirm
    if [[ "${confirm,,}" == "y" ]]; then
        postsuper -d ALL deferred
        echo -e "${GREEN}[OK]${NC}    Deferred queue cleared"
    fi
    ;;
3)
    certbot renew --force-renewal
    ;;
4)
    echo
    ask "Domain:"
    read -r CHECK_DOMAIN
    CHECK_DOMAIN="${CHECK_DOMAIN,,}"
    SELECTOR=$(awk -v d="$CHECK_DOMAIN" '$1 == d {print $2; exit}' /etc/rspamd/dkim_selectors.map 2>/dev/null || true)
    PUB_FILE="/var/lib/rspamd/dkim/${CHECK_DOMAIN}.${SELECTOR}.pub"
    if [[ -n "$SELECTOR" && -f "$PUB_FILE" ]]; then
        echo
        echo "TXT record ${SELECTOR}._domainkey.${CHECK_DOMAIN}:"
        grep -oE '"[^"]*"' "$PUB_FILE" | tr -d '"\n'; echo
    else
        echo -e "${RED}[ERROR]${NC} DKIM key for ${CHECK_DOMAIN} was not found"
    fi
    ;;
0|"")
    exit 0
    ;;
*)
    exit 0
    ;;
esac
