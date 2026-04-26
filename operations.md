# Mail Server Operations — Управление доменами и ящиками

Этот файл — для работы с уже установленным сервером.
Переменные (`<VAR>`) — из таблицы в `README.md`.

---

## Добавить новый домен

### 1. Postfix — добавить домен в `virtual_mailbox_domains`

В `/etc/postfix/main.cf`:
```
virtual_mailbox_domains = <EXISTING_DOMAIN>, <NEW_DOMAIN>
```

### 2. rspamd — DKIM ключ для нового домена

```bash
rspamadm dkim_keygen -s <DKIM_SELECTOR> -d <NEW_DOMAIN> \
  -k /var/lib/rspamd/dkim/<NEW_DOMAIN>.<DKIM_SELECTOR>.key \
  > /var/lib/rspamd/dkim/<NEW_DOMAIN>.<DKIM_SELECTOR>.pub
chown _rspamd:_rspamd /var/lib/rspamd/dkim/<NEW_DOMAIN>.<DKIM_SELECTOR>.*
chmod 440 /var/lib/rspamd/dkim/<NEW_DOMAIN>.<DKIM_SELECTOR>.key
```

Добавить в `/etc/rspamd/dkim_selectors.map`:
```
<NEW_DOMAIN>    <DKIM_SELECTOR>
```

### 3. DNS для нового домена

| Тип | Имя | Значение |
|-----|-----|---------|
| MX  | `@` | `10 <MAIL_HOSTNAME>` |
| TXT | `@` | `v=spf1 mx ~all` |
| TXT | `<DKIM_SELECTOR>._domainkey` | содержимое `<NEW_DOMAIN>.<DKIM_SELECTOR>.pub` |
| TXT | `_dmarc` | `v=DMARC1; p=quarantine; rua=mailto:dmarc@<NEW_DOMAIN>` |

### 4. Перезагрузить

```bash
systemctl reload postfix rspamd
```

---

## Добавить ящик

```bash
# 1. Хеш пароля
doveadm pw -s SHA512-CRYPT -p "<PASSWORD>"

# 2. Добавить в /etc/dovecot/users
echo "<USER>@<MAIL_DOMAIN>:{SHA512-CRYPT}<HASH>" >> /etc/dovecot/users

# 3. Добавить в /etc/postfix/vmailbox
echo "<USER>@<MAIL_DOMAIN>    <MAIL_DOMAIN>/<USER>/" >> /etc/postfix/vmailbox
postmap /etc/postfix/vmailbox

# 4. Создать Maildir
mkdir -p /var/mail/vhosts/<MAIL_DOMAIN>/<USER>/{cur,new,tmp}
chown -R vmail:vmail /var/mail/vhosts/<MAIL_DOMAIN>/<USER>
chmod -R 700 /var/mail/vhosts/<MAIL_DOMAIN>/<USER>

# 5. Перезагрузить
systemctl reload postfix dovecot
```

---

## Изменить пароль ящика

```bash
# Генерировать новый хеш
doveadm pw -s SHA512-CRYPT -p "<NEW_PASSWORD>"

# Заменить строку в /etc/dovecot/users
# Найти строку с нужным адресом и заменить хеш
```

---

## Удалить ящик

```bash
# 1. Удалить из /etc/dovecot/users
sed -i '/^<USER>@<MAIL_DOMAIN>:/d' /etc/dovecot/users

# 2. Удалить из /etc/postfix/vmailbox
sed -i '/^<USER>@<MAIL_DOMAIN>/d' /etc/postfix/vmailbox
postmap /etc/postfix/vmailbox

# 3. Удалить данные (необратимо — убедись что нужно)
rm -rf /var/mail/vhosts/<MAIL_DOMAIN>/<USER>

# 4. Перезагрузить
systemctl reload postfix dovecot
```

---

## Удалить домен

```bash
# 1. Убрать домен из virtual_mailbox_domains в /etc/postfix/main.cf

# 2. Удалить все ящики домена из /etc/dovecot/users
sed -i '/@<MAIL_DOMAIN>:/d' /etc/dovecot/users

# 3. Удалить все ящики домена из /etc/postfix/vmailbox
sed -i '/@<MAIL_DOMAIN>/d' /etc/postfix/vmailbox
postmap /etc/postfix/vmailbox

# 4. Удалить из dkim_selectors.map
sed -i '/^<MAIL_DOMAIN>/d' /etc/rspamd/dkim_selectors.map

# 5. Удалить данные (необратимо)
rm -rf /var/mail/vhosts/<MAIL_DOMAIN>
rm -f /var/lib/rspamd/dkim/<MAIL_DOMAIN>.*

# 6. Перезагрузить
systemctl reload postfix dovecot rspamd
```

---

## Просмотр текущих доменов и ящиков

```bash
# Домены в Postfix
postconf virtual_mailbox_domains

# Все ящики
cat /etc/postfix/vmailbox

# Все пользователи Dovecot (без паролей)
cut -d: -f1 /etc/dovecot/users

# Размер ящика
du -sh /var/mail/vhosts/<MAIL_DOMAIN>/<USER>

# Все ящики с размерами
du -sh /var/mail/vhosts/*/*
```

---

## Обновить TLS сертификат вручную

```bash
certbot renew --force-renewal
# Хук /etc/letsencrypt/renewal-hooks/deploy/reload-mail.sh
# перезагрузит postfix/dovecot/rspamd автоматически
```

---

## Проверить DKIM подпись

```bash
# Просмотр публичного ключа для DNS
cat /var/lib/rspamd/dkim/<MAIL_DOMAIN>.<DKIM_SELECTOR>.pub

# Тест через rspamd
rspamadm dkim_keygen -s <DKIM_SELECTOR> -d <MAIL_DOMAIN> --check
```

---

## Разблокировать IP в fail2ban

```bash
fail2ban-client status               # список jail-ов
fail2ban-client status postfix-sasl  # заблокированные IP
fail2ban-client set postfix-sasl unbanip <IP>
```

---

## Очистить очередь Postfix

```bash
mailq                        # посмотреть очередь
postsuper -d ALL deferred    # удалить все deferred письма
postsuper -d ALL             # удалить все письма (осторожно)
```
