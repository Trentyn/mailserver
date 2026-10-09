# TODO

Open work for running this mail server for a team or organization. Numbers
match the planning list, so done items leave gaps.

## Important

- [ ] **5. Backups and restore.** Back up Maildirs, DKIM keys and configs
  (restic or borg to off-site storage) and document a tested restore.
  Without it, losing the VPS loses all mail.
- [ ] **7. Monitoring and alerts.** Stopped services, certificate expiry,
  growing queue, low disk space, IP on blocklists; alert by email or Telegram.
- [ ] **9. Non-interactive install.** Read answers from a config file or
  environment variables for cloud-init and Ansible.

## User experience

- [ ] **10. ManageSieve (port 4190).** User filters and vacation replies,
  usable from SnappyMail.
- [ ] **11. Mail client autoconfiguration.** Thunderbird autoconfig, Outlook
  autodiscover, iOS profile. Plan:
  - print SRV records (`_imaps._tcp`, `_submissions._tcp`, `_submission._tcp`)
    in `setup.sh` and `add-domain.sh`;
  - a script that generates `config-v1.1.xml` (Thunderbird), `autodiscover.xml`
    (Outlook) and a `.mobileconfig` profile (iOS/macOS) for each domain;
  - undecided: where to serve them from (`autoconfig.<domain>`,
    `autodiscover.<domain>`). Serving from the mail server needs port 443 open
    permanently. The alternative is another web server, for example the home
    server behind the Cloudflare Tunnel.
- [ ] **12. Per-mailbox quota.** The quota is currently one value for all
  mailboxes.

## Security and deliverability

- [ ] **13. No plain-text passwords.** `add-mailbox.sh` prints the password and
  the setup summary stores it. Generate strong passwords and show them once.
- [ ] **14. MTA-STS and TLS-RPT.**
- [ ] **15. Gradual DMARC tightening.** `p=none`, then `quarantine`, then
  `reject`, with a hint in `verify-mailserver.sh` when to move on.
- [ ] **16. ARGON2ID password hashing** instead of SHA512-CRYPT.
- [ ] **17. Optional POP3** (ports 110 and 995).
- [ ] **18. Optional IPv6** (AAAA and PTR records).
- [ ] **20. Check the `From:` header.** Postfix only checks the envelope
  sender, so a mailbox can send with its own envelope address and someone
  else's `From:`, and the message is still DKIM-signed for the domain.
- [ ] **21. Attachment protection (undecided).** ClamAV is too heavy for a
  small VPS (its signatures keep about 1–1.5 GB in RAM). Lightweight option:
  have Rspamd reject executable and script attachments (`.exe`, `.scr`, `.js`,
  `.vbs`, `.bat`, `.cmd`, `.ps1`, `.lnk`, `.iso`, macro-enabled Office files),
  also inside archives and with double extensions. Document ClamAV as an option
  for servers with 4 GB of RAM or more.

## Webmail on another server

- [ ] **23. WireGuard tunnel between the webmail server and the mail server.**
  The webmail server gets a fixed tunnel address for `trusted-client.sh`
  instead of a DDNS hostname. IMAP and SMTP traffic from webmail then stays off
  the public internet, and the mail server no longer sees the home IP.
- [ ] **24. Protect the webmail login at Cloudflare.** The mail server no longer
  bans the webmail server's IP, so password guessing through the webmail login
  must be stopped in front of it: a Cloudflare rate-limiting rule for the login
  request, or Cloudflare Access. Document it in `operations.md`.

## Platform

- [ ] **22. Recommend Debian 13.** State "Debian 13 recommended" in the README
  and `setup.md`, and print a non-blocking warning when `setup.sh` runs on
  Debian 12. CI tests only Debian 13; Debian 12 is tested locally.

## Code structure

- [ ] **19. Split `setup.sh` into functions with a `main`.** Do it together with
  9 and 17, which need steps to be called selectively.

## Done

- [x] 1. fail2ban exemption for a webmail server (`trusted-client.sh`)
- [x] 2. Send-as grants (`send-as.sh`)
- [x] 3. Alias targets may send as the alias
- [x] 4. Alias and catch-all management (`alias.sh`)
- [x] 6. Sending limit per mailbox (`send-limit.sh`)
- [x] 8. Automatic security updates (`unattended-upgrades`, `needrestart`)
- [x] Port 80 open only during certificate renewal
- [x] One language (English) and shared helpers in `scripts/lib/`
- [x] Integration test in Docker and CI
- [x] ~~Roundcube~~ dropped: SnappyMail is used as webmail
