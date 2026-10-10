#!/bin/bash
# Mail server installer for a clean Debian 12/13 VPS.
# Postfix + Dovecot CE 2.4 + Rspamd + Let's Encrypt.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/junk.sh
. "$SCRIPT_DIR/lib/junk.sh"
# shellcheck source=lib/tls.sh
. "$SCRIPT_DIR/lib/tls.sh"
# shellcheck source=lib/maps.sh
. "$SCRIPT_DIR/lib/maps.sh"
# shellcheck source=lib/fail2ban.sh
. "$SCRIPT_DIR/lib/fail2ban.sh"
# shellcheck source=lib/ratelimit.sh
. "$SCRIPT_DIR/lib/ratelimit.sh"
# shellcheck source=lib/updates.sh
. "$SCRIPT_DIR/lib/updates.sh"
# shellcheck source=lib/password.sh
. "$SCRIPT_DIR/lib/password.sh"
require_root

STATE_DIR=/etc/mailserver
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# ── Preflight checks ──────────────────────────────────────────────────────────
# The installer targets a clean server only. An interrupted run (for example,
# certbot could not issue the certificate yet) can be repeated safely: the
# setup-started marker tells our unfinished install apart from foreign config.
[[ -e "$STATE_DIR/setup-complete" ]] \
    && die "The mail server is already installed. Use the maintenance scripts in scripts/."
if [[ -e "$STATE_DIR/setup-started" ]]; then
    RESUMING=true
elif [[ -e /etc/postfix/main.cf || -e /etc/dovecot/local.conf ]]; then
    die "This server already has a mail configuration. Run setup.sh only on a clean Debian server; use the maintenance scripts in scripts/."
else
    RESUMING=false
fi

# shellcheck source=/dev/null
. /etc/os-release
[[ "${ID:-}" == debian && "${VERSION_CODENAME:-}" =~ ^(bookworm|trixie)$ ]] \
    || die "Only Debian 12 (bookworm) and Debian 13 (trixie) are supported; found: ${PRETTY_NAME:-unknown}"
CODENAME="$VERSION_CODENAME"

if [[ ! -e "$STATE_DIR/ufw-configured" ]] && command -v ufw >/dev/null \
    && ufw status | grep -q '^Status: active'; then
    die "UFW is already active. To avoid changing existing rules, disable it or configure the firewall manually."
fi

