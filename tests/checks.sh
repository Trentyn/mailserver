#!/bin/bash
# Runs inside the test container after setup.sh completed. Each check prints
# PASS or FAIL; the exit code is the number of failures (capped at 1).
set -uo pipefail

cd /root/mailserver || exit 1
PASSWORD='Secret123!'
IP=$(hostname -I | awk '{print $1}')
passed=0
failed=0

# check NAME COMMAND: COMMAND is a bash snippet that must exit 0.
check() {
    local name="$1" cmd="$2" out
    if out=$(bash -c "$cmd" 2>&1); then
        echo "PASS  $name"
        passed=$((passed + 1))
    else
        echo "FAIL  $name"
        echo "$out" | tail -5 | sed 's/^/      /'
        failed=$((failed + 1))
    fi
}

# swaks marks server replies "<-" (plain) or "<~" (TLS); an error reply is
# "<**" in plain text and "<~*" over TLS.
smtp_ok()     { grep -Eq '^<[-~] +250 .*queued'; }
smtp_reject() { grep -Eq "^<[-~*]\*? +$1"; }
export -f smtp_ok smtp_reject
export PASSWORD IP

wait_for_mail() {  # wait_for_mail USER MAILBOX SUBJECT
    for _ in {1..20}; do
        doveadm search -u "$1" mailbox "$2" subject "$3" 2>/dev/null | grep -q . && return 0
        sleep 0.5
    done
    return 1
}
export -f wait_for_mail

echo "== Installation"
for svc in postfix dovecot rspamd redis-server fail2ban; do
    check "service $svc is active" "systemctl is-active --quiet $svc"
done
check "postfix check" "postfix check"
check "doveconf parses the config" "doveconf -n >/dev/null"
check "rspamadm configtest" "rspamadm configtest"
check "fail2ban runs the sshd, postfix-sasl and dovecot jails" \
    "fail2ban-client status | grep -q 'dovecot, postfix-sasl, sshd'"
check "setup refuses to run on an installed server" \
    "bash scripts/setup.sh </dev/null 2>&1 | grep -q 'already installed'"
check "setup summary is root-only" "[[ \$(stat -c %a /root/mailserver-setup-*.txt) == 600 ]]"
check "shell environment is sourced from root's .bashrc" "grep -q '# mailserver' /root/.bashrc"
check "shell environment is sourced from the sudo user's .bashrc" "grep -q '# mailserver' /home/admin/.bashrc"
check "scripts work with a PATH lacking sbin (su without -)" \
    "echo 0 | env PATH=/usr/bin:/bin bash scripts/status.sh >/dev/null
     env PATH=/usr/bin:/bin bash scripts/verify-mailserver.sh 2>&1 | grep -q 'OK.*Postfix configuration'"
check "Dovecot log rotation is valid" "logrotate -d /etc/logrotate.d/mailserver-dovecot"
check "Trash and Junk cleanup timer is active" "systemctl is-active --quiet mailserver-mail-cleanup.timer"

echo "== Firewall and certificate renewal"
check "UFW is active" "ufw status | grep -q '^Status: active'"
check "UFW allows the SSH port sshd listens on (2222), found through sudo" \
    "ufw status | grep -Eq '^2222/tcp +ALLOW' && ! ufw status | grep -Eq '^22/tcp '"
check "port 80 is closed outside renewals" "! ufw status | grep -Eq '^80(/tcp)? '"
check "renewal pre hook opens port 80" \
    "/etc/letsencrypt/renewal-hooks/pre/mailserver-open-http.sh && ufw status | grep -Eq '^80/tcp +ALLOW'"
check "renewal post hook closes port 80" \
    "/etc/letsencrypt/renewal-hooks/post/mailserver-close-http.sh && ! ufw status | grep -Eq '^80(/tcp)? '"
check "hooks leave an administrator's port 80 rule alone" \
    "ufw allow 80/tcp comment web >/dev/null
     /etc/letsencrypt/renewal-hooks/pre/mailserver-open-http.sh
     /etc/letsencrypt/renewal-hooks/post/mailserver-close-http.sh
     ufw status | grep -Eq '^80/tcp +ALLOW'; rc=\$?; ufw delete allow 80/tcp >/dev/null; exit \$rc"
check "deploy hook keeps the key readable by Dovecot" \
    "/etc/letsencrypt/renewal-hooks/deploy/reload-mail.sh && [[ \$(stat -c %G:%a /etc/letsencrypt/live/mx.example.test/privkey.pem) == dovecot:640 ]]"

