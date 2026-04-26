# Известные проблемы — Debian 13 / Dovecot 2.4

Этот файл — шпаргалка для следующей установки. Все грабли уже собраны здесь.

---

## 1. Dovecot 2.4 — `mail_location` больше не существует

**Ошибка:**
```
doveconf: Fatal: Error in configuration file /etc/dovecot/local.conf line 7: mail_location: Unknown setting
```

**Причина:** В Dovecot 2.4 настройка `mail_location` разделена на три отдельные.

**Неправильно (Dovecot ≤ 2.3):**
```
mail_location = maildir:/var/mail/vhosts/%d/%n
```

**Правильно (Dovecot 2.4):**
```
mail_driver = maildir
mail_home = /var/mail/vhosts/%{user|domain}/%{user|username}
mail_path = /var/mail/vhosts/%{user|domain}/%{user|username}
```

Переменные тоже изменились:
- `%d` → `%{user|domain}`
- `%n` → `%{user|username}`

---

## 2. Dovecot 2.4 — переименованы настройки SSL

**Неправильно:**
```
ssl_cert = </path/to/fullchain.pem
ssl_key = </path/to/privkey.pem
```

**Правильно (Dovecot 2.4):**
```
ssl_server_cert_file = /path/to/fullchain.pem
ssl_server_key_file  = /path/to/privkey.pem
```

Синтаксис `< /path` (чтение из файла) больше не используется — теперь просто путь строкой.

---

## 3. Dovecot 2.4 — изменился синтаксис блоков `passdb` и `userdb`

**Ошибка:**
```
doveconf: Fatal: Error in configuration file /etc/dovecot/local.conf line 23: passdb { } is missing section name
```

**Неправильно (Dovecot ≤ 2.3):**
```
passdb {
  driver = passwd-file
  args = scheme=SHA512-CRYPT username_format=%u /etc/dovecot/users
}
userdb {
  driver = static
  args = uid=5000 gid=5000 home=/var/mail/vhosts/%d/%n
}
```

**Правильно (Dovecot 2.4):**
```
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
```

---

## 4. Dovecot 2.4 — переименована настройка `disable_plaintext_auth`

**Неправильно:**
```
disable_plaintext_auth = yes
```

**Правильно (Dovecot 2.4):**
```
auth_allow_cleartext = no
```

---

## 5. Dovecot 2.4 — `process_limit` нельзя ставить внутри блока `protocol {}`

**Ошибка:**
```
doveconf: Fatal: Error in configuration file /etc/dovecot/local.conf line 39: process_limit: Unknown setting
```

**Неправильно:**
```
protocol imap {
  process_limit = 512
}
```

**Правильно:**
```
protocol imap {
  mail_max_userip_connections = 10
}
service imap {
  process_limit = 512
}
```

---

## 6. rspamd — требует отдельного репозитория

rspamd **не входит** в стандартные репозитории Debian. Добавить официальный:

```bash
curl -s https://rspamd.com/apt-stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/rspamd.gpg
echo "deb [signed-by=/usr/share/keyrings/rspamd.gpg] https://rspamd.com/apt-stable/ $(lsb_release -cs) main" \
  > /etc/apt/sources.list.d/rspamd.list
apt-get update && apt-get install -y rspamd
```

---

## 7. Certbot standalone — Postfix не мешает порту 80

Postfix слушает порты 25/587/465. Останавливать его перед `certbot --standalone` **не нужно** — Certbot занимает только порт 80.

---

## 8. UFW — `systemctl is-active ufw` показывает inactive при работающем файрволле

UFW управляется через `ufw status`, а не через systemd. После `ufw --force enable` правила активны, даже если `systemctl status ufw` показывает `inactive (dead)`.

```bash
ufw status verbose    # правильная проверка
```

---

## 9. Hostname в промпте показывает короткое имя вместо FQDN

**Симптом:** если `/etc/hostname` содержит `mx.example.com`, в промпте будет `root@mx`.

**Причина:** `\h` в PS1 берёт часть до первой точки. `\H` — полный FQDN.

**Это нормально.** Postfix `myhostname = mx.example.com` в `main.cf` работает независимо от системного hostname.

Если нужен другой системный hostname — изменить через `hostnamectl set-hostname <NAME>`.
На cloud-серверах с cloud-init изменения в `/etc/hosts` нужно вносить в
`/etc/cloud/templates/hosts.debian.tmpl`, иначе перезапишутся после перезагрузки.

---

## 11. Dovecot — PAM перехватывает аутентификацию вместо passwd-file

**Симптом:** Пользователи из `/etc/dovecot/users` не могут залогиниться. В логах:
```
pam_unix(dovecot:auth): check pass; user unknown
pam_unix(dovecot:auth): authentication failure
```
`doveadm auth test user@domain.com password` возвращает `temp_fail`.

**Причина 1:** В `/etc/dovecot/conf.d/10-auth.conf` по умолчанию включён PAM и он стоит первым — перехватывает все запросы до того как Dovecot доходит до passwd-file.

**Исправление:** закомментировать PAM в `/etc/dovecot/conf.d/10-auth.conf`:
```
#!include auth-system.conf.ext   ← закомментировать эту строку
```

**Причина 2:** Файл `/etc/dovecot/users` недоступен процессу Dovecot из-за прав.

**Исправление:**
```bash
chown root:dovecot /etc/dovecot/users
chmod 640 /etc/dovecot/users
```

После обоих исправлений — перезапустить (не reload):
```bash
systemctl restart dovecot
doveadm auth test <USER>@<DOMAIN> '<PASSWORD>'   # должно вернуть auth succeeded
```

---

## 10. cloud-init перезаписывает `/etc/hosts` после перезагрузки

Если в `/etc/cloud/cloud.cfg` стоит `manage_etc_hosts: true`, правки `/etc/hosts` не сохраняются.

**Правильное место для изменений:**
```
/etc/cloud/templates/hosts.debian.tmpl
```