if ss -Hltn 'sport = :80' | grep -q .; then
    die "Port 80 is in use by $(ss -Hltnp 'sport = :80' | grep -o 'users:(("[^"]*' | cut -d'"' -f2 | sort -u | paste -sd,). Certbot needs it to issue the certificate."
fi

$RESUMING && warn "Found an unfinished installation. Starting over; completed steps will be rewritten."

# ── Bootstrap ─────────────────────────────────────────────────────────────────
# curl, dig and gpg can be missing on a minimal Debian image.
step "Preparing"
apt-get update -q
apt-get install "${APT_OPTS[@]}" curl dnsutils gnupg2 ssl-cert
ok "Base tools installed"

DOMAIN_RE='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'

# read_val PROMPT DEFAULT [REGEX ERROR]: ask again until the answer is valid,
# so a typo does not abort the installation.
read_val() {
    local prompt="$1" default="${2:-}" regex="${3:-}" error="${4:-}" val
    while true; do
        if [[ -n "$default" ]]; then ask "${prompt} [${default}]:" >&2; else ask "${prompt}:" >&2; fi
        read -r val
        val="${val:-$default}"
        val="${val//[[:space:]]/}"
        if [[ -z "$val" ]]; then
            warn "A value is required" >&2
        elif [[ -n "$regex" && ! "${val,,}" =~ $regex ]]; then
            warn "$error" >&2
        else
            echo "$val"
            return
        fi
    done
}

# ═════════════════════════════════════════════════════════════════════════════
step "Settings"
# ═════════════════════════════════════════════════════════════════════════════

echo
echo "You will need:"
echo "  • the mail server FQDN, for example mx.example.com"
echo "  • the mailbox domain, for example example.com"
echo "  • an email address for Let's Encrypt notices"
echo "  • a DNS A record for the FQDN that already points to this server"
echo

SERVER_IP=$(public_ipv4)
info "Public IPv4: ${BOLD}${SERVER_IP}${NC}"

MAIL_HOSTNAME=$(read_val "Mail server FQDN (mx.your-domain.com)" "" \
    '^[a-z0-9-]+\.([a-z0-9-]+\.)*[a-z]{2,63}$' "Enter a fully qualified host name, for example mx.example.com")
MAIL_HOSTNAME="${MAIL_HOSTNAME,,}"

BASE_DOMAIN="${MAIL_HOSTNAME#*.}"
info "Base domain: ${BOLD}${BASE_DOMAIN}${NC}"

MAIL_DOMAIN=$(read_val "Mailbox domain (user@???)" "$BASE_DOMAIN" \
    "$DOMAIN_RE" "Invalid domain, for example: example.com")
MAIL_DOMAIN="${MAIL_DOMAIN,,}"
DKIM_SELECTOR=$(read_val "DKIM selector" "mail$(date +%Y)" \
    '^[a-z0-9][a-z0-9-]*$' "Use only letters, digits and hyphens")
DKIM_SELECTOR="${DKIM_SELECTOR,,}"
LETSENCRYPT_EMAIL=$(read_val "Email for Let's Encrypt notices" "" \
    '^[^@]+@[^@]+\.[^@]+$' "Invalid email address")

# Offer the port sshd actually listens on. sudo drops SSH_CONNECTION, so the
# session variable is only a fallback; on a bare console, offer the default 22.
DETECTED_SSH_PORT=$(/usr/sbin/sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}' || true)
[[ -n "$DETECTED_SSH_PORT" ]] || DETECTED_SSH_PORT=$(awk '{print $4}' <<< "${SSH_CONNECTION:-}" 2>/dev/null || true)
while true; do
    SSH_PORT=$(read_val "SSH port to allow in UFW (double-check it)" "${DETECTED_SSH_PORT:-22}" \
        '^[0-9]{1,5}$' "The port must be a number")
    (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) && break
    warn "The port must be between 1 and 65535"
done

echo
echo -e "${BOLD}First mailbox:${NC}"
FIRST_USER=$(read_val "User name (before @)" "info" \
    '^[a-z0-9._+-]+$' "Use only letters, digits and . _ + -")
FIRST_USER="${FIRST_USER,,}"
FIRST_EMAIL="${FIRST_USER}@${MAIL_DOMAIN}"
info "Mailbox to create: ${BOLD}${FIRST_EMAIL}${NC}"
info "postmaster@${MAIL_DOMAIN} and abuse@${MAIL_DOMAIN} will deliver to it"
read_new_password "Password for ${FIRST_EMAIL}"
FIRST_PASS="$NEW_PASSWORD"
FIRST_PASS_GENERATED="$PASSWORD_GENERATED"

MAILBOX_QUOTA=$(read_val "Storage quota per mailbox (for example 5G)" "5G" \
    '^[1-9][0-9]*[kmgt]$' "Enter a positive size such as 5G, 10G or 500M")
MAILBOX_QUOTA="${MAILBOX_QUOTA^^}"

MAIL_RETENTION_DAYS=$(read_val "Days to keep Trash and Junk mail (0 disables cleanup)" "30" \
    '^[0-9]+$' "Enter 0 or a positive number of days")
MAIL_RETENTION_DAYS=$((10#$MAIL_RETENTION_DAYS))

echo
echo -e "${BOLD}Summary:${NC}"
echo "  MAIL_HOSTNAME : $MAIL_HOSTNAME"
echo "  BASE_DOMAIN   : $BASE_DOMAIN"
echo "  MAIL_DOMAIN   : $MAIL_DOMAIN"
echo "  DKIM_SELECTOR : $DKIM_SELECTOR"
echo "  SERVER_IP     : $SERVER_IP"
echo "  FIRST_EMAIL   : $FIRST_EMAIL"
echo "  MAILBOX_QUOTA : $MAILBOX_QUOTA"
echo "  MAIL_RETENTION_DAYS : $MAIL_RETENTION_DAYS"
echo
ask "Start the installation? [y/N]:"
read -r confirm
[[ "${confirm,,}" == "y" ]] || { info "Cancelled."; exit 0; }

install -d -m 0755 "$STATE_DIR"
touch "$STATE_DIR/setup-started"

# ═════════════════════════════════════════════════════════════════════════════
step "DNS check"
# ═════════════════════════════════════════════════════════════════════════════

# Certbot cannot issue a certificate without the A record, so wait for DNS
# instead of aborting the installation.
while true; do
    info "Looking up the A record for ${MAIL_HOSTNAME}..."
    RESOLVED=$(dig +short A "$MAIL_HOSTNAME" @8.8.8.8 2>/dev/null | tail -1 || true)
    [[ -n "$RESOLVED" ]] || RESOLVED=$(dig +short A "$MAIL_HOSTNAME" 2>/dev/null | tail -1 || true)
    if [[ "$RESOLVED" == "$SERVER_IP" ]]; then
        ok "DNS ${MAIL_HOSTNAME} → ${SERVER_IP} ✓"
        break
    fi
    warn "${MAIL_HOSTNAME} resolves to '${RESOLVED:-nothing}', expected '${SERVER_IP}'"
    echo
    echo "Add this A record at your DNS provider:"
    echo "  ${MAIL_HOSTNAME}    A    ${SERVER_IP}"
    echo
    ask "Press Enter to check again, type skip to continue anyway, or q to quit:"
    read -r dns_choice
    case "${dns_choice,,}" in
        skip) warn "DNS is not confirmed; certbot may fail to issue the certificate"; break ;;
        q) die "Configure DNS and run setup.sh again." ;;
    esac
done

# Without outbound port 25 the server can receive mail but cannot deliver it.
if timeout 7 bash -c 'exec 3<>/dev/tcp/gmail-smtp-in.l.google.com/25' 2>/dev/null; then
    ok "Outbound port 25 is open"
else
    warn "Outbound port 25 is blocked. Mail to external addresses will not leave the"
    warn "server until the provider unblocks port 25 (usually through a support ticket)."
fi

# ═════════════════════════════════════════════════════════════════════════════
step "Package repositories"
# ═════════════════════════════════════════════════════════════════════════════

# Rspamd: the official stable repository. The Debian package lags behind and
# is not supported by the upstream project.
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://rspamd.com/apt-stable/gpg.key \
    | gpg --dearmor --yes -o /etc/apt/keyrings/rspamd.gpg
echo "deb [signed-by=/etc/apt/keyrings/rspamd.gpg] https://rspamd.com/apt-stable/ ${CODENAME} main" \
    > /etc/apt/sources.list.d/rspamd.list
info "Added the official Rspamd repository"

# Dovecot CE 2.4: the official upstream repository with the current 2.4 release.
curl -fsSL https://repo.dovecot.org/DOVECOT-REPO-GPG-2.4 \
    | gpg --dearmor --yes -o /etc/apt/keyrings/dovecot.gpg
cat > /etc/apt/sources.list.d/dovecot.sources << EOF
Types: deb
URIs: https://repo.dovecot.org/ce-2.4-latest/debian/${CODENAME}
Suites: ${CODENAME}
Components: main
Signed-By: /etc/apt/keyrings/dovecot.gpg
EOF
info "Added the official Dovecot CE 2.4 repository"

# ═════════════════════════════════════════════════════════════════════════════
step "Packages"
# ═════════════════════════════════════════════════════════════════════════════

# Preseed debconf so the Postfix package does not ask questions.
echo "postfix postfix/main_mailer_type select Internet Site" | debconf-set-selections
echo "postfix postfix/mailname string ${MAIL_HOSTNAME}" | debconf-set-selections

# Bring the base system up to date with Debian security and stable updates.
apt-get update -q
apt-get upgrade "${APT_OPTS[@]}"
apt-get install "${APT_OPTS[@]}" \
    postfix postfix-pcre \
    dovecot-core dovecot-imapd dovecot-pop3d dovecot-lmtpd dovecot-sieve \
    rspamd \
    redis-server \
    certbot \
    fail2ban \
    rsyslog \
    dnsutils curl wget gnupg2 swaks openssl ufw git

ok "Packages installed"
info "Versions:"
echo "  postfix:  $(postconf -h mail_version 2>/dev/null || echo 'n/a')"
echo "  dovecot:  $(dovecot --version 2>/dev/null | head -1 || echo 'n/a')"
echo "  rspamd:   $(rspamd --version 2>/dev/null | head -1 || echo 'n/a')"
echo "  certbot:  $(certbot --version 2>/dev/null || echo 'n/a')"

install_auto_updates
ok "Debian security updates install automatically every day"

# ═════════════════════════════════════════════════════════════════════════════
step "System"
# ═════════════════════════════════════════════════════════════════════════════

hostnamectl set-hostname "$MAIL_HOSTNAME"

if [[ -f /etc/cloud/templates/hosts.debian.tmpl ]]; then
    info "cloud-init detected; it maintains /etc/hosts"
else
    if ! grep -q "$MAIL_HOSTNAME" /etc/hosts; then
        echo "127.0.1.1   $MAIL_HOSTNAME ${MAIL_HOSTNAME%%.*}" >> /etc/hosts
    fi
fi
ok "Hostname: $(hostname)"

# Shell environment: one shared file, sourced by a single line in ~/.bashrc of
# root and of the user who ran the installer. The stock Debian .bashrc is kept;
# delete the line marked "# mailserver" to opt out.
cat > "$STATE_DIR/bashrc" << 'BASHRC'
# Managed by mailserver setup.sh. Sourced from ~/.bashrc.
[[ $- == *i* ]] || return

HISTCONTROL=ignoreboth:erasedups
HISTSIZE=10000
HISTFILESIZE=20000
shopt -s histappend checkwinsize

if [[ -d "$HOME/.local/bin" && ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    PATH="$HOME/.local/bin:$PATH"
fi

# Git branch in the prompt: the stock git helper, or a minimal fallback.
if [[ -r /usr/lib/git-core/git-sh-prompt ]]; then
    . /usr/lib/git-core/git-sh-prompt
else
    __git_ps1() { local b; b=$(git symbolic-ref --short HEAD 2>/dev/null) && printf -- "${1:- (%s)}" "$b"; }
fi
# Red user@host for root, green otherwise, so a root shell is obvious.
if (( EUID == 0 )); then _mc='1;31'; else _mc='1;32'; fi
PS1='\[\e['"$_mc"'m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\[\e[1;33m\]$(__git_ps1 " (%s)")\[\e[0m\]\$ '
unset _mc

# Mail server shortcuts; non-root users get them through sudo.
if (( EUID == 0 )); then _ms=''; else _ms='sudo '; fi
alias mq='mailq'
alias mql='mailq | grep -c "^[A-F0-9]"'
alias postlog="${_ms}journalctl -u postfix -f"
alias dovelog="${_ms}tail -f /var/log/dovecot.log"
alias rsplog="${_ms}tail -f /var/log/rspamd/rspamd.log"
alias mailstatus="${_ms}systemctl status postfix dovecot rspamd redis-server fail2ban"
alias mailreload="${_ms}systemctl reload postfix dovecot rspamd"
alias f2b="${_ms}fail2ban-client status"
unset _ms
BASHRC
chmod 644 "$STATE_DIR/bashrc"

BASHRC_LINE="[ -r $STATE_DIR/bashrc ] && . $STATE_DIR/bashrc  # mailserver"
TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == root ]]; then
    TARGET_USER=$(getent passwd 1000 | cut -d: -f1 || true)
fi
for shell_user in root ${TARGET_USER:+"$TARGET_USER"}; do
    shell_home=$(getent passwd "$shell_user" | cut -d: -f6)
    [[ -n "$shell_home" && -d "$shell_home" ]] || continue
    if [[ ! -f "$shell_home/.bashrc" ]]; then
        cp /etc/skel/.bashrc "$shell_home/.bashrc" 2>/dev/null || touch "$shell_home/.bashrc"
        chown "$shell_user:" "$shell_home/.bashrc"
    fi
    grep -Fqx "$BASHRC_LINE" "$shell_home/.bashrc" \
        || printf '\n%s\n' "$BASHRC_LINE" >> "$shell_home/.bashrc"
    ok "Shell environment enabled for ${shell_user}"
done

# ═════════════════════════════════════════════════════════════════════════════
step "TLS certificate"
# ═════════════════════════════════════════════════════════════════════════════

info "Requesting a certificate for ${MAIL_HOSTNAME}..."
# The certificate is issued before the Postfix and Dovecot configs that point
# to it are written, so a certbot failure leaves a state setup.sh can resume.
if [[ -f "/etc/letsencrypt/live/${MAIL_HOSTNAME}/fullchain.pem" ]]; then
    info "The certificate already exists; skipping issuance"
elif ! CERTBOT_OUT=$(certbot certonly --standalone \
        -d "$MAIL_HOSTNAME" \
        --email "$LETSENCRYPT_EMAIL" \
        --agree-tos \
        --non-interactive 2>&1); then
    echo "$CERTBOT_OUT" | sed 's/^/  /'
    die "No certificate was issued. Check that ${MAIL_HOSTNAME} resolves to ${SERVER_IP} and port 80 is reachable, then run setup.sh again."
fi

chown root:dovecot "/etc/letsencrypt/live/${MAIL_HOSTNAME}/privkey.pem"
chmod 640 "/etc/letsencrypt/live/${MAIL_HOSTNAME}/privkey.pem"
ok "TLS certificate is in place"

# Renewal opens port 80 only while certbot runs, then reloads the mail services.
install_certbot_hooks
ok "Renewal hooks installed; port 80 opens only during renewal"

# ═════════════════════════════════════════════════════════════════════════════
step "vmail user"
# ═════════════════════════════════════════════════════════════════════════════

getent group vmail &>/dev/null  || groupadd -g 5000 vmail
getent passwd vmail &>/dev/null || useradd -u 5000 -g vmail -d /var/mail/vhosts -s /sbin/nologin vmail
mkdir -p /var/mail/vhosts
chown vmail:vmail /var/mail/vhosts
ok "vmail user ready"

# ═════════════════════════════════════════════════════════════════════════════
step "Postfix"
# ═════════════════════════════════════════════════════════════════════════════

cat > /etc/postfix/main.cf << EOF
myhostname = ${MAIL_HOSTNAME}
# Use a neutral MTA name in SMTP and Received headers.
mail_name = Mail Server
smtpd_banner = \$myhostname ESMTP
mydomain = ${BASE_DOMAIN}
myorigin = ${MAIL_HOSTNAME}

inet_interfaces = all
inet_protocols = ipv4
mynetworks = 127.0.0.0/8

# Local delivery is disabled: virtual mailboxes only
mydestination =
local_recipient_maps =
local_transport = error:local mail delivery is disabled

# Virtual domains
virtual_mailbox_domains = ${MAIL_DOMAIN}
virtual_mailbox_base = /var/mail/vhosts
virtual_mailbox_maps = hash:/etc/postfix/vmailbox
virtual_alias_maps = hash:/etc/postfix/virtual, hash:/etc/postfix/virtual_mailboxes
smtpd_sender_login_maps = hash:/etc/postfix/sender_login_maps
virtual_minimum_uid = 100
virtual_uid_maps = static:5000
virtual_gid_maps = static:5000
virtual_transport = lmtp:unix:private/dovecot-lmtp

# SASL through Dovecot
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_auth_enable = yes
smtpd_sasl_security_options = noanonymous
smtpd_sasl_local_domain = \$myhostname

# Milter (rspamd)
milter_default_action = accept
milter_protocol = 6
smtpd_milters = inet:127.0.0.1:11332
non_smtpd_milters = inet:127.0.0.1:11332

# Rate limiting
smtpd_client_connection_count_limit = 100
smtpd_client_connection_rate_limit = 50

# Header filtering
header_checks = pcre:/etc/postfix/header_checks_pcre

# Inbound TLS
smtpd_tls_cert_file = /etc/letsencrypt/live/${MAIL_HOSTNAME}/fullchain.pem
smtpd_tls_key_file = /etc/letsencrypt/live/${MAIL_HOSTNAME}/privkey.pem
smtpd_tls_security_level = may
smtpd_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtpd_tls_mandatory_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtpd_tls_loglevel = 1
smtpd_tls_received_header = yes

# Outbound TLS
smtp_tls_security_level = may
smtp_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtp_tls_loglevel = 1

smtpd_relay_restrictions =
  permit_mynetworks,
  permit_sasl_authenticated,
  reject_unauth_destination

smtpd_recipient_restrictions =
  permit_mynetworks,
  permit_sasl_authenticated,
  reject_unauth_destination

message_size_limit = 52428800
mailbox_size_limit = 0

biff = no
append_dot_mydomain = no
readme_directory = no
compatibility_level = 3.6
recipient_delimiter = +
alias_maps = hash:/etc/aliases
alias_database = hash:/etc/aliases
EOF

cat > /etc/postfix/header_checks_pcre << 'EOF'
/^X-Mailer:/            IGNORE
/^X-Originating-IP:/    IGNORE
EOF

# First mailbox
printf '%s\t%s/%s/\n' "$FIRST_EMAIL" "$MAIL_DOMAIN" "$FIRST_USER" > /etc/postfix/vmailbox
postmap /etc/postfix/vmailbox
# RFC 5321 requires a working postmaster@; it also receives DMARC reports.
{
    printf 'postmaster@%s\t%s\n' "$MAIL_DOMAIN" "$FIRST_EMAIL"
    printf 'abuse@%s\t%s\n' "$MAIL_DOMAIN" "$FIRST_EMAIL"
} > /etc/postfix/virtual
# Who may send as which address; regenerated again once the first mailbox exists.
: > "$SEND_AS_FILE"
sync_postfix_maps

# submission (587) and smtps (465) in master.cf. Comment out the stock entries
# to avoid duplicates, but only on the first pass: a resumed run would
# otherwise comment out our own block.
if ! grep -q '# mailserver-setup: ports' /etc/postfix/master.cf; then
sed -i 's/^submission /#submission /' /etc/postfix/master.cf
sed -i 's/^smtps /#smtps /'         /etc/postfix/master.cf
cat >> /etc/postfix/master.cf << 'EOF'

# mailserver-setup: ports
submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_hide_client_session=yes
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_tls_auth_only=yes
  -o smtpd_reject_unlisted_recipient=no
  -o smtpd_sender_restrictions=reject_authenticated_sender_login_mismatch,permit_sasl_authenticated,reject
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING

smtps     inet  n       -       y       -       -       smtpd
  -o syslog_name=postfix/smtps
  -o smtpd_tls_wrappermode=yes
  -o smtpd_hide_client_session=yes
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_reject_unlisted_recipient=no
  -o smtpd_sender_restrictions=reject_authenticated_sender_login_mismatch,permit_sasl_authenticated,reject
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
EOF
fi

ok "Postfix configured"

# ═════════════════════════════════════════════════════════════════════════════
step "Dovecot"
# ═════════════════════════════════════════════════════════════════════════════

cat > /etc/dovecot/local.conf << EOF
# ${MAIL_HOSTNAME}
protocols = imap pop3 lmtp

# Storage (Dovecot 2.4)
mail_driver = maildir
mail_home = /var/mail/vhosts/%{user|domain}/%{user|username}
mail_path = /var/mail/vhosts/%{user|domain}/%{user|username}
# Debian defaults to /var/mail/%{user}; virtual Maildir must use mail_path for INBOX.
mail_inbox_path =

namespace inbox {
  inbox = yes
  separator = /

  mailbox Sent {
    auto = subscribe
    special_use = \Sent
  }
  mailbox Drafts {
    auto = subscribe
    special_use = \Drafts
  }
  mailbox Trash {
    auto = subscribe
    special_use = \Trash
  }
  mailbox Junk {
    auto = subscribe
    special_use = \Junk
  }
  mailbox Archive {
    auto = subscribe
    special_use = \Archive
  }
}
# Per-mailbox storage limit. Dovecot count is the recommended 2.4 quota driver.
mail_plugins {
  quota = yes
}
quota "User quota" {
  driver = count
  storage_size = $MAILBOX_QUOTA
}

log_path = /var/log/dovecot.log

# TLS (Dovecot 2.4)
ssl = required
ssl_server_cert_file = /etc/letsencrypt/live/${MAIL_HOSTNAME}/fullchain.pem
ssl_server_key_file  = /etc/letsencrypt/live/${MAIL_HOSTNAME}/privkey.pem
ssl_min_protocol = TLSv1.2

auth_mechanisms = plain login
auth_allow_cleartext = no

passdb passwd-file {
  default_password_scheme = SHA512-CRYPT
  passwd_file_path = /etc/dovecot/users
}

userdb static {
  fields {
    uid = 5000
    gid = 5000
    home = /var/mail/vhosts/%{user|domain}/%{user|username}
  }
}

protocol imap {
  mail_max_userip_connections = 10
}
protocol pop3 {
  mail_max_userip_connections = 10
}
protocol lmtp {
  postmaster_address = postmaster@${MAIL_DOMAIN}
  mail_plugins {
    sieve = yes
  }
}

protocol imap {
  mail_plugins {
    imap_sieve = yes
  }
}

# Global rules: Rspamd marks inbound spam and Sieve files it into Junk.
sieve_plugins {
  sieve_extprograms = yes
  sieve_imapsieve = yes
}
sieve_global_extensions {
  vnd.dovecot.pipe = yes
}
sieve_pipe_bin_dir = /usr/lib/dovecot/sieve
sieve_script spam_to_junk {
  type = before
  path = /etc/dovecot/sieve/spam-to-junk.sieve
}

# IMAPSieve teaches Rspamd when a user moves mail into or out of Junk.
mailbox Junk {
  sieve_script learn_spam {
    type = before
    cause = copy
    path = /etc/dovecot/sieve/learn-spam.sieve
  }
}
imapsieve_from Junk {
  sieve_script learn_ham {
    type = before
    cause = copy
    path = /etc/dovecot/sieve/learn-ham.sieve
  }
}


service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
  unix_listener auth-userdb {
    mode = 0600
    user = vmail
    group = vmail
  }
}

