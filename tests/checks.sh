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
check "Dovecot log rotation is valid" "logrotate -d /etc/logrotate.d/mailserver-dovecot"
check "Trash and Junk cleanup timer is active" "systemctl is-active --quiet mailserver-mail-cleanup.timer"

echo "== Firewall and certificate renewal"
check "UFW is active" "ufw status | grep -q '^Status: active'"
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
