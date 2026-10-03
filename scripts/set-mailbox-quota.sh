#!/bin/bash
# Set the global Dovecot storage quota for every virtual mailbox.
set -Eeuo pipefail

QUOTA="${1:-5G}"
LOCAL_CONF=/etc/dovecot/local.conf
BACKUP="${LOCAL_CONF}.bak.$(date +%Y%m%d%H%M%S)"

[[ $EUID -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
[[ "$QUOTA" =~ ^[1-9][0-9]*[KMGT]$ ]] || { echo 'Usage: sudo bash set-mailbox-quota.sh [SIZE], e.g. 5G or 500M' >&2; exit 2; }
[[ -f "$LOCAL_CONF" ]] || { echo "Missing $LOCAL_CONF. Is this a mailserver installed by this project?" >&2; exit 1; }

cp "$LOCAL_CONF" "$BACKUP"

if grep -q '^# BEGIN MAILSERVER QUOTA$' "$LOCAL_CONF"; then
  awk '/^# BEGIN MAILSERVER QUOTA$/{skip=1} !skip{print} /^# END MAILSERVER QUOTA$/{skip=0; next}' "$LOCAL_CONF" >"${LOCAL_CONF}.new"
  mv "${LOCAL_CONF}.new" "$LOCAL_CONF"
elif doveconf -n | grep -Fq 'quota "User quota" {'; then
  perl -0pi -e 's/(quota "User quota" \{.*?storage_size = )[0-9]+[KMGT]/$1$ENV{QUOTA}/s' "$LOCAL_CONF"
fi

if ! doveconf -n | grep -Fq 'quota "User quota" {'; then
  cat >>"$LOCAL_CONF" <<EOF

# BEGIN MAILSERVER QUOTA
mail_plugins {
  quota = yes
}
quota "User quota" {
  driver = count
  storage_size = $QUOTA
}
# END MAILSERVER QUOTA
EOF
fi

QUOTA="$QUOTA" perl -0pi -e 's/(quota "User quota" \{.*?storage_size = )[0-9]+[KMGT]/$1$ENV{QUOTA}/s' "$LOCAL_CONF"
doveconf -n >/dev/null
systemctl restart dovecot
doveconf -n | sed -n '/quota "User quota" {/,/}/p'
echo "Quota set to $QUOTA. Backup: $BACKUP"