#!/bin/bash
# End-to-end test: install the mail server in a Debian container with systemd,
# then exercise mail flow and the maintenance scripts.
#
#   bash tests/integration.sh            # Debian 13 (trixie)
#   DEBIAN_RELEASE=bookworm bash tests/integration.sh
#   KEEP=1 bash tests/integration.sh     # keep the container for debugging
#
# Requires Docker and outbound internet access (Rspamd and Dovecot repositories).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE="${DEBIAN_RELEASE:-trixie}"
IMAGE="mailserver-test:${RELEASE}"
NAME="mailserver-test-${RELEASE}-$$"

log() { echo -e "\n\033[1;36m== $*\033[0m"; }

S3_NAME="${NAME}-s3"
NEW_NAME="${NAME}-restore"

cleanup() {
    if [[ "${KEEP:-0}" == 1 ]]; then
        echo "Containers kept: ${NAME} ${NEW_NAME} ${S3_NAME}"
    else
        docker rm -f "$NAME" "$NEW_NAME" "$S3_NAME" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

log "Building ${IMAGE}"
docker build -q --build-arg "DEBIAN_RELEASE=${RELEASE}" -t "$IMAGE" "$REPO_DIR/tests" >/dev/null

# S3-compatible storage for the backup tests (SeaweedFS).
log "Starting S3 storage"
docker run -d --name "$S3_NAME" -v "$REPO_DIR/tests/s3.json:/etc/s3.json:ro" \
    chrislusf/seaweedfs:3.80 server -s3 -s3.config=/etc/s3.json -dir=/data >/dev/null
S3_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$S3_NAME")
S3_ENDPOINT="http://${S3_IP}:8333"

start_container() {  # start_container NAME: systemd container with the repository
    log "Starting $1"
    docker run -d --name "$1" --hostname mx --privileged --cgroupns=host \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw "$IMAGE" >/dev/null
    for _ in {1..30}; do
        state=$(docker exec "$1" systemctl is-system-running 2>/dev/null || true)
        [[ "$state" == running || "$state" == degraded ]] && break
        sleep 1
    done
    docker cp "$REPO_DIR" "$1:/root/mailserver"
    docker cp "$REPO_DIR" "$1:/home/admin/mailserver"
    docker exec "$1" chown -R admin:admin /home/admin/mailserver
}
start_container "$NAME"

# Answers to the installer prompts, in order: hostname, mail domain, DKIM
# selector, Let's Encrypt email, SSH port (accept the detected one), first
# user, password twice, quota, retention, confirmation, DNS prompt (the test
# domain never resolves), SSH-OK.
# The new server for the restore test stops there: no answer to the backup
# question means no backups. The first server answers yes and sets them up.
ANSWERS=$'mx.example.test\n\n\nadmin@example.test\n\n\nSecret123!\nSecret123!\n\n\ny\nskip\nSSH-OK\n'
BACKUP_ANSWERS="y
${S3_ENDPOINT}
mail-test


testkey
testsecret
"

# The first run goes as root, the resumed one as a regular user through sudo,
# which drops SSH_CONNECTION; the installer must still find sshd's port 2222.
run_setup_as_root() {
    docker exec -i "$NAME" bash -c 'cd /root/mailserver && bash scripts/setup.sh' <<< "$ANSWERS"
}
run_setup_with_sudo() {
    docker exec -i -u admin -e SSH_CONNECTION= "$NAME" \
        bash -c 'cd ~/mailserver && sudo bash scripts/setup.sh' <<< "${ANSWERS}${BACKUP_ANSWERS}"
}

log "Setup with a failing certificate request (must stop cleanly)"
docker exec "$NAME" touch /root/fail-cert
if run_setup_as_root > /tmp/"$NAME"-run1.log 2>&1; then
    echo "FAIL: setup succeeded although the certificate request failed"
    exit 1
fi
grep -q 'No certificate was issued' /tmp/"$NAME"-run1.log \
    || { echo "FAIL: missing certificate error"; tail -20 /tmp/"$NAME"-run1.log; exit 1; }
docker exec "$NAME" test ! -e /etc/dovecot/local.conf \
    || { echo "FAIL: mail configs were written before the certificate existed"; exit 1; }
echo "PASS  setup stops before writing mail configs when certbot fails"

log "Setup resumed through sudo after fixing the certificate"
docker exec "$NAME" rm /root/fail-cert
if ! run_setup_with_sudo > /tmp/"$NAME"-run2.log 2>&1; then
    tail -40 /tmp/"$NAME"-run2.log
    echo "FAIL: resumed setup did not complete"
    exit 1
fi
grep -q 'Found an unfinished installation' /tmp/"$NAME"-run2.log \
    || { echo "FAIL: resumed run did not detect the unfinished installation"; exit 1; }
echo "PASS  resumed setup completes"
grep -q 'Backup complete' /tmp/"$NAME"-run2.log \
    || { echo "FAIL: setup did not set up backups"; grep -A5 '══ Backups' /tmp/"$NAME"-run2.log; exit 1; }
BACKUP_PW=$(sed -n 's/\x1b\[[0-9;]*m//g; s/^ *Backup password: *//p' /tmp/"$NAME"-run2.log)
[[ ${#BACKUP_PW} -eq 40 && $(grep -cF "$BACKUP_PW" /tmp/"$NAME"-run2.log) -eq 1 ]] \
    || { echo "FAIL: the backup password was not shown exactly once"; exit 1; }
echo "PASS  setup sets up backups and shows their password once"
rm -f /tmp/"$NAME"-run1.log /tmp/"$NAME"-run2.log

log "Checks"
status=0
docker exec -e S3_ENDPOINT="$S3_ENDPOINT" "$NAME" bash /root/mailserver/tests/checks.sh || status=1

# fail2ban must ban a client that keeps failing to log in, and trusted-client.sh
# must lift and prevent that ban. The failures come from the Docker host, which
# the container sees as its default gateway.
log "fail2ban against a real client"
CIP=$(docker exec "$NAME" hostname -I | awk '{print $1}')
HOST_IP=$(docker exec "$NAME" ip route | awk '/^default/ {print $3}')
banned() { docker exec "$NAME" fail2ban-client status "$1" | grep -q "Banned IP list:.*${HOST_IP}"; }
fail_logins() {
    for _ in {1..6}; do
        curl -sk --max-time 5 --user 'info@example.test:wrong' "imaps://${CIP}/INBOX" >/dev/null 2>&1 || true
        curl -sk --max-time 5 --ssl-reqd --user 'info@example.test:wrong' --mail-from info@example.test \
            --mail-rcpt info@example.test --upload-file /dev/null "smtp://${CIP}:587" >/dev/null 2>&1 || true
    done
    sleep 3
}
fail_logins
for jail in dovecot postfix-sasl; do
    if banned "$jail"; then echo "PASS  $jail bans repeated login failures"; else echo "FAIL  $jail did not ban ${HOST_IP}"; status=1; fi
done
docker exec "$NAME" bash /root/mailserver/scripts/trusted-client.sh add "$HOST_IP" >/dev/null
if banned dovecot || banned postfix-sasl; then echo "FAIL  trusted-client did not lift the ban"; status=1
else echo "PASS  trusted-client lifts an existing ban"; fi
fail_logins
if banned dovecot || banned postfix-sasl; then echo "FAIL  a trusted client was banned again"; status=1
else echo "PASS  a trusted client is never banned"; fi

# Disaster recovery: a new server gets setup.sh with the same answers, then
# backup.sh restore must bring back the mailboxes, passwords, mail, DKIM key,
# aliases and settings of the old one.
log "Restoring the backup onto a new server"
start_container "$NEW_NAME"
if ! docker exec -i "$NEW_NAME" bash -c 'cd /root/mailserver && bash scripts/setup.sh' <<< "$ANSWERS" > /tmp/"$NAME"-run3.log 2>&1; then
    tail -30 /tmp/"$NAME"-run3.log; echo "FAIL  setup on the new server"; exit 1
fi
grep -q 'not set up yet' /tmp/"$NAME"-run3.log && docker exec "$NEW_NAME" test ! -e /etc/mailserver/backup.env \
    || { echo "FAIL  setup without an answer to the backup question must skip backups"; exit 1; }
echo "PASS  setup skips backups when the question gets no answer"
rm -f /tmp/"$NAME"-run3.log
restore_out=$(printf '%s\nmail-test\n\n\ntestkey\ntestsecret\n%s\nRESTORE\n' "$S3_ENDPOINT" "$BACKUP_PW" \
    | docker exec -i -u admin "$NEW_NAME" sudo -n bash /home/admin/mailserver/scripts/backup.sh restore 2>&1) \
    || { echo "$restore_out" | tail -20; echo "FAIL  backup.sh restore"; exit 1; }
echo "PASS  backup.sh restore runs on a new server (through sudo)"
restored() {  # restored NAME COMMAND
    if docker exec "$NEW_NAME" bash -c "$2" >/dev/null 2>&1; then echo "PASS  $1"; else echo "FAIL  $1"; status=1; fi
}
same() {  # same NAME COMMAND: COMMAND prints the same on both servers
    if [[ "$(docker exec "$NAME" bash -c "$2")" == "$(docker exec "$NEW_NAME" bash -c "$2")" ]]; then
        echo "PASS  $1"; else echo "FAIL  $1"; status=1; fi
}
same "mailboxes and password hashes match the old server" "cat /etc/dovecot/users"
same "DKIM key matches the old server" "sha256sum /var/lib/rspamd/dkim/*.key"
same "aliases and send-as grants match" "cat /etc/postfix/virtual /etc/mailserver/send-as 2>/dev/null"
same "mail in the first mailbox matches" "doveadm search -u info@example.test mailbox INBOX all | wc -l"
same "sending limits and exemptions match" "cat /etc/mailserver/send-limit /etc/mailserver/send-limit-exempt"
restored "a trusted webmail client is still exempt from fail2ban" \
    "grep -qx 198.51.100.9 /etc/mailserver/trusted-clients && fail2ban-client get dovecot ignoreip | grep -q 198.51.100.9"
restored "a restored mailbox logs in with its old password" \
    "printf 'Secret123!\n' | doveadm auth test lim1@example.test | grep -q 'auth succeeded'"
restored "services run after the restore" "systemctl is-active --quiet postfix dovecot rspamd redis-server fail2ban && postfix check"
restored "a restored alias delivers" \
    "swaks --server 127.0.0.1 --from ext@gmail.com --to hand@example.test --header 'Subject: after-restore' | grep -q 'queued'
     for _ in {1..20}; do doveadm search -u info@example.test mailbox INBOX subject after-restore | grep -q . && exit 0; sleep 0.5; done; exit 1"
restored "daily backups continue on the new server" "systemctl is-enabled --quiet mailserver-backup.timer"

exit "$status"
