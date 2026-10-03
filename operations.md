# Operations Guide

Run maintenance scripts as root from the repository directory.

```bash
sudo bash scripts/status.sh
sudo bash scripts/add-domain.sh
sudo bash scripts/add-mailbox.sh
sudo bash scripts/passwd-mailbox.sh
sudo bash scripts/delete-mailbox.sh
sudo bash scripts/delete-domain.sh
```

## Logs and queue

```bash
sudo journalctl -u postfix -f
sudo journalctl -u dovecot -f
sudo tail -f /var/log/dovecot.log
mailq
sudo postqueue -f
```

## Mail storage

Mailboxes use Maildir storage at `/var/mail/vhosts/<domain>/<user>/`. Check capacity with:

```bash
df -h /var/mail
sudo du -sh /var/mail/vhosts/<domain>/*
```

Do not edit Maildir files manually. Use an IMAP client or the provided scripts.

## Validation

```bash
sudo bash scripts/verify-mailserver.sh <mail-hostname> <mail-domain> <dkim-selector>
```

The verifier is read-only and checks services, configuration, public DNS, PTR and TLS.