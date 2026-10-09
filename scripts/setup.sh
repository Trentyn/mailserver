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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR=/etc/mailserver
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# ── Предварительные проверки ──────────────────────────────────────────────────
# Установщик рассчитан только на чистый сервер. Если прошлый запуск прервался
# (например, certbot не смог получить сертификат), его можно безопасно повторить:
# маркер setup-started отличает нашу незавершённую установку от чужой конфигурации.
[[ -e "$STATE_DIR/setup-complete" ]] \
    && die "Почтовый сервер уже установлен. Для обслуживания используй scripts/*.sh."
if [[ -e "$STATE_DIR/setup-started" ]]; then
    RESUMING=true
elif [[ -e /etc/postfix/main.cf || -e /etc/dovecot/local.conf ]]; then
    die "Сервер уже содержит конфигурацию почты. setup.sh запускают только на чистом Debian; для обслуживания используй scripts/*.sh."
else
    RESUMING=false
fi

# shellcheck source=/dev/null
. /etc/os-release
[[ "${ID:-}" == debian && "${VERSION_CODENAME:-}" =~ ^(bookworm|trixie)$ ]] \
    || die "Поддерживаются только Debian 12 (bookworm) и Debian 13 (trixie); обнаружено: ${PRETTY_NAME:-unknown}"
CODENAME="$VERSION_CODENAME"

if [[ ! -e "$STATE_DIR/ufw-configured" ]] && command -v ufw >/dev/null \
    && ufw status | grep -q '^Status: active'; then
    die "UFW уже активен. Чтобы не изменить существующие правила, отключи его или настрой firewall вручную."
fi

