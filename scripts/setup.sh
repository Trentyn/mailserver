#!/bin/bash
# Mail Server Setup — Debian 12/13
# Postfix + Dovecot 2.4 + rspamd (latest) + Let's Encrypt
set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step()  { echo -e "\n${BOLD}${CYAN}══ $* ${NC}"; }
ask()   { echo -en "${YELLOW}[?]${NC} $* "; }

[[ $EUID -eq 0 ]] || die "Запусти скрипт от root: sudo bash setup.sh"

# Этот установщик предназначен только для чистого сервера. Повторный запуск
# способен перезаписать рабочие конфиги; для обслуживания используются scripts/*.sh.
if [[ -e /etc/postfix/main.cf || -e /etc/dovecot/local.conf ]]; then
    die "Сервер уже содержит конфигурацию почты. setup.sh запускают только на чистом Debian; для обслуживания используй scripts/*.sh."
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Bootstrap: минимум инструментов для запуска скрипта ───────────────────────
# curl, dig, gpg могут отсутствовать на чистом Debian — ставим сразу
step "Подготовка"
apt-get update -q
apt-get install -y -q curl dnsutils gnupg2 lsb-release
ok "Базовые утилиты готовы"

read_val() {
    local prompt="$1" default="${2:-}" val
    if [[ -n "$default" ]]; then ask "${prompt} [${default}]:" >&2; else ask "${prompt}:" >&2; fi
    read -r val
    echo "${val:-$default}"
}

read_secret() {
    local prompt="$1" val confirm
    while true; do
        ask "${prompt}:" >&2; read -rs val; echo
        [[ -z "$val" ]] && warn "Пароль не может быть пустым" >&2 && continue
        ask "Повтори пароль:" >&2; read -rs confirm; echo
        [[ "$val" == "$confirm" ]] && break
        warn "Пароли не совпадают, попробуй снова" >&2
    done
    REPLY="$val"
}

# ═════════════════════════════════════════════════════════════════════════════
step "Сбор параметров"
# ═════════════════════════════════════════════════════════════════════════════

echo
echo "Тебе понадобится:"
echo "  • FQDN почтового сервера (например: mx.example.com)"
echo "  • Домен для почтовых ящиков (например: example.com)"
echo "  • Email для уведомлений Let's Encrypt"
echo "  • DNS A-запись для FQDN должна уже указывать на этот сервер"
echo

SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null \
    || curl -4 -s --max-time 5 api.ipify.org 2>/dev/null \
    || hostname -I | awk '{print $1}')
info "Публичный IP: ${BOLD}${SERVER_IP}${NC}"

MAIL_HOSTNAME=$(read_val "FQDN почтового сервера (mx.ваш-домен.com)")
[[ "$MAIL_HOSTNAME" == *.* ]] || die "FQDN должен содержать точку: mx.example.com"
MAIL_HOSTNAME="${MAIL_HOSTNAME,,}"

BASE_DOMAIN="${MAIL_HOSTNAME#*.}"
info "Базовый домен: ${BOLD}${BASE_DOMAIN}${NC}"

MAIL_DOMAIN=$(read_val "Домен для почтовых ящиков (user@???)" "$BASE_DOMAIN")
MAIL_DOMAIN="${MAIL_DOMAIN,,}"
DKIM_SELECTOR=$(read_val "DKIM селектор" "mail$(date +%Y)")
LETSENCRYPT_EMAIL=$(read_val "Email для Let's Encrypt уведомлений")
[[ "$LETSENCRYPT_EMAIL" == *@* ]] || die "Некорректный email"

