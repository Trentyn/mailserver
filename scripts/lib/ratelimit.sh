# Outbound sending limits per mailbox, enforced by Rspamd and managed by
# send-limit.sh. A stolen password then cannot be used to send thousands of
# messages and get the server's IP address blocklisted.
# shellcheck shell=bash

SEND_LIMIT_FILE=/etc/mailserver/send-limit
SEND_LIMIT_EXEMPT_FILE=/etc/mailserver/send-limit-exempt
SEND_LIMIT_DEFAULT="100 500"

# Prints "PER_HOUR PER_DAY", or "off".
send_limits() {
    if [[ -s "$SEND_LIMIT_FILE" ]]; then
        head -1 "$SEND_LIMIT_FILE"
    else
        echo "$SEND_LIMIT_DEFAULT"
    fi
}

# Rspamd counts recipients, not messages: a message to five people uses five.
# Only authenticated mail is limited; inbound mail has no user. Over the limit
# the server answers with a temporary error and nothing is sent.
write_rspamd_ratelimit_config() {
    local hour day
    read -r hour day < <(send_limits)
    install -d -m 0755 /etc/mailserver /etc/rspamd/local.d
    [[ -e "$SEND_LIMIT_EXEMPT_FILE" ]] \
        || printf '# Mailboxes without a sending limit, one per line. Managed by send-limit.sh.\n' \
            > "$SEND_LIMIT_EXEMPT_FILE"
    chmod 0644 "$SEND_LIMIT_EXEMPT_FILE"

    if [[ "$hour" == off ]]; then
        printf '# Managed by mailserver: sending limits are off (scripts/send-limit.sh).\n' \
            > /etc/rspamd/local.d/ratelimit.conf
        return 0
    fi
    cat > /etc/rspamd/local.d/ratelimit.conf << EOF
# Managed by mailserver: recipients per authenticated mailbox. Change with
# scripts/send-limit.sh, not here.
rates {
  mailbox_hourly {
    selector = "user.lower";
    bucket = {
      burst = ${hour};
      rate = "${hour} / 1h";
      message = "Sending limit of ${hour} recipients per hour reached, try again later";
    }
  }
  mailbox_daily {
    selector = "user.lower";
    bucket = {
      burst = ${day};
      rate = "${day} / 1d";
      message = "Sending limit of ${day} recipients per day reached, try again later";
    }
  }
}
whitelisted_user = "${SEND_LIMIT_EXEMPT_FILE}";
# Rspamd skips all limits when any recipient is postmaster or mailer-daemon,
# so adding postmaster@ to a spam run would bypass them. Exempt nobody.
whitelisted_rcpts = ["ratelimit-exempts-nobody.invalid"];
EOF
}

# Rspamd lets the first message of an idle mailbox through whatever its
# recipient count, so one message to a thousand addresses would pass. Postfix
# caps the recipients of a single submitted message at the hourly limit.
write_submission_recipient_limit() {
    local hour day svc
    read -r hour day < <(send_limits)
    for svc in submission/inet smtps/inet; do
        postconf -M "$svc" 2>/dev/null | grep -q . || continue
        if [[ "$hour" == off ]]; then
            postconf -PX "${svc}/smtpd_recipient_limit"
        else
            postconf -P "${svc}/smtpd_recipient_limit=${hour}"
        fi
    done
}
