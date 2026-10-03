# Mail Server

A production-oriented self-hosted mail server for Debian 12 and 13.

Postfix provides SMTP, Dovecot CE 2.4 provides IMAP, POP3 and LMTP, rspamd provides spam filtering and DKIM, and Let's Encrypt provides TLS certificates.

## Requirements

- A clean Debian 12 or Debian 13 VPS with root access.
- An A record for the mail hostname, such as `mx.example.com`, pointing to the VPS before setup.
- Ports 25, 80, 110, 143, 465, 587, 993 and 995 available.
- Provider support for outbound TCP port 25. Many cloud providers block it by default.

## Install

Run only on a clean server:

```bash
sudo bash scripts/setup.sh
```

The installer asks for the mail hostname, mail domain, DKIM selector, Let's Encrypt notification email, SSH port, first mailbox, and Trash retention period. Use `0` to disable automatic Trash cleanup. It creates a root-only setup summary at `/root/mailserver-setup-<domain>-<timestamp>.txt`.

Do not run `setup.sh` again on an existing mail server. Use the maintenance scripts below.

## Scripts

| Script | Purpose |
|---|---|
| `setup.sh` | Full installation on a clean server |
| `add-domain.sh` | Add a mail domain |
| `add-mailbox.sh` | Create a mailbox |
| `passwd-mailbox.sh` | Change a mailbox password |
| `delete-mailbox.sh` | Permanently delete a mailbox |
| `delete-domain.sh` | Permanently delete a domain and its mailboxes |
| `status.sh` | Inspect services, mailboxes, queue and fail2ban |
| `verify-mailserver.sh` | Validate services, TLS and DNS |
| `create-setup-summary.sh` | Recreate the root-only setup summary |
| `set-mailbox-quota.sh` | Set the global storage quota for existing mailboxes |
| `cleanup-mailboxes.sh` | Preview or remove old Trash messages |
| `install-mail-cleanup-timer.sh` | Install daily automated Trash cleanup |

## DNS records

For every mail domain configure:

| Type | Name | Value |
|---|---|---|
| A | `mx.example.com` | VPS IPv4 address |
| MX | `@` | `10 mx.example.com.` |
| TXT | `@` | `v=spf1 mx ~all` |
| TXT | `<selector>._domainkey` | DKIM value printed by the script |
| TXT | `_dmarc` | `v=DMARC1; p=quarantine; rua=mailto:postmaster@example.com` |
| PTR | VPS IP | `mx.example.com.` |

Do not paste DNS zone syntax such as `IN TXT`, parentheses, or outer quotation marks into a DNS control panel. Paste only the TXT value.

## Verify production readiness

After DNS has propagated, run:

```bash
sudo bash scripts/verify-mailserver.sh mx.example.com example.com mail2026
```

The command is read-only. It checks local services, configuration, A, MX, SPF, DKIM, DMARC, PTR, and IMAPS TLS.

## Mail client settings

Use the full email address as the login for incoming and outgoing mail.

| Service | Port | Security |
|---|---:|---|
| IMAP | 993 | SSL/TLS |
| POP3 | 995 | SSL/TLS |
| SMTP | 465 | SSL/TLS |
| SMTP | 587 | STARTTLS |

## Storage and monitoring

Every mailbox has a Dovecot-enforced 5 GiB storage quota. Mailboxes are Maildir directories under:

```text
/var/mail/vhosts/<domain>/<user>/
```

Check free space and mailbox sizes:

```bash
df -h /var/mail
sudo du -sh /var/mail/vhosts/<domain>/*
```

## Trash retention

The cleanup scripts never touch Inbox, Sent, Drafts, or any other mailbox. They remove messages whose internal delivery date is older than the selected age from `Trash` only. Gmail may display this IMAP mailbox as `Bin`.

Preview the result first:

```bash
sudo bash scripts/cleanup-mailboxes.sh --days 30
```

Run a one-off cleanup after reviewing the preview:

```bash
sudo bash scripts/cleanup-mailboxes.sh --apply --days 30
```

For an existing server, install or change the daily systemd timer:

```bash
sudo bash scripts/install-mail-cleanup-timer.sh 30
systemctl list-timers mailserver-mail-cleanup.timer --all
```

Use `90` instead of `30` if you want to retain Trash for ninety days. The timer has a randomized delay of up to twenty minutes and continues missed runs after a reboot.

## Stack and updates

The installer runs `apt update` and `apt upgrade`, uses the official Dovecot CE 2.4 and rspamd repositories, and uses Debian packages for Postfix, Certbot, Redis and fail2ban. After major package updates, run `postfix check`, `doveconf -n`, `rspamadm configtest`, and the verification script.

## Firewall

On a clean server, setup configures UFW with an automatic three-minute rollback. Before confirming `SSH-OK`, open a separate terminal and verify that SSH access works. If UFW is already active, setup stops without changing its rules.