if ss -Hltn 'sport = :80' | grep -q .; then
    die "Порт 80 занят ($(ss -Hltnp 'sport = :80' | grep -o 'users:(("[^"]*' | cut -d'"' -f2 | sort -u | paste -sd,)). Он нужен certbot для выпуска сертификата."
fi

$RESUMING && warn "Найдена незавершённая установка — продолжаю с начала, уже сделанные шаги будут перезаписаны."

# ── Bootstrap: минимум инструментов для запуска скрипта ───────────────────────
# curl, dig, gpg могут отсутствовать на чистом Debian — ставим сразу
step "Подготовка"
apt-get update -q
apt-get install "${APT_OPTS[@]}" curl dnsutils gnupg2 ssl-cert
ok "Базовые утилиты готовы"

DOMAIN_RE='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'

# read_val PROMPT DEFAULT [REGEX ERROR]: повторяет вопрос, пока ответ не пройдёт
# проверку, вместо того чтобы обрывать установку из-за опечатки.
read_val() {
    local prompt="$1" default="${2:-}" regex="${3:-}" error="${4:-}" val
    while true; do
        if [[ -n "$default" ]]; then ask "${prompt} [${default}]:" >&2; else ask "${prompt}:" >&2; fi
        read -r val
        val="${val:-$default}"
        val="${val//[[:space:]]/}"
        if [[ -z "$val" ]]; then
            warn "Значение не может быть пустым" >&2
        elif [[ -n "$regex" && ! "${val,,}" =~ $regex ]]; then
            warn "$error" >&2
        else
            echo "$val"
            return
        fi
    done
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

IPV4_RE='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
SERVER_IP=""
for url in https://api.ipify.org https://ifconfig.me; do
    SERVER_IP=$(curl -4fsS --max-time 5 "$url" 2>/dev/null || true)
    [[ "$SERVER_IP" =~ $IPV4_RE ]] && break
    SERVER_IP=""
done
[[ -n "$SERVER_IP" ]] || SERVER_IP=$(hostname -I | awk '{print $1}')
info "Публичный IP: ${BOLD}${SERVER_IP}${NC}"

MAIL_HOSTNAME=$(read_val "FQDN почтового сервера (mx.ваш-домен.com)" "" \
    '^[a-z0-9-]+\.([a-z0-9-]+\.)*[a-z]{2,63}$' "Нужно полное имя хоста, например mx.example.com")
MAIL_HOSTNAME="${MAIL_HOSTNAME,,}"

BASE_DOMAIN="${MAIL_HOSTNAME#*.}"
info "Базовый домен: ${BOLD}${BASE_DOMAIN}${NC}"

MAIL_DOMAIN=$(read_val "Домен для почтовых ящиков (user@???)" "$BASE_DOMAIN" \
    "$DOMAIN_RE" "Некорректный домен, пример: example.com")
MAIL_DOMAIN="${MAIL_DOMAIN,,}"
DKIM_SELECTOR=$(read_val "DKIM селектор" "mail$(date +%Y)" \
    '^[a-z0-9][a-z0-9-]*$' "Селектор может содержать только латиницу, цифры и дефис")
DKIM_SELECTOR="${DKIM_SELECTOR,,}"
LETSENCRYPT_EMAIL=$(read_val "Email для Let's Encrypt уведомлений" "" \
    '^[^@]+@[^@]+\.[^@]+$' "Некорректный email")

# Определяем порт текущей SSH-сессии; на консоли предлагается стандартный 22.
DETECTED_SSH_PORT=$(awk '{print $4}' <<< "${SSH_CONNECTION:-}" 2>/dev/null || true)
while true; do
    SSH_PORT=$(read_val "SSH-порт для UFW (проверь перед подтверждением)" "${DETECTED_SSH_PORT:-22}" \
        '^[0-9]{1,5}$' "Порт должен быть числом")
    (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) && break
    warn "Порт должен быть в диапазоне 1–65535"
done

echo
echo -e "${BOLD}Первый почтовый ящик:${NC}"
FIRST_USER=$(read_val "Имя пользователя (до @)" "info" \
    '^[a-z0-9._+-]+$' "Допустимы латиница, цифры и символы . _ + -")
FIRST_USER="${FIRST_USER,,}"
FIRST_EMAIL="${FIRST_USER}@${MAIL_DOMAIN}"
info "Будет создан ящик: ${BOLD}${FIRST_EMAIL}${NC}"
info "Адреса postmaster@${MAIL_DOMAIN} и abuse@${MAIL_DOMAIN} будут пересылаться в него"
read_secret "Пароль для ${FIRST_EMAIL}"
FIRST_PASS="$REPLY"

MAILBOX_QUOTA=$(read_val "Квота каждого ящика (например 5G)" "5G" \
    '^[1-9][0-9]*[kmgt]$' "Укажи положительный размер, например 5G, 10G или 500M")
MAILBOX_QUOTA="${MAILBOX_QUOTA^^}"

MAIL_RETENTION_DAYS=$(read_val "Сколько дней хранить Bin/Trash и Junk (0 — отключить автоочистку)" "30" \
    '^[0-9]+$' "Укажи количество дней: 0 или положительное целое число")
MAIL_RETENTION_DAYS=$((10#$MAIL_RETENTION_DAYS))

echo
echo -e "${BOLD}Параметры:${NC}"
echo "  MAIL_HOSTNAME : $MAIL_HOSTNAME"
echo "  BASE_DOMAIN   : $BASE_DOMAIN"
echo "  MAIL_DOMAIN   : $MAIL_DOMAIN"
echo "  DKIM_SELECTOR : $DKIM_SELECTOR"
echo "  SERVER_IP     : $SERVER_IP"
echo "  FIRST_EMAIL   : $FIRST_EMAIL"
echo "  MAILBOX_QUOTA : $MAILBOX_QUOTA"
echo "  MAIL_RETENTION_DAYS : $MAIL_RETENTION_DAYS"
echo
ask "Всё верно? Начать установку? [y/N]:"
read -r confirm
[[ "${confirm,,}" == "y" ]] || { info "Отменено."; exit 0; }

install -d -m 0755 "$STATE_DIR"
touch "$STATE_DIR/setup-started"

# ═════════════════════════════════════════════════════════════════════════════
step "Проверка DNS"
# ═════════════════════════════════════════════════════════════════════════════

# certbot всё равно не выпустит сертификат без A-записи, поэтому вместо
# обрыва установки ждём, пока DNS обновится.
while true; do
    info "Проверяю A-запись для ${MAIL_HOSTNAME}..."
    RESOLVED=$(dig +short A "$MAIL_HOSTNAME" @8.8.8.8 2>/dev/null | tail -1 || true)
    [[ -n "$RESOLVED" ]] || RESOLVED=$(dig +short A "$MAIL_HOSTNAME" 2>/dev/null | tail -1 || true)
    if [[ "$RESOLVED" == "$SERVER_IP" ]]; then
        ok "DNS ${MAIL_HOSTNAME} → ${SERVER_IP} ✓"
        break
    fi
    warn "DNS для ${MAIL_HOSTNAME} → '${RESOLVED:-не найдено}', ожидается '${SERVER_IP}'"
    echo
    echo "Добавь A-запись в DNS:"
    echo "  ${MAIL_HOSTNAME}    A    ${SERVER_IP}"
    echo
    ask "Enter — проверить снова, skip — продолжить без проверки, q — выйти:"
    read -r dns_choice
    case "${dns_choice,,}" in
        skip) warn "DNS не подтверждён — certbot может не выпустить сертификат"; break ;;
        q) die "Настрой DNS и запусти скрипт снова." ;;
    esac
done

# Без исходящего 25-го порта сервер сможет принимать почту, но не отправлять её.
if timeout 7 bash -c 'exec 3<>/dev/tcp/gmail-smtp-in.l.google.com/25' 2>/dev/null; then
    ok "Исходящий порт 25 открыт"
else
    warn "Исходящий порт 25 недоступен. Письма на внешние адреса не будут уходить,"
    warn "пока хостер не разблокирует порт 25 (обычно — через тикет в поддержку)."
fi

# ═════════════════════════════════════════════════════════════════════════════
step "Подготовка репозиториев"
# ═════════════════════════════════════════════════════════════════════════════

# Rspamd: официальный production-репозиторий. Debian-пакет заметно отстаёт
# и не поддерживается upstream-проектом.
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://rspamd.com/apt-stable/gpg.key \
    | gpg --dearmor --yes -o /etc/apt/keyrings/rspamd.gpg
echo "deb [signed-by=/etc/apt/keyrings/rspamd.gpg] https://rspamd.com/apt-stable/ ${CODENAME} main" \
    > /etc/apt/sources.list.d/rspamd.list
info "Подключён официальный production-репозиторий Rspamd"

# Dovecot CE 2.4 latest: официальный репозиторий upstream.
# Он поддерживает актуальную стабильную ветку Dovecot 2.4 для Debian.
curl -fsSL https://repo.dovecot.org/DOVECOT-REPO-GPG-2.4 \
    | gpg --dearmor --yes -o /etc/apt/keyrings/dovecot.gpg
cat > /etc/apt/sources.list.d/dovecot.sources << EOF
Types: deb
URIs: https://repo.dovecot.org/ce-2.4-latest/debian/${CODENAME}
Suites: ${CODENAME}
Components: main
Signed-By: /etc/apt/keyrings/dovecot.gpg
EOF
info "Подключён официальный репозиторий Dovecot CE 2.4 latest"

# ═════════════════════════════════════════════════════════════════════════════
step "Установка пакетов"
# ═════════════════════════════════════════════════════════════════════════════

# Предварительно настроить postfix через debconf чтобы apt не спрашивал
echo "postfix postfix/main_mailer_type select Internet Site" | debconf-set-selections
echo "postfix postfix/mailname string ${MAIL_HOSTNAME}" | debconf-set-selections

# Обновить базовую систему до актуальных Debian security/stable-пакетов.
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

# Shell-окружение: общий файл подключается одной строкой из ~/.bashrc root и
# пользователя, который запустил установку. Стандартный Debian .bashrc не
# перезаписывается; чтобы отключить, удали строку с пометкой "# mailserver".
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
    ok "Shell-окружение подключено для ${shell_user}"
done

# ═════════════════════════════════════════════════════════════════════════════
step "TLS сертификат"
# ═════════════════════════════════════════════════════════════════════════════

info "Запрашиваю сертификат для ${MAIL_HOSTNAME}..."
# Сертификат выпускается до записи конфигов Postfix/Dovecot, которые на него
# ссылаются: если certbot упадёт, установку можно просто запустить снова.
if [[ -f "/etc/letsencrypt/live/${MAIL_HOSTNAME}/fullchain.pem" ]]; then
    info "Сертификат уже существует — пропускаю выпуск"
elif ! CERTBOT_OUT=$(certbot certonly --standalone \
        -d "$MAIL_HOSTNAME" \
        --email "$LETSENCRYPT_EMAIL" \
        --agree-tos \
        --non-interactive 2>&1); then
    echo "$CERTBOT_OUT" | sed 's/^/  /'
    die "Сертификат не получен. Проверь A-запись ${MAIL_HOSTNAME} → ${SERVER_IP} и доступность порта 80, затем запусти setup.sh снова."
fi

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
virtual_alias_maps = hash:/etc/postfix/virtual
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
# RFC 5321 требует рабочий postmaster@; туда же приходят отчёты DMARC.
{
    printf 'postmaster@%s\t%s\n' "$MAIL_DOMAIN" "$FIRST_EMAIL"
    printf 'abuse@%s\t%s\n' "$MAIL_DOMAIN" "$FIRST_EMAIL"
} > /etc/postfix/virtual
postmap /etc/postfix/virtual

# submission (587) и smtps (465) в master.cf
# Комментируем существующие незакомментированные строки чтобы не было дублей.
# Только при первом проходе: иначе повторный запуск закомментирует наш же блок.
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
        die "Не удалось отключить системную PAM-аутентификацию Dovecot"
    fi
    if doveconf -n | grep -Eq '^mail_inbox_path = /var/mail/'; then
        die "Dovecot использует системный путь INBOX вместо virtual Maildir"
    fi
fi

ok "Dovecot настроен"

# ═════════════════════════════════════════════════════════════════════════════
step "Настройка rspamd"
# ═════════════════════════════════════════════════════════════════════════════

mkdir -p /etc/rspamd/local.d

# Redis backs Rspamd's Bayes statistics and IMAPSieve user training.
cat > /etc/rspamd/local.d/redis.conf << 'EOF'
servers = "127.0.0.1:6379";
EOF
cat > /etc/rspamd/local.d/options.inc <<'EOF'
task_timeout = 10s;
EOF

cat > /etc/rspamd/local.d/milter_headers.conf << 'EOF'
# Mark only messages Rspamd classifies as spam. Dovecot's global Sieve rule
# consumes this marker and files the message into Junk.
use = ["spam-header"];
routines {
  spam-header {
    header = "X-Rspamd-Deliver-To";
    value = "Junk";
    remove = 0;
  }
}
EOF

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
# При повторном запуске после сбоя ключ не пересоздаётся.
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

rspamadm configtest && ok "rspamd настроен"

install -d -o root -g vmail -m 0750 /etc/dovecot/sieve /usr/lib/dovecot/sieve
cat > /etc/dovecot/sieve/spam-to-junk.sieve <<'EOF'
require ["fileinto", "mailbox"];

if header :is "X-Rspamd-Deliver-To" "Junk" {
    fileinto :create "Junk";
    stop;
}
EOF
cat > /etc/dovecot/sieve/learn-spam.sieve <<'EOF'
require ["vnd.dovecot.pipe", "copy"];
pipe :copy "rspamd-learn-spam";
EOF
cat > /etc/dovecot/sieve/learn-ham.sieve <<'EOF'
require ["vnd.dovecot.pipe", "copy", "imapsieve", "environment"];

# Deleting spam is not a ham report.
if environment :is "imap.mailbox" "Trash" {
    stop;
}
pipe :copy "rspamd-learn-ham";
EOF
cat > /usr/lib/dovecot/sieve/rspamd-learn-spam <<'EOF'
#!/bin/sh
exec /usr/bin/rspamc -h 127.0.0.1:11334 learn_spam
EOF
cat > /usr/lib/dovecot/sieve/rspamd-learn-ham <<'EOF'
#!/bin/sh
exec /usr/bin/rspamc -h 127.0.0.1:11334 learn_ham
EOF
sievec -c /etc/dovecot/dovecot.conf /etc/dovecot/sieve/spam-to-junk.sieve
sievec -c /etc/dovecot/dovecot.conf /etc/dovecot/sieve/learn-spam.sieve
sievec -c /etc/dovecot/dovecot.conf /etc/dovecot/sieve/learn-ham.sieve
chown root:vmail /etc/dovecot/sieve/* /usr/lib/dovecot/sieve/rspamd-learn-spam /usr/lib/dovecot/sieve/rspamd-learn-ham
chmod 0640 /etc/dovecot/sieve/*.sieve /etc/dovecot/sieve/*.svbin
chmod 0750 /usr/lib/dovecot/sieve/rspamd-learn-spam /usr/lib/dovecot/sieve/rspamd-learn-ham

# Проверяем итоговый конфиг Postfix
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
# Dovecot пишет в собственный лог — без ротации он растёт бесконечно.
if ! grep -rqs '/var/log/dovecot.log' /etc/logrotate.d/; then
    cat > /etc/logrotate.d/mailserver-dovecot << 'EOF'
/var/log/dovecot.log {
    weekly
    rotate 8
    missingok
    notifempty
    compress
    delaycompress
    postrotate
        doveadm log reopen >/dev/null 2>&1 || true
    endscript
}
EOF
fi
# fail2ban не запускается, если указанного logpath ещё нет.
touch /var/log/mail.log /var/log/dovecot.log
ok "fail2ban настроен"

# ═════════════════════════════════════════════════════════════════════════════
step "Первый почтовый ящик"
# ═════════════════════════════════════════════════════════════════════════════

HASH=$(doveadm pw -s SHA512-CRYPT -p "$FIRST_PASS")
echo "${FIRST_EMAIL}:${HASH}" > /etc/dovecot/users

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

# Пакеты могли стартовать с конфигурацией по умолчанию до записи main.cf/local.conf
# и jail.local. Перезапуск применяет новые параметры, включая inet_protocols и Dovecot 2.4;
# fail2ban перезапускается последним, когда логи сервисов уже существуют.
systemctl restart rsyslog postfix dovecot rspamd
systemctl restart fail2ban

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

if [[ -e "$STATE_DIR/ufw-configured" ]]; then
    info "UFW уже настроен прошлым запуском — пропускаю"
else
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
    # Опечатка не должна обрывать установку: спрашиваем, пока откат не отключил UFW.
    # Таймер после срабатывания остаётся «active (elapsed)», поэтому смотрим на сам UFW.
    UFW_CONFIRM=""
    while ufw status | grep -q '^Status: active'; do
        ask "Confirmation:"
        # Тайм-аут, чтобы заметить сработавший откат, даже если никто не ответил.
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
    step "Автоочистка Bin/Trash и Junk"
    bash "$SCRIPT_DIR/install-mail-cleanup-timer.sh" "$MAIL_RETENTION_DAYS"
    ok "Bin/Trash и Junk будут очищаться через $MAIL_RETENTION_DAYS дней"
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
    "\"v=DMARC1; p=quarantine; rua=mailto:postmaster@${MAIL_DOMAIN}\""
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
Trash and Junk retention: ${MAIL_RETENTION_DAYS} days (0 = disabled)

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
4. Store this password in a password manager, then securely delete this file.
EOF
chmod 600 "$SETUP_SUMMARY"
ok "Создан защищённый итоговый файл: ${SETUP_SUMMARY}"
touch "$STATE_DIR/setup-complete"

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
