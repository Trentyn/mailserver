# Known Issues: Debian 13 and Dovecot 2.4

## Dovecot 2.4 configuration changes

Dovecot 2.4 no longer accepts `mail_location`. Use separate settings:

```text
mail_driver = maildir
mail_home = /var/mail/vhosts/%{user|domain}/%{user|username}
mail_path = /var/mail/vhosts/%{user|domain}/%{user|username}
mail_inbox_path =
```

Use `%{user|domain}` and `%{user|username}` instead of `%d` and `%n`.

TLS settings use:

```text
ssl_server_cert_file = /path/to/fullchain.pem
ssl_server_key_file = /path/to/privkey.pem
```

Passdb and userdb blocks require names in Dovecot 2.4:

```text
passdb passwd-file { }
userdb static { }
```

## Authentication

Dovecot's Debian defaults can enable PAM/system users ahead of virtual mailboxes. The setup script disables `passdb pam` and `userdb passwd` in `/etc/dovecot/conf.d/10-auth.conf`. Confirm with:

```bash
sudo doveconf -n | grep -E 'passdb pam|userdb passwd' || echo 'OK: PAM is disabled'
```

The virtual users file must be readable by Dovecot:

```bash
sudo chown root:dovecot /etc/dovecot/users
sudo chmod 640 /etc/dovecot/users
```

## Maildir inbox path

Debian can set `mail_inbox_path = /var/mail/%{user}` for system users. Virtual Maildir must override it with an empty `mail_inbox_path =`; otherwise delivery fails with `Failed to autocreate mailbox: Permission denied`.

## Dovecot CE updates

A package update can replace `/etc/dovecot/dovecot.conf`. Ensure it still contains:

```text
!include_try local.conf
```

Then run `doveconf -n` and restart Dovecot.

## cloud-init hostname files

With `manage_etc_hosts: true`, cloud-init can rewrite `/etc/hosts`. Update `/etc/cloud/templates/hosts.debian.tmpl` when persistent host mappings are required.
