# POP3 on or off: Dovecot's protocol list and the firewall ports 110 and 995.
# shellcheck shell=bash

pop3_enabled() {
    grep -Eq '^protocols = .*\bpop3\b' /etc/dovecot/local.conf 2>/dev/null
}

# sync_pop3_firewall: open 110 and 995 when POP3 is on, close them when it is
# off. Leaves the firewall alone while UFW is not active.
sync_pop3_firewall() {
    command -v ufw >/dev/null && ufw status | grep -q '^Status: active' || return 0
    local port
    if pop3_enabled; then
        ufw allow 110/tcp comment 'POP3' >/dev/null
        ufw allow 995/tcp comment 'POP3S' >/dev/null
    else
        for port in 110 995; do
            ufw status | grep -Eq "^${port}/tcp " && ufw delete allow "${port}/tcp" >/dev/null
        done
    fi
    return 0
}

# set_pop3 on|off: change Dovecot and the firewall; the caller restarts Dovecot.
set_pop3() {
    local protocols="imap lmtp"
    [[ "$1" == on ]] && protocols="imap pop3 lmtp"
    grep -q '^protocols = ' /etc/dovecot/local.conf || die "No protocols line in /etc/dovecot/local.conf"
    sed -i "s/^protocols = .*/protocols = ${protocols}/" /etc/dovecot/local.conf
    sync_pop3_firewall
}
