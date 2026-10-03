# Mail Server Configuration Template

Copy this file outside the repository and fill in your own values. Do not commit real domains, IP addresses, mailbox names, passwords, or personal email addresses.

> **For AI agents:** Read the private configuration supplied by the owner before performing work. Placeholder values such as `example.com`, `203.0.113.10`, `admin@example.com`, `mail2026`, or empty cells are not real values. Ask for a missing required value; never guess.

## Server

| Variable | Value |
|---|---|
| `MAIL_HOSTNAME` | `mx.example.com` |
| `SERVER_IP` | `203.0.113.10` |
| `BASE_DOMAIN` | `example.com` |

## Domains and DKIM

| Domain | DKIM selector |
|---|---|
| `example.com` | `mail2026` |

## Mailboxes

| Email | Purpose |
|---|---|
| `contact@example.com` | Public website address |
| `ops@example.com` | Operations and administration |

## Certificates

| Variable | Value |
|---|---|
| `LETSENCRYPT_EMAIL` | `admin@example.com` |