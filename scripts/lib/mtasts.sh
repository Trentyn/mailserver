# MTA-STS and TLS-RPT records, printed by setup.sh and add-domain.sh.
# shellcheck shell=bash
#
# Both are optional and live outside this server: TXT records at the DNS
# provider, and for MTA-STS a small policy file on any HTTPS web server.
# MTA-STS tells other servers to deliver to this domain only over verified TLS
# to the listed MX, so an attacker cannot strip encryption; TLS-RPT asks them
# to send daily reports about TLS problems.

# mta_sts_policy HOSTNAME: the policy file. "testing" only reports problems;
# switch to "enforce" once the TLS reports are clean for a week or two.
mta_sts_policy() {
    printf 'version: STSv1\nmode: testing\nmx: %s\nmax_age: 604800\n' "$1"
}

# print_mta_sts_records DOMAIN HOSTNAME
print_mta_sts_records() {
    local domain="$1" host="$2"
    echo -e "${CYAN}── TLS-RPT (optional) ───────────────────────────────────────${NC}"
    printf "  %-40s  TXT    %s\n" "_smtp._tls.${domain}." "\"v=TLSRPTv1; rua=mailto:postmaster@${domain}\""
    echo
    echo -e "${CYAN}── MTA-STS (optional) ───────────────────────────────────────${NC}"
    printf "  %-40s  TXT    %s\n" "_mta-sts.${domain}." "\"v=STSv1; id=$(date +%Y%m%d%H%M)\""
    echo "  And this file at https://mta-sts.${domain}/.well-known/mta-sts.txt"
    echo "  (any HTTPS web server with a valid certificate for mta-sts.${domain}):"
    mta_sts_policy "$host" | sed 's/^/    /'
    echo "  Change \"mode: testing\" to \"mode: enforce\" once the TLS reports are clean,"
    echo "  and change the id in the TXT record whenever the file changes."
}