# An older installation: port 80 open for good, no sending limits and no
# automatic updates. upgrade.sh runs through sudo, as an administrator would.
check "upgrade.sh brings an older installation up to date (through sudo)" \
    "ufw allow 80/tcp comment 'HTTP Lets Encrypt' >/dev/null
     rm -f /etc/rspamd/local.d/ratelimit.conf /etc/apt/apt.conf.d/52mailserver-auto-upgrades
     systemctl reload rspamd
     runuser -u admin -- sudo -n bash /home/admin/mailserver/scripts/upgrade.sh >/dev/null
     ! ufw status | grep -Eq '^80(/tcp)? ' && systemctl is-active --quiet postfix fail2ban rspamd && postfix check
     grep -q mailbox_hourly /etc/rspamd/local.d/ratelimit.conf
     apt-config dump | grep -Fq 'APT::Periodic::Unattended-Upgrade \"1\"'"
check "fail2ban dovecot jail reads Dovecot's log with the 2.4 filter" \
    "fail2ban-client get dovecot failregex | grep -q 'Login aborted' && fail2ban-client get dovecot logpath | grep -q /var/log/dovecot.log"

echo "== Mail flow"
check "inbound mail is delivered" \
    "swaks --server 127.0.0.1 --from ext@gmail.com --to info@example.test --header 'Subject: inbound-1' | smtp_ok && wait_for_mail info@example.test INBOX inbound-1"
check "postmaster@ alias delivers to the first mailbox" \
    "swaks --server 127.0.0.1 --from ext@gmail.com --to postmaster@example.test --header 'Subject: to-postmaster' | smtp_ok && wait_for_mail info@example.test INBOX to-postmaster"
check "unknown recipient is rejected" \
    "swaks --server 127.0.0.1 --from ext@gmail.com --to nobody@example.test | smtp_reject 550"
check "relaying to other domains is denied" \
    "swaks --server \$IP --from ext@gmail.com --to someone@other.test | smtp_reject 554"
check "authenticated submission on 587" \
    "swaks --server \$IP:587 --tls --auth LOGIN --auth-user info@example.test --auth-password \"\$PASSWORD\" --from info@example.test --to info@example.test --header 'Subject: submitted' | smtp_ok"
check "authenticated submission on 465" \
    "swaks --server \$IP:465 --tlsc --auth LOGIN --auth-user info@example.test --auth-password \"\$PASSWORD\" --from info@example.test --to info@example.test --header 'Subject: smtps' | smtp_ok"
check "sending as another address is rejected" \
    "swaks --server \$IP:587 --tls --auth LOGIN --auth-user info@example.test --auth-password \"\$PASSWORD\" --from ceo@example.test --to info@example.test | smtp_reject 553"
check "wrong password is rejected" \
    "swaks --server \$IP:587 --tls --auth LOGIN --auth-user info@example.test --auth-password wrong --from info@example.test --to info@example.test 2>&1 | grep -q 'No authentication type succeeded'"
check "submitted mail is DKIM-signed" \
    "wait_for_mail info@example.test INBOX submitted
     uid=\$(doveadm search -u info@example.test mailbox INBOX subject submitted | awk '{print \$2}' | head -1)
     doveadm fetch -u info@example.test hdr mailbox INBOX uid \$uid | grep -q 'DKIM-Signature: v=1; a=rsa-sha256; c=relaxed/relaxed; d=example.test;'"
check "IMAPS login" \
    "curl -sk --user \"info@example.test:\$PASSWORD\" imaps://127.0.0.1/INBOX -X 'STATUS INBOX (MESSAGES)' | grep -q 'STATUS INBOX'"
check "POP3S login" "curl -sk --user \"info@example.test:\$PASSWORD\" pop3s://127.0.0.1/ >/dev/null"

echo "== Junk delivery and training"
# Rspamd skips its headers for local senders and only a scored message (not
# GTUBE) gets them, so make every test message look like external spam.
cp /etc/rspamd/local.d/milter_headers.conf /root/milter_headers.conf.orig
echo 'skip_local = false;' >> /etc/rspamd/local.d/milter_headers.conf
printf 'greylist = null;\nadd_header = 0.3;\nreject = 50;\n' > /etc/rspamd/local.d/actions.conf
systemctl restart rspamd && sleep 3
check "spam is filed into Junk" \
    "swaks --server 127.0.0.1 --from ext@gmail.com --to info@example.test --header 'Subject: junk-1' --body 'buy now' | smtp_ok && wait_for_mail info@example.test Junk junk-1"