# Определяем порт текущей SSH-сессии; на консоли предлагается стандартный 22.
DETECTED_SSH_PORT=$(awk '{print $4}' <<< "${SSH_CONNECTION:-}" 2>/dev/null || true)
SSH_PORT=$(read_val "SSH-порт для UFW (проверь перед подтверждением)" "${DETECTED_SSH_PORT:-22}")
[[ "$SSH_PORT" =~ ^[0-9]{1,5}$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) \
    || die "Некорректный SSH-порт: ${SSH_PORT}"

echo
echo -e "${BOLD}Первый почтовый ящик:${NC}"
FIRST_USER=$(read_val "Имя пользователя (до @)" "info")
FIRST_USER="${FIRST_USER,,}"
FIRST_EMAIL="${FIRST_USER}@${MAIL_DOMAIN}"
info "Будет создан ящик: ${BOLD}${FIRST_EMAIL}${NC}"
read_secret "Пароль для ${FIRST_EMAIL}"
FIRST_PASS="$REPLY"

MAILBOX_QUOTA=$(read_val "Квота каждого ящика (например 5G)" "5G")
MAILBOX_QUOTA="${MAILBOX_QUOTA^^}"
[[ "$MAILBOX_QUOTA" =~ ^[1-9][0-9]*[KMGT]$ ]] || die "Укажи положительный размер, например 5G, 10G или 500M"

TRASH_RETENTION_DAYS=$(read_val "Сколько дней хранить Bin/Trash (0 — отключить автоочистку)" "30")
[[ "$TRASH_RETENTION_DAYS" =~ ^[0-9]+$ ]] || die "Укажи количество дней: 0 или положительное целое число"

echo
echo -e "${BOLD}Параметры:${NC}"
echo "  MAIL_HOSTNAME : $MAIL_HOSTNAME"
echo "  BASE_DOMAIN   : $BASE_DOMAIN"
echo "  MAIL_DOMAIN   : $MAIL_DOMAIN"
echo "  DKIM_SELECTOR : $DKIM_SELECTOR"
echo "  SERVER_IP     : $SERVER_IP"
echo "  FIRST_EMAIL   : $FIRST_EMAIL"
echo "  MAILBOX_QUOTA : $MAILBOX_QUOTA"
echo "  TRASH_RETENTION_DAYS : $TRASH_RETENTION_DAYS"
echo
ask "Всё верно? Начать установку? [y/N]:"
read -r confirm
[[ "${confirm,,}" == "y" ]] || { info "Отменено."; exit 0; }

# ═════════════════════════════════════════════════════════════════════════════
step "Проверка DNS"
# ═════════════════════════════════════════════════════════════════════════════

info "Проверяю A-запись для ${MAIL_HOSTNAME}..."
RESOLVED=$(dig +short A "$MAIL_HOSTNAME" @8.8.8.8 2>/dev/null | tail -1 || true)

if [[ "$RESOLVED" != "$SERVER_IP" ]]; then
    warn "DNS для ${MAIL_HOSTNAME} → '${RESOLVED:-не найдено}', ожидается '${SERVER_IP}'"
    echo
    echo "Добавь A-запись в DNS:"
    echo "  ${MAIL_HOSTNAME}    A    ${SERVER_IP}"
    echo
    ask "DNS ещё не обновился? Пропустить проверку и продолжить? [y/N]:"
    read -r skip_dns
    [[ "${skip_dns,,}" == "y" ]] || die "Настрой DNS и запусти скрипт снова."
    warn "DNS не подтверждён — certbot может упасть!"
else
    ok "DNS ${MAIL_HOSTNAME} → ${SERVER_IP} ✓"
fi

# ═════════════════════════════════════════════════════════════════════════════
step "Подготовка репозиториев"
# ═════════════════════════════════════════════════════════════════════════════

# Rspamd: официальный production-репозиторий. Debian-пакет заметно отстаёт
# и не поддерживается upstream-проектом.
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://rspamd.com/apt-stable/gpg.key \
    | gpg --dearmor --yes -o /etc/apt/keyrings/rspamd.gpg
echo "deb [signed-by=/etc/apt/keyrings/rspamd.gpg] https://rspamd.com/apt-stable/ $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/rspamd.list
info "Подключён официальный production-репозиторий Rspamd"

# Dovecot CE 2.4 latest: официальный репозиторий upstream.
# Он поддерживает актуальную стабильную ветку Dovecot 2.4 для Debian.
curl -fsSL https://repo.dovecot.org/DOVECOT-REPO-GPG-2.4 \
    | gpg --dearmor --yes -o /etc/apt/keyrings/dovecot.gpg
cat > /etc/apt/sources.list.d/dovecot.sources << EOF
Types: deb
URIs: https://repo.dovecot.org/ce-2.4-latest/debian/$(lsb_release -cs)
Suites: $(lsb_release -cs)
Components: main
Signed-By: /etc/apt/keyrings/dovecot.gpg
EOF
info "Подключён официальный репозиторий Dovecot CE 2.4 latest"

# ═════════════════════════════════════════════════════════════════════════════
step "Установка пакетов"
# ═════════════════════════════════════════════════════════════════════════════

# Предварительно настроить postfix через debconf чтобы apt не спрашивал
export DEBIAN_FRONTEND=noninteractive
echo "postfix postfix/main_mailer_type select Internet Site" | debconf-set-selections
echo "postfix postfix/mailname string ${MAIL_HOSTNAME}" | debconf-set-selections

# Обновить базовую систему до актуальных Debian security/stable-пакетов.
apt-get update -q
apt-get upgrade -y -q
apt-get install -y -q \
    postfix postfix-pcre \
    dovecot-core dovecot-imapd dovecot-pop3d dovecot-lmtpd \
    rspamd \
    redis-server \
    certbot \
    fail2ban \
    rsyslog \
    dnsutils curl wget gnupg2 lsb-release swaks openssl ufw git

ok "Все пакеты установлены"
info "Версии:"
echo "  postfix:  $(postconf -h mail_version 2>/dev/null || echo 'n/a')"
echo "  dovecot:  $(dovecot --version 2>/dev/null | head -1 || echo 'n/a')"
echo "  rspamd:   $(rspamd --version 2>/dev/null | head -1 || echo 'n/a')"
echo "  certbot:  $(certbot --version 2>/dev/null || echo 'n/a')"

# ═════════════════════════════════════════════════════════════════════════════
step "Настройка системы"
# ═════════════════════════════════════════════════════════════════════════════

hostnamectl set-hostname "$MAIL_HOSTNAME"

if [[ -f /etc/cloud/templates/hosts.debian.tmpl ]]; then
    info "Cloud-init обнаружен — hostname подставится в /etc/hosts автоматически"
else
    if ! grep -q "$MAIL_HOSTNAME" /etc/hosts; then
        echo "127.0.1.1   $MAIL_HOSTNAME ${MAIL_HOSTNAME%%.*}" >> /etc/hosts
    fi
fi
ok "Hostname: $(hostname)"

if ! grep -q 'Mail Server Admin' /root/.bashrc 2>/dev/null; then
cat >> /root/.bashrc << 'BASHRC'

# === Mail Server Admin ===
alias mq='mailq'
alias mql='mailq | wc -l'
alias postlog='journalctl -u postfix -f'
alias dovelog='journalctl -u dovecot -f'
alias rsplog='tail -f /var/log/rspamd/rspamd.log'
alias mailstatus='systemctl status postfix dovecot rspamd redis-server fail2ban'
alias mailreload='systemctl reload postfix dovecot rspamd'
alias f2b='fail2ban-client status'
BASHRC
fi

# Настроить удобный prompt для пользователя, который запускает установщик.
# На чистом VPS его стандартный .bashrc сохраняется в резервную копию.
TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == root ]]; then
    TARGET_USER=$(getent passwd 1000 | cut -d: -f1 || true)
