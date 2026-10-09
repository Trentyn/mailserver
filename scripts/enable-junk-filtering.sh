#!/bin/bash
# Enable Junk delivery, Bayes training, and shared Trash/Junk retention on an
# existing installation created by this repository.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/junk.sh
. "$SCRIPT_DIR/lib/junk.sh"
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
  mailbox Sent {
    auto = subscribe
    special_use = \Sent
  }
  mailbox Drafts {
    auto = subscribe
    special_use = \Drafts
  }
  mailbox Trash {
    auto = subscribe
    special_use = \Trash
  }
  mailbox Junk {
    auto = subscribe
    special_use = \Junk
  }
  mailbox Archive {
    auto = subscribe
    special_use = \Archive
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

install_junk_sieve_rules
write_rspamd_junk_config

rspamadm configtest
doveconf -n >/dev/null
systemctl restart rspamd dovecot
systemctl is-active --quiet rspamd dovecot

while IFS=: read -r email _; do
    [[ -n "$email" ]] || continue
    for mailbox in Sent Drafts Trash Junk Archive; do
        if ! doveadm mailbox list -u "$email" | grep -Fxq "$mailbox"; then
            doveadm mailbox create -u "$email" "$mailbox"
        fi
    done
done < /etc/dovecot/users

install -m 0750 "$SCRIPT_DIR/cleanup-mailboxes.sh" /usr/local/sbin/mailserver-cleanup-mailboxes
if (( RETENTION_DAYS > 0 )); then
    bash "$SCRIPT_DIR/install-mail-cleanup-timer.sh" "$RETENTION_DAYS"
else
    systemctl disable --now mailserver-mail-cleanup.timer 2>/dev/null || true
fi

echo "Junk filtering enabled. Backup: $BACKUP_DIR"
echo "Trash and Junk retention: ${RETENTION_DAYS} days"