cp /root/milter_headers.conf.orig /etc/rspamd/local.d/milter_headers.conf
rm -f /etc/rspamd/local.d/actions.conf
systemctl restart rspamd && sleep 3
check "moving mail into and out of Junk trains Rspamd" \
    "before=\$(grep -c 'learn' /var/log/rspamd/rspamd.log)
     python3 - <<'PY'
import imaplib, os, ssl
c = imaplib.IMAP4_SSL('127.0.0.1', ssl_context=ssl._create_unverified_context())
c.login('info@example.test', os.environ['PASSWORD'])
c.select('Junk'); c.uid('MOVE', '1:*', 'INBOX')
c.select('INBOX'); _, d = c.uid('SEARCH', None, 'SUBJECT', 'inbound-1'); c.uid('MOVE', d[0].split()[0], 'Junk')
c.logout()
PY
     sleep 3
     (( \$(grep -c 'learn' /var/log/rspamd/rspamd.log) > before ))"

echo "== Aliases and sending identities"
send_as() {  # send_as LOGIN FROM: submit a message on 587 as LOGIN with envelope FROM
    swaks --server "$IP:587" --tls --auth LOGIN --auth-user "$1" --auth-password "$PASSWORD" \
        --from "$2" --to info@example.test --header "Subject: send-as $2"
}
export -f send_as
# Only one domain exists yet, so add-mailbox does not ask for it.
printf 'bob\n%s\n%s\ny\n' "$PASSWORD" "$PASSWORD" | bash scripts/add-mailbox.sh >/dev/null 2>&1
check "alias delivers to its target" \
    "bash scripts/alias.sh add sales@example.test info@example.test >/dev/null
     swaks --server 127.0.0.1 --from ext@gmail.com --to sales@example.test --header 'Subject: to-sales' | smtp_ok && wait_for_mail info@example.test INBOX to-sales"
check "alias target may send as the alias" "send_as info@example.test sales@example.test | smtp_ok"
check "first mailbox may send as postmaster@" "send_as info@example.test postmaster@example.test | smtp_ok"
check "other mailboxes may not send as the alias" "send_as bob@example.test sales@example.test | smtp_reject 553"
check "a mailbox may send from its +extension address" "send_as info@example.test info+news@example.test | smtp_ok"
check "alias cannot shadow an existing mailbox" \
    "! bash scripts/alias.sh add bob@example.test info@example.test 2>/dev/null"
check "catch-all receives mail for unknown addresses" \
    "bash scripts/alias.sh add @example.test info@example.test >/dev/null
     swaks --server 127.0.0.1 --from ext@gmail.com --to random@example.test --header 'Subject: to-random' | smtp_ok && wait_for_mail info@example.test INBOX to-random"
check "catch-all does not swallow mail for existing mailboxes" \
    "swaks --server 127.0.0.1 --from ext@gmail.com --to bob@example.test --header 'Subject: to-bob' | smtp_ok
     wait_for_mail bob@example.test INBOX to-bob && ! doveadm search -u info@example.test mailbox INBOX subject to-bob | grep -q ."
check "catch-all grants no sending rights" "send_as info@example.test random@example.test | smtp_reject 553"
check "send-as grant allows another address" \
    "bash scripts/send-as.sh grant bob@example.test ceo@example.test >/dev/null && send_as bob@example.test ceo@example.test | smtp_ok"
check "send-as revoke takes the right away" \
    "bash scripts/send-as.sh revoke bob@example.test ceo@example.test >/dev/null && send_as bob@example.test ceo@example.test | smtp_reject 553"
check "domain-wide grant covers existing mailboxes and aliases" \
    "bash scripts/send-as.sh grant bob@example.test @example.test >/dev/null
     send_as bob@example.test info@example.test | smtp_ok && send_as bob@example.test anything@example.test | smtp_ok
     bash scripts/send-as.sh revoke bob@example.test @example.test >/dev/null
     send_as bob@example.test info@example.test | smtp_reject 553"
check "send-as refuses domains this server does not host" \
    "! bash scripts/send-as.sh grant bob@example.test boss@gmail.com 2>/dev/null"
check "deleting a mailbox keeps the other targets of its aliases" \
    "bash scripts/alias.sh add team@example.test bob@example.test >/dev/null
     bash scripts/alias.sh add team@example.test info@example.test >/dev/null
     printf 'bob@example.test\nbob@example.test\n' | bash scripts/delete-mailbox.sh >/dev/null
     awk '\$1 == \"team@example.test\"' /etc/postfix/virtual | grep -qx 'team@example.test.info@example.test'
     ! grep -q 'bob@example.test' /etc/postfix/virtual /etc/postfix/sender_login_maps /etc/postfix/virtual_mailboxes"