fi
if [[ -n "$TARGET_USER" ]] && id "$TARGET_USER" &>/dev/null; then
    TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    TARGET_BASHRC="${TARGET_HOME}/.bashrc"
    if [[ -f "$TARGET_BASHRC" ]]; then
        TARGET_BASHRC_BACKUP="${TARGET_BASHRC}.bak.$(date +%Y%m%d%H%M%S)"
        cp "$TARGET_BASHRC" "$TARGET_BASHRC_BACKUP"
        info "Создан backup ${TARGET_BASHRC_BACKUP}"
    fi
    cat > "$TARGET_BASHRC" << 'BASHRC'
# ~/.bashrc: executed by bash(1) for non-login shells.

HISTCONTROL=ignoreboth:erasedups
shopt -s histappend

parse_git_branch() {
  git branch 2>/dev/null | grep '\*' | sed 's/\* / (/;s/$/)/'
}

PS1='\[\e[1;31m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\[\e[1;33m\]$(parse_git_branch)\[\e[0m\]\$ '

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
BASHRC
    chown "$TARGET_USER:$TARGET_USER" "$TARGET_BASHRC"
    chmod 644 "$TARGET_BASHRC"
    ok "Обновлён ${TARGET_BASHRC}"
else
    warn "Не удалось определить обычного пользователя для .bashrc"