service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}
EOF

# The upstream package may not include local.conf by default.
if ! grep -Fxq "!include_try local.conf" /etc/dovecot/dovecot.conf; then
    printf "\\n!include_try local.conf\\n" >> /etc/dovecot/dovecot.conf
fi

touch /etc/dovecot/users
chown root:dovecot /etc/dovecot/users
chmod 640 /etc/dovecot/users

# Disable system (PAM) authentication: mailboxes come from the passwd-file.
# Dovecot 2.4 defines these blocks inline; older configs use an include.
if [[ -f /etc/dovecot/conf.d/10-auth.conf ]]; then
    sed -Ei '/^[[:space:]]*passdb[[:space:]]+pam[[:space:]]*\{/,/^[[:space:]]*\}[[:space:]]*$/ s/^/#/' \
        /etc/dovecot/conf.d/10-auth.conf
    sed -Ei '/^[[:space:]]*userdb[[:space:]]+passwd[[:space:]]*\{/,/^[[:space:]]*\}[[:space:]]*$/ s/^/#/' \
        /etc/dovecot/conf.d/10-auth.conf
    sed -Ei '/^[[:space:]]*!include[[:space:]]+auth-system\.conf\.ext/s/^/#/' \
        /etc/dovecot/conf.d/10-auth.conf

    if doveconf -n | grep -Eq '^[[:space:]]*(passdb pam|userdb passwd)'; then
        die "Could not disable Dovecot PAM authentication"
    fi
    if doveconf -n | grep -Eq '^mail_inbox_path = /var/mail/'; then
        die "Dovecot uses the system INBOX path instead of the virtual Maildir"
    fi
