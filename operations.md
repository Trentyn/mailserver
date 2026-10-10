# Operations Guide

Run every script as root from the repository directory: `sudo bash scripts/<name>`.

## Backups

Encrypted daily backups go to any S3-compatible storage (AWS S3, Backblaze B2, Wasabi, Hetzner Object Storage, MinIO) with restic. Create a bucket and an access key limited to it, then:

```bash
sudo bash scripts/backup.sh setup     # asks endpoint, bucket, folder (mail-backup), keys
```

Setup creates the repository, shows the **backup password once**, starts a daily backup at about 03:30 and makes the first one. Store the password outside the server: restoring onto a new server is impossible without it. The server keeps a root-only copy with the S3 keys in `/etc/mailserver/backup.env`.

Backed up: mail, mailboxes with their password hashes, aliases, send-as grants, DKIM keys, Postfix, Dovecot and Rspamd configuration, spam training, sending limits and trusted clients. Kept: 7 daily, 4 weekly and 12 monthly backups.

```bash
sudo bash scripts/backup.sh list                                   # backups and the last success
sudo bash scripts/backup.sh run                                    # back up now
sudo bash scripts/backup.sh restore-mailbox bob@example.com        # bring back deleted mail
sudo bash scripts/backup.sh restore-mailbox bob@example.com 1a2b3c4d   # from an older backup
sudo bash scripts/backup.sh check                                  # verify the backups are readable
```

`restore-mailbox` copies back only messages that are missing now; nothing is overwritten or duplicated.

**Restoring onto a new server** after losing the old one:

1. Create the new VPS and point the A record of the mail host name to it (the PTR too).
2. `git clone` this repository and run `sudo bash scripts/setup.sh` with the **same mail host name and domain**. The first mailbox and its password do not matter; the backup replaces them.
3. `sudo bash scripts/backup.sh restore`: it asks for the bucket, keys and backup password, then restores everything and resumes daily backups.
4. `sudo bash scripts/verify-mailserver.sh`. If the IP address changed, update the A and PTR records.

`status.sh` and `verify-mailserver.sh` warn when the last successful backup is older than 48 hours.

## Domains and mailboxes

```bash
sudo bash scripts/add-domain.sh        # prints the DNS records for the new domain
sudo bash scripts/add-mailbox.sh
sudo bash scripts/passwd-mailbox.sh    # Enter generates a strong password
sudo bash scripts/delete-mailbox.sh    # permanent
sudo bash scripts/delete-domain.sh     # permanent, removes all its mailboxes
sudo bash scripts/status.sh            # services, certificate, mailboxes, queue, fail2ban
```

Passwords are stored only as hashes. When you press Enter at the password prompt, the server generates a 20-character password and shows it once; a password you type is never shown. Nothing writes a password to a file or log.

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

The same rights apply to the envelope sender (checked by Postfix) and to the `From:` header that recipients see (checked by Rspamd): a mailbox cannot show another person's address, even of its own domain. Webmail identities need a matching grant. After a change, Rspamd picks up the new rights within a few seconds.

`/etc/postfix/sender_login_maps` and `/etc/postfix/virtual_mailboxes` are generated; do not edit them. After editing `/etc/postfix/virtual` by hand, run `sudo bash scripts/alias.sh sync`. Deleting a mailbox or domain removes it from alias target lists and prints aliases left without targets.

## Sending limits

Each mailbox may send to 100 recipients per hour and 500 per day, so a stolen password cannot be used to send spam and get the server's IP address blocklisted. A message to five people counts as five, and one message may not have more recipients than the hourly limit. Over the limit the server answers with a temporary error ("Sending limit of 100 recipients per hour reached, try again later") and the mail client reports that it could not send. Inbound mail is never limited.

```bash
sudo bash scripts/send-limit.sh show                        # limits, exempt mailboxes, recent hits
sudo bash scripts/send-limit.sh set 200 1000                # per hour, per day
sudo bash scripts/send-limit.sh exempt news@example.com     # no limit for one mailbox
sudo bash scripts/send-limit.sh unexempt news@example.com
sudo bash scripts/send-limit.sh off
```

A mailbox you did not expect in the recent hits may have a stolen password: change it with `passwd-mailbox.sh`.

## POP3

POP3 is off unless it was enabled during setup. IMAP keeps mail on the server and in sync on every device; only old clients need POP3.

```bash
sudo bash scripts/pop3.sh status
sudo bash scripts/pop3.sh on     # opens ports 110 and 995
sudo bash scripts/pop3.sh off
```

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

## Updates

Debian security and stable updates install automatically every day (`unattended-upgrades`), and `needrestart` restarts the services that still use a replaced library. A new kernel needs a reboot, which `status.sh` reports; reboot at a quiet time with `sudo reboot`. The log is `/var/log/unattended-upgrades/`.

Dovecot and Rspamd come from their own repositories and are not updated automatically, because their releases can change configuration. Update them by hand and check the result:

```bash
sudo apt update && sudo apt upgrade
sudo doveconf -n >/dev/null && sudo rspamadm configtest && sudo bash scripts/verify-mailserver.sh
```

## Upgrading an older installation

After `git pull` on a server installed by an earlier version:

```bash
sudo bash scripts/upgrade.sh
```

It is idempotent and backs up what it changes. It closes port 80 outside certificate renewals, installs the fail2ban filter for Dovecot 2.4 (earlier versions never banned IMAP/POP3 password guessing), adds Dovecot log rotation, creates the maps used by `alias.sh` and `send-as.sh`, sets the default sending limits and turns on automatic security updates.

A server installed before Junk support also needs `sudo bash scripts/enable-junk-filtering.sh 30`. `create-setup-summary.sh` recreates the root-only setup summary.

## Tests

`tests/integration.sh` installs the server in a Debian container with systemd (a self-signed certificate replaces Let's Encrypt) and checks the install, mail flow, Junk, aliases, sending rights, the firewall, fail2ban and every script:

```bash
bash tests/integration.sh                           # Debian 13
DEBIAN_RELEASE=bookworm bash tests/integration.sh   # Debian 12
```

It needs Docker and internet access. CI runs ShellCheck and this test on Debian 13 for every push; run the Debian 12 test locally. Shared shell helpers are in `scripts/lib/`.