fi

# ═════════════════════════════════════════════════════════════════════════════
step "Создание пользователя vmail"
# ═════════════════════════════════════════════════════════════════════════════

getent group vmail &>/dev/null  || groupadd -g 5000 vmail
getent passwd vmail &>/dev/null || useradd -u 5000 -g vmail -d /var/mail/vhosts -s /sbin/nologin vmail
mkdir -p /var/mail/vhosts
chown vmail:vmail /var/mail/vhosts
ok "vmail готов"

# ═════════════════════════════════════════════════════════════════════════════
step "Настройка Postfix"
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

# Локальная доставка отключена — только виртуальные ящики
mydestination =
local_recipient_maps =
local_transport = error:local mail delivery is disabled

# Виртуальные домены
virtual_mailbox_domains = ${MAIL_DOMAIN}
virtual_mailbox_base = /var/mail/vhosts
virtual_mailbox_maps = hash:/etc/postfix/vmailbox
smtpd_sender_login_maps = hash:/etc/postfix/sender_login_maps
virtual_minimum_uid = 100
virtual_uid_maps = static:5000
virtual_gid_maps = static:5000
virtual_transport = lmtp:unix:private/dovecot-lmtp

# SASL через Dovecot
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

# TLS входящие
smtpd_tls_cert_file = /etc/letsencrypt/live/${MAIL_HOSTNAME}/fullchain.pem
smtpd_tls_key_file = /etc/letsencrypt/live/${MAIL_HOSTNAME}/privkey.pem
smtpd_tls_security_level = may
smtpd_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtpd_tls_mandatory_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtpd_tls_loglevel = 1
smtpd_tls_received_header = yes

# TLS исходящие
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

# Первый ящик
printf '%s\t%s/%s/\n' "$FIRST_EMAIL" "$MAIL_DOMAIN" "$FIRST_USER" > /etc/postfix/vmailbox
postmap /etc/postfix/vmailbox
printf '%s\t%s\n' "$FIRST_EMAIL" "$FIRST_EMAIL" > /etc/postfix/sender_login_maps
postmap /etc/postfix/sender_login_maps

# submission (587) и smtps (465) в master.cf
# Комментируем существующие незакомментированные строки чтобы не было дублей
sed -i 's/^submission /#submission /' /etc/postfix/master.cf 2>/dev/null || true
sed -i 's/^smtps /#smtps /'         /etc/postfix/master.cf 2>/dev/null || true

if ! grep -q '# mailserver-setup: ports' /etc/postfix/master.cf; then
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

ok "Postfix настроен"

# ═════════════════════════════════════════════════════════════════════════════
step "Настройка Dovecot"
# ═════════════════════════════════════════════════════════════════════════════

cat > /etc/dovecot/local.conf << EOF
# ${MAIL_HOSTNAME}
protocols = imap pop3 lmtp

# Хранилище (Dovecot 2.4)
mail_driver = maildir
mail_home = /var/mail/vhosts/%{user|domain}/%{user|username}
mail_path = /var/mail/vhosts/%{user|domain}/%{user|username}
# Debian defaults to /var/mail/%{user}; virtual Maildir must use mail_path for INBOX.
mail_inbox_path =

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

# Пакет из официального репозитория может не включать local.conf по умолчанию.
# Подключаем его явно, не дублируя строку при повторном запуске.
if ! grep -Fxq "!include_try local.conf" /etc/dovecot/dovecot.conf; then
    printf "\\n!include_try local.conf\\n" >> /etc/dovecot/dovecot.conf
fi

touch /etc/dovecot/users
chown root:dovecot /etc/dovecot/users
chmod 640 /etc/dovecot/users