check "alias remove drops aliases and the catch-all" \
    "bash scripts/alias.sh remove @example.test >/dev/null && bash scripts/alias.sh remove sales@example.test info@example.test >/dev/null
     ! grep -Eq '^(@example.test|sales@example.test)[[:space:]]' /etc/postfix/virtual
     swaks --server 127.0.0.1 --from ext@gmail.com --to random@example.test | smtp_reject 550"
check "alias.sh sync applies a hand-edited alias" \
    "printf 'hand@example.test\tinfo@example.test\n' >> /etc/postfix/virtual && bash scripts/alias.sh sync >/dev/null
     send_as info@example.test hand@example.test | smtp_ok"
check "trusted-client accepts an IP and a hostname" \
    "bash scripts/trusted-client.sh add 203.0.113.7 >/dev/null && bash scripts/trusted-client.sh add one.one.one.one >/dev/null
     ips=\$(fail2ban-client get dovecot ignoreip)
     grep -q 203.0.113.7 <<< \"\$ips\" && grep -q one.one.one.one <<< \"\$ips\""
check "trusted-client remove" \
    "bash scripts/trusted-client.sh remove 203.0.113.7 >/dev/null && bash scripts/trusted-client.sh remove one.one.one.one >/dev/null
     ! fail2ban-client get dovecot ignoreip | grep -Eq '203.0.113.7|one.one.one.one'"

echo "== Automatic updates"
check "Debian security updates install automatically" \
    "apt-config dump | grep -Fq 'APT::Periodic::Unattended-Upgrade \"1\"'
     systemctl is-enabled --quiet apt-daily-upgrade.timer && systemctl is-enabled --quiet apt-daily.timer"
check "needrestart restarts services without asking" \
    "grep -q \"restart} = 'a'\" /etc/needrestart/conf.d/mailserver.conf && command -v needrestart"
check "unattended-upgrade runs (dry run)" "unattended-upgrade --dry-run"

echo "== Sending limits"
limited() {  # limited LOGIN RCPTS: one message from LOGIN to comma-separated RCPTS
    swaks --server "$IP:587" --tls --auth LOGIN --auth-user "$1" --auth-password "$PASSWORD" \
        --from "$1" --to "$2" --header "Subject: limit $1"
}
export -f limited
# Only one domain exists, so add-mailbox does not ask for it.
for u in lim1 lim2 lim3; do
    printf '%s\n%s\n%s\ny\n' "$u" "$PASSWORD" "$PASSWORD" | bash scripts/add-mailbox.sh >/dev/null 2>&1
done
check "default limit is 100 recipients per hour and 500 per day" \
    "bash scripts/send-limit.sh show | grep -q '100 recipients per hour and 500 per day'
     rspamadm configdump ratelimit | grep -q mailbox_daily"
check "postmaster and mailer-daemon recipients do not switch the limit off" \
    "! rspamadm configdump ratelimit | grep -A3 whitelisted_rcpts | grep -Eq 'postmaster|mailer-daemon'"
check "send-limit.sh set works through sudo" \
    "runuser -u admin -- sudo -n bash /home/admin/mailserver/scripts/send-limit.sh set 3 10 >/dev/null
     [[ \$(cat /etc/mailserver/send-limit) == '3 10' ]]"
sleep 3
check "a mailbox may send up to its limit" \
    "limited lim1@example.test info@example.test | smtp_ok
     limited lim1@example.test info@example.test,lim2@example.test | smtp_ok"
check "the next recipient is deferred with a clear message" \
    "out=\$(limited lim1@example.test info@example.test)
     smtp_reject 451 <<< \"\$out\" && grep -q 'Sending limit of 3 recipients per hour' <<< \"\$out\""
check "adding postmaster@ as a recipient does not bypass the limit" \
    "limited lim1@example.test postmaster@example.test | smtp_reject 451"
check "one message may not have more recipients than the hourly limit" \
    "limited lim2@example.test info@example.test,lim1@example.test,postmaster@example.test,info+x@example.test | smtp_reject 452"
check "recipients are counted, not messages" \
    "limited lim3@example.test info@example.test,lim1@example.test | smtp_ok
     limited lim3@example.test info@example.test,lim1@example.test | smtp_reject 451"
