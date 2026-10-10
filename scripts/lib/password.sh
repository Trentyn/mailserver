# Mailbox passwords. A password is never written to disk, never placed on a
# command line (where ps shows it to every local user) and is shown at most
# once, when the server generated it. Only its hash is stored.
# shellcheck shell=bash

# 20 characters without look-alikes (0/O, 1/l/I): about 115 bits.
generate_password() {
    local pw
    pw=$(head -c 2048 /dev/urandom | LC_ALL=C tr -dc 'A-HJ-NP-Za-km-z2-9')
    printf '%s' "${pw:0:20}"
}

# hash_password PASSWORD: the SHA512-CRYPT hash for /etc/dovecot/users.
# doveadm reads the password twice from stdin when there is no terminal.
hash_password() {
    local hash
    hash=$(printf '%s\n%s\n' "$1" "$1" | doveadm pw -s SHA512-CRYPT 2>/dev/null)
    [[ "$hash" == '{SHA512-CRYPT}$6$'* ]] || die "doveadm could not hash the password"
    printf '%s' "$hash"
}

# auth_ok EMAIL PASSWORD: Dovecot accepts the password.
auth_ok() {
    local out
    out=$(printf '%s\n' "$2" | doveadm auth test "$1" 2>&1) || true
    grep -q 'auth succeeded' <<< "$out"
}

# read_new_password LABEL: ask twice, or generate one when the answer is empty.
# Sets NEW_PASSWORD and PASSWORD_GENERATED (true or false).
# shellcheck disable=SC2034  # Both are read by the calling script.
read_new_password() {
    local confirm
    while true; do
        ask "$1 (Enter to generate a strong one):"
        read -rs NEW_PASSWORD; echo
        if [[ -z "$NEW_PASSWORD" ]]; then
            NEW_PASSWORD=$(generate_password)
            PASSWORD_GENERATED=true
            return
        fi
        if (( ${#NEW_PASSWORD} < 8 )); then
            warn "Use at least 8 characters"
            continue
        fi
        ask "Repeat the password:"
        read -rs confirm; echo
        if [[ "$NEW_PASSWORD" == "$confirm" ]]; then
            PASSWORD_GENERATED=false
            return
        fi
        warn "The passwords do not match, try again"
    done
}

# show_password_once EMAIL PASSWORD: the only time a generated password appears.
show_password_once() {
    echo
    echo -e "  ${BOLD}Password for $1:${NC}  ${BOLD}${GREEN}$2${NC}"
    warn "Shown only now and stored nowhere. Save it in a password manager."
}