fi

ok "Dovecot configured"

# ═════════════════════════════════════════════════════════════════════════════
step "Rspamd"
# ═════════════════════════════════════════════════════════════════════════════

mkdir -p /etc/rspamd/local.d

# Redis-backed Bayes and the spam marker that files mail into Junk.
write_rspamd_junk_config
# Recipients per hour and per day for each mailbox (send-limit.sh).
write_rspamd_ratelimit_config
write_submission_recipient_limit

cat > /etc/rspamd/local.d/worker-proxy.inc << 'EOF'
milter = yes;
timeout = 120s;
upstream "local" { default = yes; self_scan = yes; }
bind_socket = "127.0.0.1:11332";
EOF

cat > /etc/rspamd/local.d/worker-controller.inc << 'EOF'
bind_socket = "127.0.0.1:11334";
EOF

cat > /etc/rspamd/local.d/dkim_signing.conf << 'EOF'
enabled = true;
sign_authenticated = true;
sign_local = true;
use_domain = "header";
path = "/var/lib/rspamd/dkim/$domain.$selector.key";
selector_map = "/etc/rspamd/dkim_selectors.map";
EOF

cat > /etc/rspamd/local.d/greylisting.conf << 'EOF'
enabled = false;
EOF

mkdir -p /var/lib/rspamd/dkim
# A resumed run keeps the existing key.
if [[ ! -s "/var/lib/rspamd/dkim/${MAIL_DOMAIN}.${DKIM_SELECTOR}.pub" ]]; then
    rspamadm dkim_keygen \
        -b 2048 \
        -s "$DKIM_SELECTOR" \
        -d "$MAIL_DOMAIN" \
        -k "/var/lib/rspamd/dkim/${MAIL_DOMAIN}.${DKIM_SELECTOR}.key" \
        > "/var/lib/rspamd/dkim/${MAIL_DOMAIN}.${DKIM_SELECTOR}.pub"
