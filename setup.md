# Installation Guide

Install only on a clean Debian 12 or Debian 13 VPS. If setup stops part-way, fix the reported problem and run it again; it resumes. A completed installation is never reinstalled over.

## Before you start

1. Create an A record for the chosen mail hostname, for example `mx.example.com`, pointing to the VPS IPv4 address.
2. Ensure the provider permits outbound TCP port 25 (setup warns if it is blocked).
3. Make sure nothing listens on port 80; certbot needs it to issue the certificate. After setup the firewall keeps port 80 closed except during certificate renewal.
4. Connect to the VPS using SSH and clone this repository.

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/Trentyn/mailserver.git
cd mailserver
sudo bash scripts/setup.sh
```

The installer asks for the FQDN, mail domain, DKIM selector, Let's Encrypt email, SSH port, first mailbox, mailbox quota, and Trash/Junk retention. If the A record does not resolve yet, it waits and lets you re-check instead of failing. It creates a root-only summary file under `/root/` containing DNS records and the first mailbox password.

## Firewall confirmation

The installer configures UFW on a clean server and schedules an automatic rollback. Open a second SSH session and confirm that login works before entering `SSH-OK`. If the three-minute rollback fires first, UFW is disabled and setup continues; re-enable it with `sudo ufw enable` once SSH access is confirmed. Do not use the installer to alter an already active UFW configuration.

## After installation

Add the printed A, MX, SPF, DKIM and DMARC records, configure the provider PTR record, wait for DNS propagation, then run:

```bash
sudo bash scripts/verify-mailserver.sh mx.example.com example.com mail2026
```

Only a result without failures confirms that local services, DNS, PTR and TLS are ready for production validation.