# Отключить системную аутентификацию: почтовые ящики берутся из passwd-file.
# Dovecot 2.4 (Debian 13) задаёт эти блоки напрямую; старые версии — include.
if [[ -f /etc/dovecot/conf.d/10-auth.conf ]]; then
    sed -Ei '/^[[:space:]]*passdb[[:space:]]+pam[[:space:]]*\{/,/^[[:space:]]*\}[[:space:]]*$/ s/^/#/' \
        /etc/dovecot/conf.d/10-auth.conf
    sed -Ei '/^[[:space:]]*userdb[[:space:]]+passwd[[:space:]]*\{/,/^[[:space:]]*\}[[:space:]]*$/ s/^/#/' \
        /etc/dovecot/conf.d/10-auth.conf
    sed -Ei '/^[[:space:]]*!include[[:space:]]+auth-system\.conf\.ext/s/^/#/' \
        /etc/dovecot/conf.d/10-auth.conf

    if doveconf -n | grep -Eq '^[[:space:]]*(passdb pam|userdb passwd)'; then
        error "Не удалось отключить системную PAM-аутентификацию Dovecot"
        exit 1
    fi
    if doveconf -n | grep -Eq '^mail_inbox_path = /var/mail/'; then
        error "Dovecot использует системный путь INBOX вместо virtual Maildir"
        exit 1
    fi
fi

ok "Dovecot настроен"

# ═════════════════════════════════════════════════════════════════════════════
step "Настройка rspamd"
# ═════════════════════════════════════════════════════════════════════════════

mkdir -p /etc/rspamd/local.d

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
rspamadm dkim_keygen \
    -b 2048 \
    -s "$DKIM_SELECTOR" \
    -d "$MAIL_DOMAIN" \
    -k "/var/lib/rspamd/dkim/${MAIL_DOMAIN}.${DKIM_SELECTOR}.key" \
    > "/var/lib/rspamd/dkim/${MAIL_DOMAIN}.${DKIM_SELECTOR}.pub"

chown -R _rspamd:_rspamd /var/lib/rspamd/dkim
chmod 700 /var/lib/rspamd/dkim
chmod 440 "/var/lib/rspamd/dkim/${MAIL_DOMAIN}.${DKIM_SELECTOR}.key"

echo "${MAIL_DOMAIN}    ${DKIM_SELECTOR}" > /etc/rspamd/dkim_selectors.map

rspamadm configtest && ok "rspamd настроен"

# ═════════════════════════════════════════════════════════════════════════════
step "TLS сертификат"
# ═════════════════════════════════════════════════════════════════════════════

info "Запрашиваю сертификат для ${MAIL_HOSTNAME}..."
CERTBOT_OUT=$(mktemp)
certbot certonly --standalone \
    -d "$MAIL_HOSTNAME" \
    --email "$LETSENCRYPT_EMAIL" \
    --agree-tos \
    --non-interactive > "$CERTBOT_OUT" 2>&1 || true
grep -E 'Successfully|Certificate|Error|failed' "$CERTBOT_OUT" | sed 's/^/  /' || true
rm -f "$CERTBOT_OUT"

[[ -f "/etc/letsencrypt/live/${MAIL_HOSTNAME}/fullchain.pem" ]] \
    || die "Сертификат не получен. Проверь DNS и попробуй снова."

chown root:dovecot "/etc/letsencrypt/live/${MAIL_HOSTNAME}/privkey.pem"
chmod 640 "/etc/letsencrypt/live/${MAIL_HOSTNAME}/privkey.pem"
ok "TLS сертификат получен"

