#!/bin/bash
# Install the certbot renewal hooks on an existing server and close port 80,
# which the hooks now open only while a renewal runs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/tls.sh
. "$SCRIPT_DIR/lib/tls.sh"
require_root

install_certbot_hooks
ok "Renewal hooks installed"

# Remove the permanent rule an older setup.sh created. A port 80 rule with any
# other comment was added by the administrator and is kept.
if command -v ufw >/dev/null && ufw status | grep -Fq 'HTTP Lets Encrypt'; then
    ufw delete allow 80/tcp >/dev/null
    ok "Closed port 80; it now opens only during certificate renewal"
fi

info "Test a renewal without changing the certificate: sudo certbot renew --dry-run"
