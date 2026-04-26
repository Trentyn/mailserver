# Mail Server Setup Guide

Перед началом заполни таблицу переменных в `README.md`.
Везде в командах заменяй `<VAR>` на свои значения.

---

## Фаза 1: Подготовка системы

### 1.1 Обновить систему

```bash
apt update && apt upgrade -y
apt install -y build-essential net-tools dnsutils curl wget gnupg2 lsb-release
```

### 1.2 Установить hostname

```bash
hostnamectl set-hostname <MAIL_HOSTNAME>
```

Проверить `/etc/hostname` — должен содержать `<MAIL_HOSTNAME>`.

Проверить `/etc/hosts` — должна быть строка:
```
127.0.1.1   <MAIL_HOSTNAME>
<SERVER_IP>  <MAIL_HOSTNAME>
```

> Если сервер использует cloud-init, изменения в `/etc/hosts` нужно вносить в
> `/etc/cloud/templates/hosts.debian.tmpl`, иначе они перезапишутся после перезагрузки.

### 1.3 Настроить ~/.bashrc

```bash
cat >> ~/.bashrc << 'EOF'

# === Mail Server Admin ===
alias mq='mailq'
alias mql='mailq | wc -l'
alias postlog='journalctl -u postfix -f'
alias dovelog='journalctl -u dovecot -f'
alias rsplog='tail -f /var/log/rspamd/rspamd.log'
alias mailstatus='systemctl status postfix dovecot rspamd redis-server fail2ban'
alias mailreload='systemctl reload postfix dovecot rspamd'
alias mailtestconfig='postconf -nf && doveconf -n && rspamadm configtest'
alias f2b='fail2ban-client status'
alias ufw-status='ufw status verbose'

HISTSIZE=10000
HISTFILESIZE=20000
HISTCONTROL=ignoredups:erasedups
shopt -s histappend
PROMPT_COMMAND="history -a; $PROMPT_COMMAND"

PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
EOF
source ~/.bashrc
```

---

## Фаза 2: Установка компонентов

### 2.1 Postfix

```bash
apt install -y postfix postfix-pcre
```

При установке выбрать: **Internet Site**, hostname: `<MAIL_HOSTNAME>`

### 2.2 Dovecot

```bash
apt install -y dovecot-core dovecot-imapd dovecot-pop3d dovecot-lmtpd
```

### 2.3 rspamd

rspamd не входит в стандартные репозитории Debian — добавить официальный:

```bash
curl -s https://rspamd.com/apt-stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/rspamd.gpg
echo "deb [signed-by=/usr/share/keyrings/rspamd.gpg] https://rspamd.com/apt-stable/ $(lsb_release -cs) main" \
  > /etc/apt/sources.list.d/rspamd.list
apt update
apt install -y rspamd
```

### 2.4 Redis, Certbot, fail2ban, UFW

```bash
apt install -y redis-server certbot fail2ban ufw
```

---

## Фаза 3: Настройка Postfix

### 3.1 Создать пользователя vmail

```bash
groupadd -g 5000 vmail
useradd -u 5000 -g vmail -d /var/mail/vhosts -s /sbin/nologin vmail
mkdir -p /var/mail/vhosts
chown vmail:vmail /var/mail/vhosts
```

### 3.2 Основной конфиг `/etc/postfix/main.cf`

```
myhostname = <MAIL_HOSTNAME>
mydomain = <BASE_DOMAIN>
myorigin = <MAIL_HOSTNAME>

inet_interfaces = all
inet_protocols = ipv4

# Отключить локальную доставку — только виртуальные ящики
mydestination =
local_recipient_maps =
local_transport = error:local mail delivery is disabled

# Виртуальные домены (добавлять новые через запятую)
virtual_mailbox_domains = <MAIL_DOMAIN>
virtual_mailbox_base = /var/mail/vhosts
virtual_mailbox_maps = hash:/etc/postfix/vmailbox
virtual_minimum_uid = 100
virtual_uid_maps = static:5000
virtual_gid_maps = static:5000

# SASL через Dovecot
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_auth_enable = yes
smtpd_sasl_security_options = noanonymous

# Milter (rspamd)
smtpd_milters = inet:127.0.0.1:11332
non_smtpd_milters = inet:127.0.0.1:11332
milter_default_action = accept
milter_protocol = 6

# TLS входящие
smtpd_tls_cert_file = /etc/letsencrypt/live/<MAIL_HOSTNAME>/fullchain.pem
smtpd_tls_key_file = /etc/letsencrypt/live/<MAIL_HOSTNAME>/privkey.pem
smtpd_tls_security_level = may
smtpd_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1

# TLS исходящие
smtp_tls_security_level = may
smtp_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1

# Ограничения
smtpd_recipient_restrictions =
    permit_sasl_authenticated,
    permit_mynetworks,
    reject_unauth_destination

smtpd_client_connection_count_limit = 100
smtpd_client_connection_rate_limit = 50

# Фильтр заголовков
header_checks = pcre:/etc/postfix/header_checks
```

