# Automatic Debian updates, shared by setup.sh and upgrade.sh.
# shellcheck shell=bash

# unattended-upgrades installs Debian security and stable point updates every
# day; needrestart then restarts the services that still use a replaced library
# (an OpenSSL fix is useless until Postfix and Dovecot reload it). Dovecot and
# Rspamd come from their own repositories, which unattended-upgrades leaves
# alone: their releases can change configuration, so update them by hand.
install_auto_updates() {
    # needrestart reads this while it is being installed, so write it first.
    install -d -m 0755 /etc/needrestart/conf.d
    cat > /etc/needrestart/conf.d/mailserver.conf << 'EOF'
# Managed by mailserver: restart services using replaced libraries without
# asking. A new kernel needs a reboot; status.sh shows when one is pending.
$nrconf{restart} = 'a';
$nrconf{kernelhints} = 0;
EOF
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        unattended-upgrades needrestart

    # Sorts after the stock 20auto-upgrades, so these values win.
    cat > /etc/apt/apt.conf.d/52mailserver-auto-upgrades << 'EOF'
// Managed by mailserver: install Debian updates, including security fixes,
// every day. Reboots for a new kernel are left to the administrator.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
}
