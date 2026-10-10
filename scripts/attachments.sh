#!/bin/bash
# Dangerous attachments are rejected by file type; this is not a virus scanner.
#
#   attachments.sh show                  the policy and recent rejections
#   attachments.sh macros reject         Office files with macros: reject (default)
#   attachments.sh macros junk           ... deliver them to Junk
#   attachments.sh macros allow          ... deliver them normally
#
# Always rejected: executables, scripts, installers, shortcuts and disk images
# (.exe, .js, .ps1, .msi, .lnk, .iso, ...), also inside zip, rar and 7z
# archives and when renamed (an .exe called invoice.pdf). The list follows the
# default attachment filter of Microsoft 365. Encrypted archives that hide
# their file names go to Junk. The sender gets a clear error message.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/attachments.sh
. "$SCRIPT_DIR/lib/attachments.sh"
require_root

usage() { sed -n '2,13s/^# \{0,1\}//p' "$0"; }

case "${1:-}" in
    show)
        [[ $# -eq 1 ]] || { usage >&2; exit 2; }
        echo "Executables, scripts, installers, shortcuts, disk images: rejected"
        echo "Office files with macros (.docm, .xlsm, ...):            $(attachment_macros_policy)"
        echo "Encrypted archives that hide their file names:           Junk"
        echo "Recent rejections:"
        # One "set pre-result" line per rejected message.
        grep -h "set pre-result to 'reject'.*'Attachment .* is not allowed" /var/log/rspamd/rspamd.log 2>/dev/null \
            | sed -E 's/^([0-9-]+ [0-9:]+).*Attachment (.*) is not allowed.*/  \1  \2/' \
            | tail -10 | grep . || echo "  none"
        ;;
    macros)
        [[ $# -eq 2 && "$2" =~ ^(reject|junk|allow)$ ]] || { usage >&2; exit 2; }
        install -d -m 0755 /etc/mailserver
        echo "macros=$2" > "$ATTACHMENTS_FILE"
        write_rspamd_attachment_check
        rspamadm configtest >/dev/null || die "Rspamd rejected the new configuration"
        systemctl reload rspamd
        ok "Office files with macros: $2"
        ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
esac
