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

# Answers to the installer prompts, in order: hostname, mail domain, DKIM
# selector, Let's Encrypt email, SSH port, first user, password twice, quota,
# retention, confirmation, DNS prompt (the test domain never resolves), SSH-OK.
ANSWERS=$'mx.example.test\n\n\nadmin@example.test\n\n\nSecret123!\nSecret123!\n\n\ny\nskip\nSSH-OK\n'

run_setup() {
    docker exec -i "$NAME" bash -c 'cd /root/mailserver && bash scripts/setup.sh' <<< "$ANSWERS"
}

log "Setup with a failing certificate request (must stop cleanly)"
docker exec "$NAME" touch /root/fail-cert
if run_setup > /tmp/"$NAME"-run1.log 2>&1; then
    echo "FAIL: setup succeeded although the certificate request failed"
    exit 1
fi
grep -q 'No certificate was issued' /tmp/"$NAME"-run1.log \
    || { echo "FAIL: missing certificate error"; tail -20 /tmp/"$NAME"-run1.log; exit 1; }
docker exec "$NAME" test ! -e /etc/dovecot/local.conf \
    || { echo "FAIL: mail configs were written before the certificate existed"; exit 1; }
echo "PASS  setup stops before writing mail configs when certbot fails"

log "Setup resumed after fixing the certificate"
docker exec "$NAME" rm /root/fail-cert
if ! run_setup > /tmp/"$NAME"-run2.log 2>&1; then
    tail -40 /tmp/"$NAME"-run2.log
    echo "FAIL: resumed setup did not complete"
    exit 1
fi
grep -q 'Found an unfinished installation' /tmp/"$NAME"-run2.log \
    || { echo "FAIL: resumed run did not detect the unfinished installation"; exit 1; }
echo "PASS  resumed setup completes"
rm -f /tmp/"$NAME"-run1.log /tmp/"$NAME"-run2.log

log "Checks"
docker exec "$NAME" bash /root/mailserver/tests/checks.sh
