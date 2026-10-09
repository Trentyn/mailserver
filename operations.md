# Operations Guide

Run every script as root from the repository directory: `sudo bash scripts/<name>`.

## Domains and mailboxes

```bash
sudo bash scripts/add-domain.sh        # prints the DNS records for the new domain
sudo bash scripts/add-mailbox.sh
sudo bash scripts/passwd-mailbox.sh
sudo bash scripts/delete-mailbox.sh    # permanent
sudo bash scripts/delete-domain.sh     # permanent, removes all its mailboxes
sudo bash scripts/status.sh            # services, certificate, mailboxes, queue, fail2ban
```

Mailboxes are Maildir directories under `/var/mail/vhosts/<domain>/<user>/` with the standard folders `Sent`, `Drafts`, `Trash`, `Junk` and `Archive`. Do not edit them by hand. Check space with `df -h /var/mail` and `sudo du -sh /var/mail/vhosts/<domain>/*`. Change the quota for all mailboxes with `sudo bash scripts/set-mailbox-quota.sh 10G`.

## Aliases and sending rights

```bash
sudo bash scripts/alias.sh add sales@example.com info@example.com      # repeat to add targets
sudo bash scripts/alias.sh add @example.com info@example.com           # catch-all
sudo bash scripts/alias.sh remove sales@example.com [info@example.com]
sudo bash scripts/alias.sh list
```

A mailbox may send only as addresses it owns: its own address (including `+tag` variants) and every alias that delivers to it. A catch-all grants no sending rights. Grant anything else explicitly; only hosted domains are allowed:

```bash
sudo bash scripts/send-as.sh grant bob@example.com ceo@example.com     # one address
sudo bash scripts/send-as.sh grant admin@example.com @example.com      # whole domain
sudo bash scripts/send-as.sh revoke bob@example.com ceo@example.com
sudo bash scripts/send-as.sh list [mailbox]
```

Webmail identities need a matching grant. Postfix checks the envelope sender; the `From:` header is not checked yet.

`/etc/postfix/sender_login_maps` and `/etc/postfix/virtual_mailboxes` are generated; do not edit them. After editing `/etc/postfix/virtual` by hand, run `sudo bash scripts/alias.sh sync`. Deleting a mailbox or domain removes it from alias target lists and prints aliases left without targets.

## Webmail on another server

A webmail server logs everyone in from one IP address, so a few wrong passwords would make fail2ban ban it and cut off webmail for all users. Exempt the address the webmail server connects *from*:

```bash
sudo bash scripts/trusted-client.sh add 203.0.113.7         # static IP
sudo bash scripts/trusted-client.sh add home.example.com    # DDNS hostname for a dynamic IP
sudo bash scripts/trusted-client.sh list
```

A webmail server behind a Cloudflare Tunnel still connects to IMAP and SMTP from its own internet connection. Protect the webmail login itself in the webmail application or at Cloudflare.

## Spam and Junk

Rspamd marks spam and Dovecot files it into `Junk`. Moving a message into `Junk` trains it as spam; moving it out of `Junk` trains it as legitimate. Moving it to `Trash` trains nothing.

`Trash` and `Junk` share one retention period. Other folders are never touched.

```bash
sudo bash scripts/cleanup-mailboxes.sh --days 30            # preview
sudo bash scripts/cleanup-mailboxes.sh --apply --days 30    # delete
sudo bash scripts/install-mail-cleanup-timer.sh 30          # daily timer
```

## Logs and queue

```bash
sudo journalctl -u postfix -f
sudo tail -f /var/log/dovecot.log
sudo tail -f /var/log/rspamd/rspamd.log
mailq
sudo postqueue -f
```

## Upgrading an older installation

After `git pull` on a server installed by an earlier version:

```bash
sudo bash scripts/upgrade.sh
```

It is idempotent and backs up what it changes. It closes port 80 outside certificate renewals, installs the fail2ban filter for Dovecot 2.4 (earlier versions never banned IMAP/POP3 password guessing), adds Dovecot log rotation, and creates the maps used by `alias.sh` and `send-as.sh`.

A server installed before Junk support also needs `sudo bash scripts/enable-junk-filtering.sh 30`. `create-setup-summary.sh` recreates the root-only setup summary.

## Tests

`tests/integration.sh` installs the server in a Debian container with systemd (a self-signed certificate replaces Let's Encrypt) and checks the install, mail flow, Junk, aliases, sending rights, the firewall, fail2ban and every script:

```bash
bash tests/integration.sh                           # Debian 13
DEBIAN_RELEASE=bookworm bash tests/integration.sh   # Debian 12
```

It needs Docker and internet access. CI runs ShellCheck and this test on Debian 13 for every push; run the Debian 12 test locally. Shared shell helpers are in `scripts/lib/`.
