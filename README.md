# Mail Server

A production-oriented self-hosted mail server for Debian 12 and 13.

Postfix provides SMTP, Dovecot CE 2.4 provides IMAP, POP3 and LMTP, rspamd provides spam filtering and DKIM, and Let's Encrypt provides TLS certificates.

## Requirements

- A clean Debian 12 or Debian 13 VPS with root access.
- An A record for the mail hostname, such as `mx.example.com`, pointing to the VPS before setup.
- Ports 25, 80, 110, 143, 465, 587, 993 and 995 available. Port 80 is used only to issue and renew the certificate; the firewall keeps it closed otherwise.
- Provider support for outbound TCP port 25. Many cloud providers block it by default.

## Install

Run only on a clean server:

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/Trentyn/mailserver.git
cd mailserver
sudo bash scripts/setup.sh
```

The installer asks for the mail hostname, mail domain, DKIM selector, Let's Encrypt notification email, SSH port, first mailbox, mailbox quota, and one Trash and Junk retention period (`0` disables automatic cleanup). Invalid answers are asked again instead of aborting. It creates a root-only setup summary at `/root/mailserver-setup-<domain>-<timestamp>.txt`.

Before changing anything, setup checks the Debian release, that port 80 is free for Let's Encrypt, and that UFW is not already active. It waits for the A record instead of failing, and warns if outbound port 25 is blocked.

If setup stops part-way, for example because the certificate could not be issued yet, fix the cause and run `setup.sh` again: it resumes an unfinished installation. After a successful installation it refuses to run again; use the maintenance scripts below.

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
| `cleanup-mailboxes.sh` | Preview or remove old Trash and Junk messages |
| `install-mail-cleanup-timer.sh` | Install daily automated Trash and Junk cleanup |
| `enable-junk-filtering.sh` | Add Junk delivery and Bayes training to an installation made before Junk support |
| `install-renewal-hooks.sh` | Close port 80 on an older installation and open it only during certificate renewal |

## DNS records

For every mail domain configure:

| Type | Name | Value |
|---|---|---|
| A | `mx.example.com` | VPS IPv4 address |
| MX | `@` | `10 mx.example.com.` |
| TXT | `@` | `v=spf1 mx ~all` |
| TXT | `<selector>._domainkey` | DKIM value printed by the script |
| TXT | `_dmarc` | `v=DMARC1; p=quarantine; rua=mailto:postmaster@example.com` |

`postmaster@` and `abuse@` are aliases of the first mailbox (setup) or of a mailbox chosen in `add-domain.sh`. They live in `/etc/postfix/virtual`; run `postmap /etc/postfix/virtual` after editing it by hand.
| PTR | VPS IP | `mx.example.com.` |

Do not paste DNS zone syntax such as `IN TXT`, parentheses, or outer quotation marks into a DNS control panel. Paste only the TXT value.

## Verify production readiness

After DNS has propagated, run:

```bash
sudo bash scripts/verify-mailserver.sh mx.example.com example.com mail2026
```

All arguments are optional; without them the script uses the configured hostname, the first domain, and its DKIM selector. The command is read-only. It checks local services, configuration, A, MX, SPF, DKIM, DMARC, PTR, and IMAPS TLS.

## Mail client settings

Use the full email address as the login for incoming and outgoing mail.

| Service | Port | Security |
|---|---:|---|
| IMAP | 993 | SSL/TLS |
| POP3 | 995 | SSL/TLS |
| SMTP | 465 | SSL/TLS |
| SMTP | 587 | STARTTLS |

The server exposes the standard IMAP system mailboxes `Sent`, `Drafts`, `Trash`, `Junk`, and `Archive` with their correct special-use attributes. `INBOX` is the protocol-reserved name and may be displayed in uppercase by clients.

## Storage and monitoring

Every mailbox has a Dovecot-enforced storage quota chosen during setup (5 GiB by default). Change it with `sudo bash scripts/set-mailbox-quota.sh 10G`. Mailboxes are Maildir directories under:

```text
/var/mail/vhosts/<domain>/<user>/
```

Check free space and mailbox sizes:

```bash
df -h /var/mail
sudo du -sh /var/mail/vhosts/<domain>/*
```

## Trash and Junk retention

The cleanup scripts never touch Inbox, Sent, Drafts, or any other mailbox. They remove messages whose internal delivery date is older than the selected age from `Trash` and `Junk`. Gmail may display `Trash` as `Bin`.

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

Trash and Junk always share the same retention period. The timer has a randomized delay of up to twenty minutes and continues missed runs after a reboot.

## Junk handling

Rspamd marks inbound spam and Dovecot files it into the standard IMAP `Junk` mailbox. Moving a message into `Junk` teaches Rspamd it is spam; moving it from `Junk` to another mailbox teaches Rspamd it is legitimate mail. Moving mail from `Junk` to `Trash` is deliberately not a ham report. Gmail may not expose `Junk` for external IMAP accounts; Roundcube and standard IMAP clients do.

## Stack and updates

The installer runs `apt update` and `apt upgrade`, uses the official Dovecot CE 2.4 and rspamd repositories, and uses Debian packages for Postfix, Certbot, Redis and fail2ban. After major package updates, run `postfix check`, `doveconf -n`, `rspamadm configtest`, and the verification script.

## Firewall

UFW allows SSH, SMTP (25, 465, 587), IMAP (143, 993) and POP3 (110, 995). Port 80 stays closed: certbot renewal hooks open it while a renewal runs and close it afterwards. A port 80 rule you add yourself, for example for a web server, is left untouched. Servers installed before this change can switch with `sudo bash scripts/install-renewal-hooks.sh`.

On a clean server, setup configures UFW with an automatic three-minute rollback. Before confirming `SSH-OK`, open a separate terminal and verify that SSH access works. If the rollback fires first, setup still finishes and tells you how to re-enable UFW. If UFW is already active, setup stops before changing anything.

## Add Junk handling to an existing server

New installations already include Junk handling. For a server installed before it was added, pull the current repository and run:

```bash
sudo bash scripts/enable-junk-filtering.sh 30
```

The command makes a root-only configuration backup before changing services.

## Development and tests

Shared shell helpers live in `scripts/lib/`. `tests/integration.sh` installs the server in a Debian container with systemd (a self-signed certificate replaces Let's Encrypt), then checks mail flow, Junk handling, the firewall and renewal hooks, and every maintenance script:

```bash
bash tests/integration.sh                           # Debian 13
DEBIAN_RELEASE=bookworm bash tests/integration.sh   # Debian 12
```

It needs Docker and internet access and takes a few minutes. CI runs ShellCheck and the integration test on Debian 12 and 13 for every push.
