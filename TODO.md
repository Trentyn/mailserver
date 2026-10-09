# TODO

Open work for running this mail server for a team or organization. Numbers
match the planning list, so done items leave gaps.

## Important

- [ ] **5. Backups and restore.** Back up Maildirs, DKIM keys and configs
  (restic or borg to off-site storage) and document a tested restore.
  Without it, losing the VPS loses all mail.
- [ ] **6. Outbound rate limit per mailbox.** Rspamd ratelimit, so a stolen
  password cannot send thousands of messages and get the IP blocklisted.
- [ ] **7. Monitoring and alerts.** Stopped services, certificate expiry,
  growing queue, low disk space, IP on blocklists; alert by email or Telegram.
- [ ] **8. Automatic security updates.** `unattended-upgrades`.
- [ ] **9. Non-interactive install.** Read answers from a config file or
  environment variables for cloud-init and Ansible.

## User experience

- [ ] **10. ManageSieve (port 4190).** User filters and vacation replies,
  usable from SnappyMail.
- [ ] **11. Mail client autoconfiguration.** Thunderbird autoconfig, Outlook
  autodiscover, iOS profile.
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

## Code structure

- [ ] **19. Split `setup.sh` into functions with a `main`.** Do it together with
  9 and 17, which need steps to be called selectively.

## Done

- [x] 1. fail2ban exemption for a webmail server (`trusted-client.sh`)
- [x] 2. Send-as grants (`send-as.sh`)
- [x] 3. Alias targets may send as the alias
- [x] 4. Alias and catch-all management (`alias.sh`)
- [x] Port 80 open only during certificate renewal
- [x] One language (English) and shared helpers in `scripts/lib/`
- [x] Integration test in Docker and CI
- [x] ~~Roundcube~~ dropped: SnappyMail is used as webmail