fi

chown -R _rspamd:_rspamd /var/lib/rspamd/dkim
chmod 700 /var/lib/rspamd/dkim
chmod 440 "/var/lib/rspamd/dkim/${MAIL_DOMAIN}.${DKIM_SELECTOR}.key"

echo "${MAIL_DOMAIN}    ${DKIM_SELECTOR}" > /etc/rspamd/dkim_selectors.map

rspamadm configtest && ok "Rspamd configured"

install_junk_sieve_rules
ok "Junk delivery and spam training rules installed"

# Final Postfix configuration check
if postfix check 2>&1; then
    ok "Postfix configuration is valid"
else
    warn "postfix check reported warnings; see the output above"
fi

# ═════════════════════════════════════════════════════════════════════════════
step "fail2ban"
# ═════════════════════════════════════════════════════════════════════════════

write_fail2ban_config
install_dovecot_logrotate
ok "fail2ban configured"

# ═════════════════════════════════════════════════════════════════════════════
step "First mailbox"
# ═════════════════════════════════════════════════════════════════════════════

HASH=$(hash_password "$FIRST_PASS")
echo "${FIRST_EMAIL}:${HASH}" > /etc/dovecot/users
sync_postfix_maps

mkdir -p "/var/mail/vhosts/${MAIL_DOMAIN}/${FIRST_USER}"/{cur,new,tmp}
chown -R vmail:vmail "/var/mail/vhosts/${MAIL_DOMAIN}"
chmod -R 700 "/var/mail/vhosts/${MAIL_DOMAIN}"
ok "Mailbox ${FIRST_EMAIL} created"

