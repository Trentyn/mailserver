# Mail Server

Self-hosted mail server for a clean Debian 12 or 13 VPS, installed by one interactive script: Postfix, Dovecot CE 2.4, Rspamd with DKIM, Junk training and per-mailbox sending limits, Let's Encrypt, fail2ban, UFW and automatic security updates.

## Requirements

- A clean Debian 12 or 13 VPS with root or sudo access.
- An A record for the mail hostname (for example `mx.example.com`) pointing to the VPS.
- Outbound port 25 allowed by the provider; many block it by default.

## Install

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/Trentyn/mailserver.git
cd mailserver
sudo bash scripts/setup.sh
```

The installer asks a few questions, waits for DNS, offers encrypted backups to S3, and can be re-run if it stops part-way. Details: [setup.md](setup.md).

## DNS records

Setup prints the exact values. For every mail domain:

| Type | Name | Value |
|---|---|---|
| A | `mx.example.com` | VPS IPv4 address |
| MX | `@` | `10 mx.example.com.` |
| TXT | `@` | `v=spf1 mx ~all` |
| TXT | `<selector>._domainkey` | DKIM value printed by setup |
| TXT | `_dmarc` | `v=DMARC1; p=quarantine; rua=mailto:postmaster@example.com` |
| PTR | VPS IP (set at the provider) | `mx.example.com.` |

Then check everything: `sudo bash scripts/verify-mailserver.sh`

## Mail clients

Log in with the full email address.

| Service | Port | Security |
|---|---:|---|
| IMAP | 993 | SSL/TLS |
| SMTP | 465 | SSL/TLS |
| SMTP | 587 | STARTTLS |
| POP3 | 995 | SSL/TLS |

## Scripts

All scripts are in `scripts/` and run with `sudo bash scripts/<name>`.

| Task | Scripts |
|---|---|
| Domains and mailboxes | `add-domain.sh`, `add-mailbox.sh`, `passwd-mailbox.sh`, `delete-mailbox.sh`, `delete-domain.sh` |
| Aliases and sending rights | `alias.sh`, `send-as.sh`, `send-limit.sh` |
| Webmail on another server | `trusted-client.sh` |
| Backups to S3 | `backup.sh` |
| Status and checks | `status.sh`, `verify-mailserver.sh` |
| Quota and cleanup | `set-mailbox-quota.sh`, `cleanup-mailboxes.sh`, `install-mail-cleanup-timer.sh` |
| Older installations | `upgrade.sh`, `enable-junk-filtering.sh`, `create-setup-summary.sh` |

Usage of each script: [operations.md](operations.md).

## More

- [setup.md](setup.md): installation, firewall, what setup checks
- [operations.md](operations.md): backups and restore, daily administration, aliases, webmail, upgrades, tests
- [known-issues.md](known-issues.md): Dovecot 2.4 and Debian 13 notes
- [TODO.md](TODO.md): planned work
