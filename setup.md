# Installation Guide

Install only on a clean Debian 12 or Debian 13 VPS. Do not rerun `setup.sh` on an existing mail server.

## Before you start

1. Create an A record for the chosen mail hostname, for example `mx.example.com`, pointing to the VPS IPv4 address.
2. Ensure the provider permits outbound TCP port 25.
3. Connect to the VPS using SSH and clone this repository.

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/Trentyn/mailserver.git
cd mailserver
sudo bash scripts/setup.sh
```

The installer asks for the FQDN, base domain, DKIM selector, Let's Encrypt email, SSH port, and first mailbox. It creates a root-only summary file under `/root/` containing DNS records and the first mailbox password.

## Firewall confirmation

The installer configures UFW on a clean server and schedules an automatic rollback. Open a second SSH session and confirm that login works before entering `SSH-OK`. Do not use the installer to alter an already active UFW configuration.

## After installation

Add the printed A, MX, SPF, DKIM and DMARC records, configure the provider PTR record, wait for DNS propagation, then run:

```bash
sudo bash scripts/verify-mailserver.sh mx.example.com example.com mail2026
```

Only an all-pass result confirms that local services, DNS, PTR and TLS are ready for production validation.