# fail2ban jails for SSH, SMTP authentication and Dovecot logins.
# shellcheck shell=bash

# The stock dovecot filter does not match Dovecot 2.4 log lines such as
#   imap-login: Info: Login aborted: Connection closed (auth failed, 1 attempts
#   in 2 secs) (auth_failed): user=<...>, method=PLAIN, rip=203.0.113.9, ...
# and Debian's jail reads the systemd journal instead of Dovecot's log file, so
# IMAP and POP3 password guessing went unnoticed. This filter matches both the
# 2.4 format and the older "Aborted login (auth failed ...)" one.
write_fail2ban_config() {
    cat > /etc/fail2ban/filter.d/mailserver-dovecot.conf << 'EOF'
# Managed by mailserver: failed IMAP/POP3/submission logins, Dovecot 2.3 and 2.4.
[Definition]
failregex = ^\s*(?:imap|pop3|submission|managesieve)-login: (?:Info: )?(?:Login aborted|Aborted login|Disconnected)\b[^(]*\((?:auth failed, \d+ attempts?(?: in \d+ secs?)?|tried to use (?:disabled|disallowed) \S+ auth)\)(?: \(\w+\))?: (?:user=<[^>]*>, )?(?:method=\S+, )?rip=<HOST>,
ignoreregex =
EOF

    cat > /etc/fail2ban/jail.local << 'EOF'
# Managed by mailserver. Trusted clients: scripts/trusted-client.sh
[DEFAULT]
bantime  = 86400
findtime = 3600
maxretry = 5

[sshd]
enabled = true

[postfix-sasl]
enabled  = true
port     = smtp,465,submission
filter   = postfix[mode=auth]
logpath  = /var/log/mail.log
maxretry = 5

# Debian points this jail at the systemd journal, but Dovecot logs to a file.
[dovecot]
enabled  = true
port     = imap,imaps,pop3,pop3s
filter   = mailserver-dovecot
backend  = auto
logpath  = /var/log/dovecot.log
maxretry = 5
EOF

    # fail2ban refuses to start when a jail logpath does not exist yet.
    touch /var/log/mail.log /var/log/dovecot.log
}

# Dovecot writes its own log file (read by the dovecot jail), which grows
# forever without rotation. Skipped when another logrotate file covers it.
install_dovecot_logrotate() {
    grep -rqs '/var/log/dovecot.log' /etc/logrotate.d/ && return 0
    cat > /etc/logrotate.d/mailserver-dovecot << 'EOF2'
/var/log/dovecot.log {
    weekly
    rotate 8
    missingok
    notifempty
    compress
    delaycompress
    postrotate
        doveadm log reopen >/dev/null 2>&1 || true
    endscript
}
EOF2
}