### 3.3 Файл `/etc/postfix/header_checks`

```
/^X-Mailer:/    IGNORE
/^X-Originating-IP:/    IGNORE
```

### 3.4 Первый ящик в `/etc/postfix/vmailbox`

```
<USER>@<MAIL_DOMAIN>    <MAIL_DOMAIN>/<USER>/
```

Скомпилировать:
```bash
postmap /etc/postfix/vmailbox
```

### 3.5 Включить submission в `/etc/postfix/master.cf`

Раскомментировать строки для `submission` (порт 587) и `smtps` (порт 465).

### 3.6 Запустить

```bash
postfix check
systemctl enable --now postfix
```

---

## Фаза 4: Настройка Dovecot

Создать `/etc/dovecot/local.conf`:

```
protocols = imap pop3 lmtp

mail_driver = maildir
mail_home = /var/mail/vhosts/%{user|domain}/%{user|username}
mail_path = /var/mail/vhosts/%{user|domain}/%{user|username}

ssl = required
ssl_server_cert_file = /etc/letsencrypt/live/<MAIL_HOSTNAME>/fullchain.pem
ssl_server_key_file  = /etc/letsencrypt/live/<MAIL_HOSTNAME>/privkey.pem
ssl_min_protocol = TLSv1.2

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

service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}

service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}

protocol imap {
  mail_max_userip_connections = 10
}

service imap {
  process_limit = 512
}

service pop3 {
  process_limit = 512
}

log_path = /var/log/dovecot.log
```

Создать пустой файл пользователей:
```bash
touch /etc/dovecot/users
chmod 640 /etc/dovecot/users
```

```bash
doveconf -n
systemctl enable --now dovecot
```

---

## Фаза 5: Настройка rspamd

### 5.1 Milter worker `/etc/rspamd/local.d/worker-proxy.inc`

```
milter = yes;
timeout = 120s;
upstream "local" { default = yes; self_scan = yes; }
bind_socket = "127.0.0.1:11332";
```

### 5.2 Controller `/etc/rspamd/local.d/worker-controller.inc`

```
bind_socket = "127.0.0.1:11334";
```

### 5.3 DKIM signing `/etc/rspamd/local.d/dkim_signing.conf`

```
enabled = true;
sign_authenticated = true;
sign_local = true;
use_domain = "header";
path = "/var/lib/rspamd/dkim/$domain.$selector.key";
selector_map = "/etc/rspamd/dkim_selectors.map";
```

### 5.4 Greylist `/etc/rspamd/local.d/greylisting.conf`

```
enabled = false;
```

### 5.5 Генерировать DKIM ключ для домена

```bash
mkdir -p /var/lib/rspamd/dkim
rspamadm dkim_keygen -s <DKIM_SELECTOR> -d <MAIL_DOMAIN> \
  -k /var/lib/rspamd/dkim/<MAIL_DOMAIN>.<DKIM_SELECTOR>.key \
  > /var/lib/rspamd/dkim/<MAIL_DOMAIN>.<DKIM_SELECTOR>.pub
chown -R _rspamd:_rspamd /var/lib/rspamd/dkim
chmod 700 /var/lib/rspamd/dkim
chmod 440 /var/lib/rspamd/dkim/<MAIL_DOMAIN>.<DKIM_SELECTOR>.key
```

### 5.6 Файл маппинга `/etc/rspamd/dkim_selectors.map`

```
<MAIL_DOMAIN>    <DKIM_SELECTOR>
```

### 5.7 Запустить

