# Installation Guide

Install only on a clean Debian 12 or 13 VPS. If setup stops part-way, fix the reported problem and run it again; it resumes. A completed installation is never reinstalled over.

## Before you start

1. Create an A record for the mail hostname, for example `mx.example.com`, pointing to the VPS IPv4 address.
2. Ensure the provider permits outbound TCP port 25 (setup warns if it is blocked).
3. Make sure nothing listens on port 80; certbot needs it to issue the certificate.
4. Connect to the VPS over SSH and clone this repository.

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/Trentyn/mailserver.git
cd mailserver
sudo bash scripts/setup.sh
```

## Installation without questions

For cloud-init, Ansible or any other automation, put the answers in a file and run setup with it. Nothing is asked; the file is read, not executed. [setup.conf.example](setup.conf.example) lists every setting.

```bash
cp setup.conf.example /root/setup.conf && chmod 600 /root/setup.conf   # then edit it
sudo bash scripts/setup.sh --config /root/setup.conf
```

The same names work as environment variables, which win over the file: `sudo MAIL_HOSTNAME=mx.example.com LETSENCRYPT_EMAIL=admin@example.com bash scripts/setup.sh --non-interactive`. Only `MAIL_HOSTNAME` and `LETSENCRYPT_EMAIL` are required.

Differences from an interactive run:

- Setup waits up to `DNS_WAIT` seconds (default 900) for the A record, then tries anyway.
- There is nobody to confirm SSH access, so UFW is enabled without the rollback timer. Setup refuses an `SSH_PORT` that sshd does not listen on.
- The first mailbox takes `FIRST_PASSWORD` or a ready hash in `FIRST_PASSWORD_HASH` (`doveadm pw -s SHA512-CRYPT`). With neither it gets a random password that is never shown, so no password ends up in cloud-init or Ansible logs; set one with `passwd-mailbox.sh`.
- Backups are set up when `BACKUP_S3_BUCKET` and the keys are given. A generated backup password is not printed; it is in `/etc/mailserver/backup.env`.

A cloud-init example (the A record must point to the new server's IP first):

```yaml
#cloud-config
write_files:
  - path: /root/setup.conf
    permissions: '0600'
    content: |
      MAIL_HOSTNAME=mx.example.com
      LETSENCRYPT_EMAIL=admin@example.com
runcmd:
  - apt-get update && apt-get install -y git
  - git clone https://github.com/Trentyn/mailserver.git /root/mailserver
  - bash /root/mailserver/scripts/setup.sh --config /root/setup.conf
```

## What setup asks and checks

It asks for the mail hostname, mailbox domain, DKIM selector, Let's Encrypt email, SSH port (detected from sshd), first mailbox and password, mailbox quota (default 5G), how many days to keep Trash and Junk mail (`0` disables cleanup) and whether to enable POP3 (default no). Invalid answers are asked again.

Before changing anything it checks the Debian release, that port 80 is free, and that UFW is not already active. It waits for the A record instead of failing and warns if outbound port 25 is blocked. The certificate is issued before any mail configuration is written, so a certbot failure leaves a state that `setup.sh` can resume.

`postmaster@` and `abuse@` become aliases of the first mailbox; DMARC reports go to `postmaster@`. Press Enter at the password prompt to have a strong password generated; it is shown once at the end. A root-only summary with the DNS records (no password) is written to `/root/mailserver-setup-<domain>-<timestamp>.txt`.

Setup also turns on automatic Debian security updates and limits each mailbox to 100 recipients per hour and 500 per day; see [operations.md](operations.md) to change either.

## Firewall

UFW allows SSH, SMTP (25, 465, 587) and IMAP (143, 993), and POP3 (110, 995) when it is enabled. Port 80 stays closed; certbot hooks open it only while a renewal runs, and leave a port 80 rule you add yourself untouched.

Setup enables UFW with an automatic three-minute rollback. Open a second SSH session and confirm that login works before typing `SSH-OK`. If the rollback fires first, setup still finishes; re-enable the firewall with `sudo ufw enable` once SSH access is confirmed.

## After installation

Add the printed A, MX, SPF, DKIM and DMARC records, set the PTR record at the VPS provider, wait for DNS propagation, then run:

```bash
sudo bash scripts/verify-mailserver.sh
```

It is read-only and checks services, configuration, A, MX, SPF, DKIM, DMARC, PTR and the IMAPS certificate. Arguments (`<hostname> <domain> <selector>`) are optional. Only a result without failures means the server is ready.

At the end, setup offers to set up encrypted daily backups to S3-compatible storage; have a bucket and an access key ready. If you skip it, set them up later with `sudo bash scripts/backup.sh setup` (see [operations.md](operations.md#backups)); `verify-mailserver.sh` warns until you do.

In a DNS control panel, paste only the TXT value: no `IN TXT`, parentheses or outer quotes.

## Stack

Postfix, Certbot, Redis and fail2ban come from Debian and update automatically; Dovecot CE 2.4 and Rspamd come from their official repositories and are updated by hand. Setup runs `apt upgrade` first. After major package updates, run `postfix check`, `doveconf -n`, `rspamadm configtest` and `verify-mailserver.sh`.