# ═════════════════════════════════════════════════════════════════════════════
step "Services"
# ═════════════════════════════════════════════════════════════════════════════

systemctl enable --now redis-server
systemctl enable --now rspamd
systemctl enable --now postfix
systemctl enable --now dovecot
systemctl enable --now fail2ban

# The packages started with default settings before main.cf, local.conf and
# jail.local were written; restart to apply them. fail2ban goes last, once the
# service logs exist.
systemctl restart rsyslog postfix dovecot rspamd
systemctl restart fail2ban

sleep 3

for svc in postfix dovecot rspamd redis-server fail2ban; do
    if systemctl is-active --quiet "$svc"; then
        ok "$svc"
    else
        warn "$svc is NOT running; check: journalctl -u $svc -n 30"
    fi
done

# ═════════════════════════════════════════════════════════════════════════════
step "Authentication check"
# ═════════════════════════════════════════════════════════════════════════════

sleep 1
if auth_ok "$FIRST_EMAIL" "$FIRST_PASS"; then
    ok "Authentication for ${FIRST_EMAIL} ✓"
else
    warn "Authentication failed. Check: doveadm auth test '${FIRST_EMAIL}'"
fi

# ═════════════════════════════════════════════════════════════════════════════
step "Firewall (UFW) with SSH lockout protection"
# ═════════════════════════════════════════════════════════════════════════════

