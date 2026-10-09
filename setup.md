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

## What setup asks and checks

It asks for the mail hostname, mailbox domain, DKIM selector, Let's Encrypt email, SSH port (detected from sshd), first mailbox and password, mailbox quota (default 5G), and how many days to keep Trash and Junk mail (`0` disables cleanup). Invalid answers are asked again.

Before changing anything it checks the Debian release, that port 80 is free, and that UFW is not already active. It waits for the A record instead of failing and warns if outbound port 25 is blocked. The certificate is issued before any mail configuration is written, so a certbot failure leaves a state that `setup.sh` can resume.

`postmaster@` and `abuse@` become aliases of the first mailbox; DMARC reports go to `postmaster@`. A root-only summary with the DNS records and the first password is written to `/root/mailserver-setup-<domain>-<timestamp>.txt`; store the password and delete the file.

## Firewall

UFW allows SSH, SMTP (25, 465, 587), IMAP (143, 993) and POP3 (110, 995). Port 80 stays closed; certbot hooks open it only while a renewal runs, and leave a port 80 rule you add yourself untouched.

Setup enables UFW with an automatic three-minute rollback. Open a second SSH session and confirm that login works before typing `SSH-OK`. If the rollback fires first, setup still finishes; re-enable the firewall with `sudo ufw enable` once SSH access is confirmed.

## After installation

Add the printed A, MX, SPF, DKIM and DMARC records, set the PTR record at the VPS provider, wait for DNS propagation, then run:

```bash
sudo bash scripts/verify-mailserver.sh
```

It is read-only and checks services, configuration, A, MX, SPF, DKIM, DMARC, PTR and the IMAPS certificate. Arguments (`<hostname> <domain> <selector>`) are optional. Only a result without failures means the server is ready.

In a DNS control panel, paste only the TXT value: no `IN TXT`, parentheses or outer quotes.

## Stack

Postfix, Certbot, Redis and fail2ban come from Debian; Dovecot CE 2.4 and Rspamd from their official repositories. Setup runs `apt upgrade` first. After major package updates, run `postfix check`, `doveconf -n`, `rspamadm configtest` and `verify-mailserver.sh`.
