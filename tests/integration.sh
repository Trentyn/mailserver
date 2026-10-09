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

cleanup() {
    if [[ "${KEEP:-0}" == 1 ]]; then
        echo "Container kept: docker exec -it ${NAME} bash"
    else
        docker rm -f "$NAME" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

log "Building ${IMAGE}"
docker build -q --build-arg "DEBIAN_RELEASE=${RELEASE}" -t "$IMAGE" "$REPO_DIR/tests" >/dev/null

log "Starting ${NAME}"
docker run -d --name "$NAME" --hostname mx --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw "$IMAGE" >/dev/null
for _ in {1..30}; do
    state=$(docker exec "$NAME" systemctl is-system-running 2>/dev/null || true)
    [[ "$state" == running || "$state" == degraded ]] && break
    sleep 1
done
docker cp "$REPO_DIR" "$NAME:/root/mailserver"
docker cp "$REPO_DIR" "$NAME:/home/admin/mailserver"
docker exec "$NAME" chown -R admin:admin /home/admin/mailserver

# Answers to the installer prompts, in order: hostname, mail domain, DKIM
# selector, Let's Encrypt email, SSH port (accept the detected one), first
# user, password twice, quota, retention, confirmation, DNS prompt (the test
# domain never resolves), SSH-OK.
ANSWERS=$'mx.example.test\n\n\nadmin@example.test\n\n\nSecret123!\nSecret123!\n\n\ny\nskip\nSSH-OK\n'

# The first run goes as root, the resumed one as a regular user through sudo,
# which drops SSH_CONNECTION; the installer must still find sshd's port 2222.
run_setup_as_root() {
    docker exec -i "$NAME" bash -c 'cd /root/mailserver && bash scripts/setup.sh' <<< "$ANSWERS"
}
run_setup_with_sudo() {
    docker exec -i -u admin -e SSH_CONNECTION= "$NAME" \
        bash -c 'cd ~/mailserver && sudo bash scripts/setup.sh' <<< "$ANSWERS"
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
rm -f /tmp/"$NAME"-run1.log /tmp/"$NAME"-run2.log

log "Checks"
status=0
docker exec "$NAME" bash /root/mailserver/tests/checks.sh || status=1

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

exit "$status"