if [[ -e "$STATE_DIR/ufw-configured" ]]; then
    info "UFW was configured by a previous run; skipping"
else
    # An emergency rollback disables UFW after 3 minutes unless SSH is confirmed.
    UFW_ROLLBACK_UNIT="mailserver-ufw-rollback"
    cat > "/run/systemd/system/${UFW_ROLLBACK_UNIT}.service" <<'EOF'
[Unit]
Description=Emergency rollback for mailserver UFW setup

[Service]
Type=oneshot
ExecStart=/usr/sbin/ufw disable
EOF
    cat > "/run/systemd/system/${UFW_ROLLBACK_UNIT}.timer" <<'EOF'
[Unit]
Description=Schedule emergency rollback for mailserver UFW setup

[Timer]
OnActiveSec=3m
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl start "${UFW_ROLLBACK_UNIT}.timer"
    systemctl is-active --quiet "${UFW_ROLLBACK_UNIT}.timer" \
        || die "Could not schedule the UFW rollback"
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "${SSH_PORT}/tcp" comment 'SSH verified port'
    ufw allow 25/tcp comment 'SMTP'
    ufw allow 110/tcp comment 'POP3'
    ufw allow 143/tcp comment 'IMAP STARTTLS'
    ufw allow 465/tcp comment 'SMTPS'
    ufw allow 587/tcp comment 'Submission STARTTLS'
    ufw allow 993/tcp comment 'IMAPS'
    ufw allow 995/tcp comment 'POP3S'
    ufw --force enable

    cat << EOF

UFW enabled. The automatic rollback will disable it in 3 minutes.
Open a NEW terminal now and verify SSH before continuing:
  ssh -p ${SSH_PORT} <user>@${SERVER_IP}

Only after that new login succeeds, type: SSH-OK
EOF
    # A typo must not abort setup: keep asking until the rollback disables UFW.
    # A fired timer stays "active (elapsed)", so check UFW itself.
    UFW_CONFIRM=""
    while ufw status | grep -q '^Status: active'; do
        ask "Confirmation:"
        # Time out to notice a fired rollback even when nobody answers.
        read -r -t 200 UFW_CONFIRM || true
        [[ "$UFW_CONFIRM" == 'SSH-OK' ]] && break
        warn "Type exactly SSH-OK after the new SSH login works."
    done
    systemctl stop "${UFW_ROLLBACK_UNIT}.timer"
    if [[ "$UFW_CONFIRM" == 'SSH-OK' ]] && ufw status | grep -q '^Status: active'; then
        touch "$STATE_DIR/ufw-configured"
        ok "UFW enabled; SSH port ${SSH_PORT} was verified by the owner"
    else
        warn "The rollback timer expired and UFW was disabled. Setup continues without a firewall;"
        warn "re-enable it after checking SSH access: sudo ufw enable"
    fi
    rm -f "/run/systemd/system/${UFW_ROLLBACK_UNIT}.service" "/run/systemd/system/${UFW_ROLLBACK_UNIT}.timer"
    systemctl daemon-reload
fi

if (( MAIL_RETENTION_DAYS > 0 )); then
    step "Trash and Junk cleanup"
    bash "$SCRIPT_DIR/install-mail-cleanup-timer.sh" "$MAIL_RETENTION_DAYS"
    ok "Trash and Junk messages are removed after $MAIL_RETENTION_DAYS days"
else
    info "Trash and Junk cleanup is disabled"
fi

# ═════════════════════════════════════════════════════════════════════════════
step "DNS records to add at your DNS provider"
# ═════════════════════════════════════════════════════════════════════════════