# Deploy hook: фиксирует права и перезагружает сервисы при автообновлении
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-mail.sh << 'EOF'
#!/bin/bash
for d in /etc/letsencrypt/live/*/privkey.pem; do
    chown root:dovecot "$d"
    chmod 640 "$d"
done
systemctl reload postfix dovecot rspamd
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-mail.sh

# Проверяем конфиг Postfix теперь когда cert существует
if postfix check 2>&1; then
    ok "Postfix конфиг валиден"
else
    warn "Postfix check выдал предупреждения — смотри вывод выше"
fi

# ═════════════════════════════════════════════════════════════════════════════
step "fail2ban"
# ═════════════════════════════════════════════════════════════════════════════

cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime  = 86400
findtime = 3600
maxretry = 5

[sshd]
enabled = true

[postfix-sasl]
enabled  = true
port     = smtp,465,submission
filter   = postfix[mode=auth]
logpath  = /var/log/mail.log
maxretry = 5

[dovecot]
enabled  = true
port     = imap,imaps,pop3,pop3s
logpath  = /var/log/dovecot.log
maxretry = 5
EOF
ok "fail2ban настроен"

# ═════════════════════════════════════════════════════════════════════════════
step "Первый почтовый ящик"
# ═════════════════════════════════════════════════════════════════════════════

HASH=$(doveadm pw -s SHA512-CRYPT -p "$FIRST_PASS")
echo "${FIRST_EMAIL}:${HASH}" >> /etc/dovecot/users

mkdir -p "/var/mail/vhosts/${MAIL_DOMAIN}/${FIRST_USER}"/{cur,new,tmp}
chown -R vmail:vmail "/var/mail/vhosts/${MAIL_DOMAIN}"
chmod -R 700 "/var/mail/vhosts/${MAIL_DOMAIN}"
ok "Ящик ${FIRST_EMAIL} создан"

# ═════════════════════════════════════════════════════════════════════════════
step "Запуск сервисов"
# ═════════════════════════════════════════════════════════════════════════════

systemctl enable --now redis-server
systemctl enable --now rspamd
systemctl enable --now postfix
systemctl enable --now dovecot
systemctl enable --now fail2ban

# Пакеты могли стартовать с конфигурацией по умолчанию до записи main.cf/local.conf.
# Перезапуск применяет новые параметры, включая inet_protocols и Dovecot 2.4.
systemctl restart postfix dovecot rspamd

sleep 3

for svc in postfix dovecot rspamd redis-server fail2ban; do
    if systemctl is-active --quiet "$svc"; then
        ok "$svc"
    else
        warn "$svc НЕ запущен — проверь: journalctl -u $svc -n 30"
    fi
done

# ═════════════════════════════════════════════════════════════════════════════
step "Проверка аутентификации"
# ═════════════════════════════════════════════════════════════════════════════

sleep 1
AUTH_RESULT=$(doveadm auth test "$FIRST_EMAIL" "$FIRST_PASS" 2>&1 || true)
if echo "$AUTH_RESULT" | grep -q "auth succeeded"; then
    ok "Аутентификация ${FIRST_EMAIL} ✓"
else
    warn "Аутентификация не прошла. Проверь: doveadm auth test '${FIRST_EMAIL}' 'пароль'"
    echo "$AUTH_RESULT" | sed 's/^/  /'
fi

# ═════════════════════════════════════════════════════════════════════════════
# ═════════════════════════════════════════════════════════════════════════════
step "Настройка UFW с защитой от потери SSH"
# ═════════════════════════════════════════════════════════════════════════════

if ufw status | grep -q '^Status: active'; then
    die "UFW уже активен. Чтобы не изменить существующие правила, настрой его вручную."
fi

# Аварийный откат отключит UFW через 3 минуты, если новый SSH-вход не проверен.
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
    || die "Не удалось запланировать безопасный откат UFW"
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp" comment 'SSH verified port'
ufw allow 25/tcp comment 'SMTP'
ufw allow 80/tcp comment 'HTTP Lets Encrypt'
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
ask "Confirmation:"
read -r UFW_CONFIRM
if [[ "$UFW_CONFIRM" != 'SSH-OK' ]]; then
    warn "UFW will be disabled automatically when the 3-minute rollback expires."
    exit 1
fi
systemctl stop "${UFW_ROLLBACK_UNIT}.timer"
rm -f "/run/systemd/system/${UFW_ROLLBACK_UNIT}.service" "/run/systemd/system/${UFW_ROLLBACK_UNIT}.timer"
systemctl daemon-reload
ok "UFW enabled; SSH port ${SSH_PORT} was verified by the owner"

if (( TRASH_RETENTION_DAYS > 0 )); then
    step "Автоочистка Bin/Trash"
    bash "$SCRIPT_DIR/install-mail-cleanup-timer.sh" "$TRASH_RETENTION_DAYS"
    ok "Bin/Trash будут очищаться через $TRASH_RETENTION_DAYS дней"
else
    info "Автоочистка Bin/Trash отключена"
fi

# ═════════════════════════════════════════════════════════════════════════════
step "DNS записи — добавь в панели управления доменом"
# ═════════════════════════════════════════════════════════════════════════════

echo
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║         DNS ЗАПИСИ ДЛЯ: ${MAIL_DOMAIN}${NC}"
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
printf "  Имя:   %s\n"   "${DKIM_SELECTOR}._domainkey.${MAIL_DOMAIN}."
printf "  Тип:   TXT\n"
echo   "  Значение:"
grep -oE '"[^"]*"' "/var/lib/rspamd/dkim/${MAIL_DOMAIN}.${DKIM_SELECTOR}.pub" | tr -d '"\n'; echo
echo
echo -e "${CYAN}── DMARC ────────────────────────────────────────────────────${NC}"
printf "  %-40s  TXT    %s\n" "_dmarc.${MAIL_DOMAIN}." \
    "\"v=DMARC1; p=quarantine; rua=mailto:${FIRST_EMAIL}\""
echo
echo -e "${CYAN}── PTR (у хостера, не в DNS домена) ────────────────────────${NC}"
printf "  %-40s  PTR    %s\n" "${SERVER_IP}" "${MAIL_HOSTNAME}."
echo
echo -e "${YELLOW}Проверить DKIM после распространения DNS: https://mxtoolbox.com/dkim.aspx${NC}"

# ═════════════════════════════════════════════════════════════════════════════
# Сводка содержит пароль первого ящика, поэтому остаётся только у root.
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
Password: ${FIRST_PASS}
IMAPS: ${MAIL_HOSTNAME}:993 (SSL/TLS)
SMTP submission: ${MAIL_HOSTNAME}:587 (STARTTLS)
SMTP SSL: ${MAIL_HOSTNAME}:465 (SSL/TLS)
Mailbox quota: ${MAILBOX_QUOTA}
Bin/Trash retention: ${TRASH_RETENTION_DAYS} days (0 = disabled)

DNS RECORDS — add in the DNS provider
${MAIL_HOSTNAME}.    A      ${SERVER_IP}
${MAIL_DOMAIN}.      MX     10 ${MAIL_HOSTNAME}.
${MAIL_DOMAIN}.      TXT    "v=spf1 mx ~all"
${DKIM_SELECTOR}._domainkey.${MAIL_DOMAIN}.  TXT  "${DKIM_DNS_VALUE}"
_dmarc.${MAIL_DOMAIN}.  TXT  "v=DMARC1; p=quarantine; rua=mailto:${FIRST_EMAIL}"

PTR — configure at the VPS provider
${SERVER_IP}  PTR  ${MAIL_HOSTNAME}.

NEXT STEPS
1. Add the DNS records above and configure the PTR at the VPS provider.
2. Wait for DNS propagation.
3. Run: sudo bash ${SCRIPT_DIR}/verify-mailserver.sh ${MAIL_HOSTNAME} ${MAIL_DOMAIN} ${DKIM_SELECTOR}
4. Store this password in a password manager, then securely delete this file.
EOF
chmod 600 "$SETUP_SUMMARY"
ok "Создан защищённый итоговый файл: ${SETUP_SUMMARY}"

step "Установка завершена!"
# ═════════════════════════════════════════════════════════════════════════════

echo
echo -e "${GREEN}${BOLD}Сервер готов!${NC}"
echo
echo "  Ящик  : ${FIRST_EMAIL}"
echo "  IMAP  : ${MAIL_HOSTNAME}:993  (SSL/TLS)"
echo "  SMTP  : ${MAIL_HOSTNAME}:587  (STARTTLS)"
echo
echo "  Добавить домен : bash ${SCRIPT_DIR}/add-domain.sh"
echo "  Добавить ящик  : bash ${SCRIPT_DIR}/add-mailbox.sh"
echo "  Статус         : bash ${SCRIPT_DIR}/status.sh"
echo
echo -e "${YELLOW}${BOLD}⚠  ВАЖНО — порт 25 (SMTP):${NC}"
echo "   Многие VPS-провайдеры блокируют исходящий порт 25 по умолчанию."
echo "   Если письма не доходят до внешних адресатов — обратись в поддержку"
echo "   хостера и попроси разблокировать порт 25 для твоего сервера."
echo "   Провайдеры у которых это точно нужно делать:"
echo "   Hetzner, DigitalOcean, Vultr, Linode, AWS, GCP, Azure"
echo
echo "Логи:"
echo "  journalctl -u postfix -f"
echo "  journalctl -u dovecot -f"
echo "  tail -f /var/log/rspamd/rspamd.log"