```bash
systemctl enable --now redis-server
rspamadm configtest
systemctl enable --now rspamd
```

---

## Фаза 6: TLS сертификат

```bash
certbot certonly --standalone -d <MAIL_HOSTNAME> --email <LETSENCRYPT_EMAIL> --agree-tos -n
```

Установить права на ключ:
```bash
chown root:dovecot /etc/letsencrypt/live/<MAIL_HOSTNAME>/privkey.pem
chmod 640 /etc/letsencrypt/live/<MAIL_HOSTNAME>/privkey.pem
```

Создать хук автообновления `/etc/letsencrypt/renewal-hooks/deploy/reload-mail.sh`:
```bash
#!/bin/bash
systemctl reload postfix dovecot rspamd
```
```bash
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-mail.sh
```

---

## Фаза 7: Firewall (UFW)

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 25/tcp
ufw allow 587/tcp
ufw allow 465/tcp
ufw allow 143/tcp
ufw allow 993/tcp
ufw allow 110/tcp
ufw allow 995/tcp
ufw --force enable
```

> Состояние проверять через `ufw status verbose`, не через systemctl.

---

## Фаза 8: fail2ban

Создать `/etc/fail2ban/jail.local`:

```ini
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
enabled = true
port    = imap,imaps,pop3,pop3s
logpath = /var/log/dovecot.log
maxretry = 5
```

```bash
systemctl enable --now fail2ban
```

---

## Фаза 9: Создание первого ящика

```bash
# Генерировать хеш пароля
doveadm pw -s SHA512-CRYPT -p "<PASSWORD>"

# Добавить в /etc/dovecot/users
echo "<USER>@<MAIL_DOMAIN>:{SHA512-CRYPT}<HASH>" >> /etc/dovecot/users

# Создать директорию Maildir
mkdir -p /var/mail/vhosts/<MAIL_DOMAIN>/<USER>/{cur,new,tmp}
chown -R vmail:vmail /var/mail/vhosts/<MAIL_DOMAIN>
chmod -R 700 /var/mail/vhosts/<MAIL_DOMAIN>

# Перезагрузить сервисы
systemctl reload postfix dovecot
```

Для дополнительных ящиков — смотри `operations.md`.

---

## Фаза 10: DNS записи для `<MAIL_DOMAIN>`

| Тип | Имя | Значение |
|-----|-----|---------|
| MX  | `@` | `10 <MAIL_HOSTNAME>` |
| TXT | `@` | `v=spf1 mx ~all` |
| TXT | `<DKIM_SELECTOR>._domainkey` | содержимое `<MAIL_DOMAIN>.<DKIM_SELECTOR>.pub` |
| TXT | `_dmarc` | `v=DMARC1; p=quarantine; rua=mailto:dmarc@<MAIL_DOMAIN>` |
| PTR | `<SERVER_IP>` | `<MAIL_HOSTNAME>` (настраивается у хостера) |

Для каждого дополнительного домена — повторить весь блок DNS.

---

## Фаза 11: Тестирование

```bash
# Все сервисы запущены
systemctl status postfix dovecot rspamd redis-server fail2ban

# Порты слушают
ss -tlnp | grep -E '25|587|465|143|993|110|995'

# Тест SMTP (установить swaks: apt install swaks)
swaks --to test@gmail.com --from <USER>@<MAIL_DOMAIN> \
  --server <MAIL_HOSTNAME> --port 587 --auth LOGIN \
  --auth-user <USER>@<MAIL_DOMAIN> --auth-password "<PASSWORD>" --tls
```

DKIM проверить — отправить письмо на Gmail, открыть оригинал, найти `dkim=pass`.

---

## Фаза 12: Мониторинг

```bash
journalctl -u postfix -f      # postlog (alias)
journalctl -u dovecot -f      # dovelog (alias)
tail -f /var/log/rspamd/rspamd.log   # rsplog (alias)
mailq                          # mq (alias)
fail2ban-client status         # f2b (alias)
ufw status verbose             # ufw-status (alias)
```

Резервные копии:
- `/etc/postfix/`
- `/etc/dovecot/users`
- `/etc/rspamd/`
- `/var/lib/rspamd/dkim/` (приватные ключи — критично!)
- `/var/mail/vhosts/`