echo
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║         DNS RECORDS FOR: ${MAIL_DOMAIN}${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo
echo -e "${CYAN}── A ────────────────────────────────────────────────────────${NC}"
printf "  %-40s  A      %s\n" "${MAIL_HOSTNAME}" "${SERVER_IP}"
echo
echo -e "${CYAN}── MX ───────────────────────────────────────────────────────${NC}"
printf "  %-40s  MX     %s\n" "${MAIL_DOMAIN}." "10 ${MAIL_HOSTNAME}."
echo
echo -e "${CYAN}── SPF ──────────────────────────────────────────────────────${NC}"
printf "  %-40s  TXT    %s\n" "${MAIL_DOMAIN}." '"v=spf1 mx ~all"'
echo
echo -e "${CYAN}── DKIM ─────────────────────────────────────────────────────${NC}"
printf "  Name:   %s\n"   "${DKIM_SELECTOR}._domainkey.${MAIL_DOMAIN}."
printf "  Type:   TXT\n"
echo   "  Value:"
grep -oE '"[^"]*"' "/var/lib/rspamd/dkim/${MAIL_DOMAIN}.${DKIM_SELECTOR}.pub" | tr -d '"\n'; echo
echo
echo -e "${CYAN}── DMARC ────────────────────────────────────────────────────${NC}"
printf "  %-40s  TXT    %s\n" "_dmarc.${MAIL_DOMAIN}." \
    "\"v=DMARC1; p=quarantine; rua=mailto:postmaster@${MAIL_DOMAIN}\""
echo
echo -e "${CYAN}── PTR (set at the VPS provider, not in the domain DNS) ─────${NC}"
printf "  %-40s  PTR    %s\n" "${SERVER_IP}" "${MAIL_HOSTNAME}."
echo
echo -e "${YELLOW}After DNS propagates, run: sudo bash ${SCRIPT_DIR}/verify-mailserver.sh${NC}"

# ═════════════════════════════════════════════════════════════════════════════
# Only root can read the summary. It holds no password.
SETUP_SUMMARY="/root/mailserver-setup-${MAIL_DOMAIN}-$(date +%Y%m%d-%H%M%S).txt"
DKIM_DNS_VALUE=$(grep -oE '"[^"]*"' "/var/lib/rspamd/dkim/${MAIL_DOMAIN}.${DKIM_SELECTOR}.pub" | tr -d '"\n')
umask 077
cat > "$SETUP_SUMMARY" << EOF
MAIL SERVER SETUP SUMMARY
Generated: $(date -Is)

SERVER
Hostname: ${MAIL_HOSTNAME}
IPv4: ${SERVER_IP}
Let's Encrypt contact: ${LETSENCRYPT_EMAIL}

MAILBOX CREATED
Email: ${FIRST_EMAIL}
IMAPS: ${MAIL_HOSTNAME}:993 (SSL/TLS)
SMTP submission: ${MAIL_HOSTNAME}:587 (STARTTLS)
SMTP SSL: ${MAIL_HOSTNAME}:465 (SSL/TLS)
Mailbox quota: ${MAILBOX_QUOTA}
Trash and Junk retention: ${MAIL_RETENTION_DAYS} days (0 = disabled)
Sending limit per mailbox: $(send_limits | awk '{print $1 " recipients per hour, " $2 " per day"}') (send-limit.sh)

DNS RECORDS — add in the DNS provider
${MAIL_HOSTNAME}.    A      ${SERVER_IP}
${MAIL_DOMAIN}.      MX     10 ${MAIL_HOSTNAME}.
${MAIL_DOMAIN}.      TXT    "v=spf1 mx ~all"
${DKIM_SELECTOR}._domainkey.${MAIL_DOMAIN}.  TXT  "${DKIM_DNS_VALUE}"
_dmarc.${MAIL_DOMAIN}.  TXT  "v=DMARC1; p=quarantine; rua=mailto:postmaster@${MAIL_DOMAIN}"

PTR — configure at the VPS provider
${SERVER_IP}  PTR  ${MAIL_HOSTNAME}.

NEXT STEPS
1. Add the DNS records above and configure the PTR at the VPS provider.
2. Wait for DNS propagation.
3. Run: sudo bash ${SCRIPT_DIR}/verify-mailserver.sh ${MAIL_HOSTNAME} ${MAIL_DOMAIN} ${DKIM_SELECTOR}
EOF
chmod 600 "$SETUP_SUMMARY"
ok "Root-only setup summary: ${SETUP_SUMMARY}"
touch "$STATE_DIR/setup-complete"

# Optional: the server is installed by now, so a failure here (wrong keys, no
# bucket yet) only leaves backups for later and never breaks the install.
step "Backups"
echo "Encrypted daily backups to S3-compatible storage (AWS S3, Backblaze B2, Wasabi,"
echo "Hetzner, MinIO). You need a bucket and an access key for it."
ask "Set up backups now? [y/N]:"
read -r SETUP_BACKUPS || SETUP_BACKUPS=""
BACKUPS_ON=false
if [[ "${SETUP_BACKUPS,,}" == y ]]; then
    if bash "$SCRIPT_DIR/backup.sh" setup; then
        BACKUPS_ON=true
    else
        warn "Backups were not set up. Try again later: sudo bash ${SCRIPT_DIR}/backup.sh setup"
    fi
else
    info "Skipped. Set them up later: sudo bash ${SCRIPT_DIR}/backup.sh setup"
fi

step "Installation complete"
# ═════════════════════════════════════════════════════════════════════════════

echo
echo -e "${GREEN}${BOLD}The mail server is ready.${NC}"
echo
echo "  Mailbox: ${FIRST_EMAIL}"
if [[ "$FIRST_PASS_GENERATED" == true ]]; then
    show_password_once "$FIRST_EMAIL" "$FIRST_PASS"
fi
echo "  IMAP   : ${MAIL_HOSTNAME}:993  (SSL/TLS)"
echo "  SMTP   : ${MAIL_HOSTNAME}:587  (STARTTLS)"
echo
echo "  Add a domain  : sudo bash ${SCRIPT_DIR}/add-domain.sh"
echo "  Add a mailbox : sudo bash ${SCRIPT_DIR}/add-mailbox.sh"
if $BACKUPS_ON; then
    echo "  Backups       : sudo bash ${SCRIPT_DIR}/backup.sh list"
else
    echo -e "  ${YELLOW}Backups to S3 : sudo bash ${SCRIPT_DIR}/backup.sh setup  (not set up yet)${NC}"
fi
echo "  Sending limit : sudo bash ${SCRIPT_DIR}/send-limit.sh show"
echo "  Status        : sudo bash ${SCRIPT_DIR}/status.sh"
echo
echo -e "${YELLOW}${BOLD}⚠  Outbound port 25 (SMTP):${NC}"
echo "   Many VPS providers block outbound port 25 by default. If mail does not"
echo "   reach external recipients, ask the provider to unblock port 25."
echo "   Hetzner, DigitalOcean, Vultr, Linode, AWS, GCP and Azure all require this."
echo
echo "Logs:"
echo "  journalctl -u postfix -f"
echo "  tail -f /var/log/dovecot.log"
echo "  tail -f /var/log/rspamd/rspamd.log"
