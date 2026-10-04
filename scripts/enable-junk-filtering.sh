#!/bin/bash
# Enable Junk delivery, Bayes training, and shared Trash/Junk retention on an
# existing installation created by this repository.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RETENTION_DAYS="${1:-30}"

if (( EUID != 0 )); then
    echo "Run as root: sudo bash scripts/enable-junk-filtering.sh [days]" >&2
    exit 1
fi
if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
    echo "Retention days must be a non-negative integer." >&2
    exit 1
fi

for command in doveconf rspamadm rspamc systemctl install; do
    command -v "$command" >/dev/null || { echo "Missing required command: $command" >&2; exit 1; }
done

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y dovecot-sieve

STAMP=$(date +%Y%m%d%H%M%S)
BACKUP_DIR="/root/mailserver-junk-backup-${STAMP}"
mkdir -p "$BACKUP_DIR"
for path in /etc/dovecot/dovecot.conf /etc/dovecot/mailserver-junk.conf /etc/rspamd/local.d/milter_headers.conf /etc/rspamd/local.d/redis.conf /etc/rspamd/local.d/options.inc; do
    [[ -e "$path" ]] && cp -a "$path" "$BACKUP_DIR/$(basename "$path")"
done

cat > /etc/dovecot/mailserver-junk.conf <<'EOF'
namespace inbox {
  mailbox Junk {
    auto = create
    special_use = \Junk
  }
}

protocol lmtp {
  mail_plugins {
    sieve = yes
  }
}

protocol imap {
  mail_plugins {
    imap_sieve = yes
  }
}

sieve_plugins {
  sieve_extprograms = yes
  sieve_imapsieve = yes
}
sieve_global_extensions {
  vnd.dovecot.pipe = yes
}
sieve_pipe_bin_dir = /usr/lib/dovecot/sieve

sieve_script spam_to_junk {
  type = before
  path = /etc/dovecot/sieve/spam-to-junk.sieve
}
mailbox Junk {
  sieve_script learn_spam {
    type = before
    cause = copy
    path = /etc/dovecot/sieve/learn-spam.sieve
  }
}
imapsieve_from Junk {
  sieve_script learn_ham {
    type = before
    cause = copy
    path = /etc/dovecot/sieve/learn-ham.sieve
  }
}
EOF

grep -qxF '!include_try mailserver-junk.conf' /etc/dovecot/dovecot.conf || printf '\n!include_try mailserver-junk.conf\n' >> /etc/dovecot/dovecot.conf

install -d -o root -g vmail -m 0750 /etc/dovecot/sieve /usr/lib/dovecot/sieve
cat > /etc/dovecot/sieve/spam-to-junk.sieve <<'EOF'
require ["fileinto", "mailbox"];
if header :is "X-Rspamd-Deliver-To" "Junk" {
  fileinto :create "Junk";
  stop;
}
EOF
cat > /etc/dovecot/sieve/learn-spam.sieve <<'EOF'
require ["vnd.dovecot.pipe", "copy"];
pipe :copy "rspamd-learn-spam";
EOF
cat > /etc/dovecot/sieve/learn-ham.sieve <<'EOF'
require ["vnd.dovecot.pipe", "copy", "imapsieve", "environment"];
if environment :is "imap.mailbox" "Trash" { stop; }
pipe :copy "rspamd-learn-ham";
EOF
cat > /usr/lib/dovecot/sieve/rspamd-learn-spam <<'EOF'
#!/bin/sh
exec /usr/bin/rspamc -h 127.0.0.1:11334 learn_spam
EOF
cat > /usr/lib/dovecot/sieve/rspamd-learn-ham <<'EOF'
#!/bin/sh
exec /usr/bin/rspamc -h 127.0.0.1:11334 learn_ham
EOF
sievec -c /etc/dovecot/dovecot.conf /etc/dovecot/sieve/spam-to-junk.sieve
sievec -c /etc/dovecot/dovecot.conf /etc/dovecot/sieve/learn-spam.sieve
sievec -c /etc/dovecot/dovecot.conf /etc/dovecot/sieve/learn-ham.sieve
chown root:vmail /etc/dovecot/sieve/* /usr/lib/dovecot/sieve/rspamd-learn-spam /usr/lib/dovecot/sieve/rspamd-learn-ham
chmod 0640 /etc/dovecot/sieve/*.sieve /etc/dovecot/sieve/*.svbin
chmod 0750 /usr/lib/dovecot/sieve/rspamd-learn-spam /usr/lib/dovecot/sieve/rspamd-learn-ham

mkdir -p /etc/rspamd/local.d
cat > /etc/rspamd/local.d/redis.conf <<'EOF'
servers = "127.0.0.1:6379";
EOF
cat > /etc/rspamd/local.d/options.inc <<'EOF'
task_timeout = 10s;
EOF
cat > /etc/rspamd/local.d/milter_headers.conf <<'EOF'
use = ["spam-header"];
routines {
  spam-header {
    header = "X-Rspamd-Deliver-To";
    value = "Junk";
    remove = 0;
  }
}
EOF

rspamadm configtest
doveconf -n >/dev/null
systemctl restart rspamd dovecot
systemctl is-active --quiet rspamd dovecot

while IFS=: read -r email _; do
    [[ -n "$email" ]] || continue
    if ! doveadm mailbox list -u "$email" | grep -Fxq Junk; then
        doveadm mailbox create -u "$email" Junk
    fi
done < /etc/dovecot/users

install -m 0750 "$SCRIPT_DIR/cleanup-mailboxes.sh" /usr/local/sbin/mailserver-cleanup-mailboxes
if (( RETENTION_DAYS > 0 )); then
    bash "$SCRIPT_DIR/install-mail-cleanup-timer.sh" "$RETENTION_DAYS"
else
    systemctl disable --now mailserver-mail-cleanup.timer 2>/dev/null || true
fi

echo "Junk filtering enabled. Backup: $BACKUP_DIR"
echo "Trash and Junk retention: ${RETENTION_DAYS} days"