check "an exempt mailbox sends past the limit, and is limited again after unexempt" \
    "bash scripts/send-limit.sh exempt lim1@example.test >/dev/null && sleep 3
     limited lim1@example.test info@example.test | smtp_ok
     bash scripts/send-limit.sh unexempt lim1@example.test >/dev/null && sleep 3
     limited lim1@example.test info@example.test | smtp_reject 451"
check "show lists the mailboxes that hit the limit" \
    "bash scripts/send-limit.sh show | grep -q 'lim1@example.test (hourly)'"
check "send-limit.sh rejects nonsense" \
    "! bash scripts/send-limit.sh set 0 10 2>/dev/null && ! bash scripts/send-limit.sh set 50 10 2>/dev/null
     ! bash scripts/send-limit.sh exempt nobody@example.test 2>/dev/null"
check "send-limit.sh off removes the limit" \
    "bash scripts/send-limit.sh off >/dev/null && sleep 3
     limited lim1@example.test info@example.test | smtp_ok"
check "deleting a mailbox drops its exemption" \
    "bash scripts/send-limit.sh exempt lim2@example.test >/dev/null
     printf 'lim2@example.test\nlim2@example.test\n' | bash scripts/delete-mailbox.sh >/dev/null
     ! grep -q lim2@ /etc/mailserver/send-limit-exempt"
bash scripts/send-limit.sh set 100 500 >/dev/null

echo "== Maintenance scripts"
check "add-domain rejects an invalid domain" \
    "printf 'bad domain\n' | bash scripts/add-domain.sh 2>&1 | grep -q 'Invalid domain'"
check "add-domain example.test.au" \
    "printf 'example.test.au\n\n\ny\n' | bash scripts/add-domain.sh && grep -q '^postmaster@example.test.au' /etc/postfix/virtual"
check "back-to-back add-mailbox runs all succeed" \
    "for u in bob r1 r2 r3; do printf 'example.test.au\n%s\nPw12345!x\nPw12345!x\ny\n' \$u | bash scripts/add-mailbox.sh >/dev/null || exit 1; done
     doveadm mailbox list -u r3@example.test.au | grep -qx Junk"
check "add-mailbox refuses a duplicate" \
    "printf 'example.test.au\nbob\n' | bash scripts/add-mailbox.sh 2>&1 | grep -q 'already exists'"
check "passwd-mailbox changes the password" \
    "printf 'bob@example.test.au\nNew12345!x\nNew12345!x\n' | bash scripts/passwd-mailbox.sh >/dev/null && doveadm auth test bob@example.test.au 'New12345!x' | grep -q 'auth succeeded'"
check "delete-mailbox removes every trace" \
    "printf 'r1@example.test.au\nr1@example.test.au\n' | bash scripts/delete-mailbox.sh >/dev/null
     ! grep -q '^r1@' /etc/dovecot/users /etc/postfix/vmailbox /etc/postfix/sender_login_maps && [[ ! -d /var/mail/vhosts/example.test.au/r1 ]]"
check "delete-domain example.test.au leaves example.test intact" \
    "printf 'example.test.au\nexample.test.au\n' | bash scripts/delete-domain.sh >/dev/null
     ! grep -q 'example.test.au' /etc/dovecot/users /etc/postfix/vmailbox /etc/postfix/virtual /etc/rspamd/dkim_selectors.map
     grep -q '^info@example.test:' /etc/dovecot/users
     grep -q '^postmaster@example.test' /etc/postfix/virtual
     [[ -f /var/lib/rspamd/dkim/example.test.mail\$(date +%Y).key && -d /var/mail/vhosts/example.test/info ]]
     doveadm auth test info@example.test \"\$PASSWORD\" | grep -q 'auth succeeded'"
check "status works without a terminal" "echo 0 | env -u TERM bash scripts/status.sh >/dev/null"
check "verify passes every local check" \
    "out=\$(bash scripts/verify-mailserver.sh 2>&1)
     # DNS, PTR and the public certificate cannot pass for a test domain.
     ! grep '^\[FAIL\]' <<< \"\$out\" | grep -vE '\] (A |MX |SPF |DKIM record |DMARC |PTR |IMAPS TLS)'"
check "set-mailbox-quota changes the quota" \
    "bash scripts/set-mailbox-quota.sh 10G >/dev/null && doveadm quota get -u info@example.test | grep -q 10485760"
check "cleanup-mailboxes preview runs" "bash scripts/cleanup-mailboxes.sh --days 1 >/dev/null"

echo
echo "Passed: ${passed}  Failed: ${failed}"
(( failed == 0 ))
