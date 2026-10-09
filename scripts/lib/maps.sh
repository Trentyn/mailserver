# Postfix maps generated from the mailbox list, aliases and send-as grants.
# shellcheck shell=bash

# Send-as grants, one "<address|@domain> <mailbox>" per line, managed by send-as.sh.
SEND_AS_FILE=/etc/mailserver/send-as

# local_domains: hosted domains, one per line.
local_domains() {
    postconf -h virtual_mailbox_domains 2>/dev/null | tr ', ' '\n\n' | sed '/^$/d'
}

# is_local_domain DOMAIN
is_local_domain() {
    local_domains | grep -Fxq "$1"
}

# sync_postfix_maps: regenerate the derived maps. Running smtpd processes can
# serve one more connection with the old tables, so callers that change rights
# on a live server must reload Postfix afterwards (see apply_postfix_maps).
#
# virtual_mailboxes maps every mailbox to itself. A catch-all alias (@domain)
# would otherwise swallow mail for existing mailboxes, because Postfix tries
# user@domain and then @domain in virtual_alias_maps before it looks at the
# mailbox table.
#
# sender_login_maps lists who may send as each address:
#   - every mailbox owns its own address;
#   - every local mailbox an alias delivers to may send as that alias
#     (a catch-all grants nothing; use send-as.sh for that);
#   - grants from send-as.sh, where "@domain" covers every address of the domain.
# Postfix stops at the first matching key, so a domain grant is also merged into
# each explicit address of that domain.
sync_postfix_maps() {
    install -d -m 0755 /etc/mailserver
    touch "$SEND_AS_FILE" /etc/postfix/virtual /etc/dovecot/users

    awk -F: '$1 != "" && $1 !~ /^#/ {print $1 "\t" $1}' /etc/dovecot/users \
        > /etc/postfix/virtual_mailboxes

    awk '
        function own(key, login) {
            if ((key, login) in seen) return
            seen[key, login] = 1
            if (key in owners) owners[key] = owners[key] "," login
            else owners[key] = login
        }
        FILENAME == ARGV[1] {
            split($0, f, ":")
            if (f[1] != "" && f[1] !~ /^#/) { mailbox[f[1]] = 1; own(f[1], f[1]) }
            next
        }
        FILENAME == ARGV[2] {
            if (NF < 2 || $1 ~ /^#/ || $1 ~ /^@/) next
            targets = $0
            sub(/^[^ \t]+[ \t]+/, "", targets)
            n = split(targets, t, ",")
            for (i = 1; i <= n; i++) {
                gsub(/[ \t]/, "", t[i])
                if (t[i] in mailbox) own($1, t[i])
            }
            next
        }
        FILENAME == ARGV[3] {
            if (NF < 2 || $1 ~ /^#/) next
            own($1, $2)
            if ($1 ~ /^@/) {
                if ($1 in domain_grant) domain_grant[$1] = domain_grant[$1] SUBSEP $2
                else domain_grant[$1] = $2
            }
            next
        }
        END {
            for (key in owners) {
                if (key ~ /^@/) continue
                d = key; sub(/^[^@]*/, "", d)
                if (!(d in domain_grant)) continue
                n = split(domain_grant[d], g, SUBSEP)
                for (i = 1; i <= n; i++) own(key, g[i])
            }
            for (key in owners) print key "\t" owners[key]
        }
    ' /etc/dovecot/users /etc/postfix/virtual "$SEND_AS_FILE" \
        | sort > /etc/postfix/sender_login_maps

    postmap /etc/postfix/virtual /etc/postfix/virtual_mailboxes /etc/postfix/sender_login_maps

    # Installations from before these maps existed get them on first use.
    local alias_maps
    alias_maps=$(postconf -h virtual_alias_maps)
    if [[ "$alias_maps" != *"hash:/etc/postfix/virtual_mailboxes"* ]]; then
        [[ "$alias_maps" == *"hash:/etc/postfix/virtual"* ]] \
            || alias_maps="${alias_maps:+${alias_maps}, }hash:/etc/postfix/virtual"
        postconf -e "virtual_alias_maps = ${alias_maps}, hash:/etc/postfix/virtual_mailboxes"
    fi
}

# apply_postfix_maps: regenerate the maps and make running Postfix use them now.
apply_postfix_maps() {
    sync_postfix_maps
    systemctl reload postfix
}

# prune_aliases ADDRESS|@DOMAIN: forget a deleted mailbox or domain in
# /etc/postfix/virtual. Aliases of it are removed; it is dropped from the target
# lists of other aliases. Prints aliases that lost their last target and were
# therefore removed. Run sync_postfix_maps afterwards.
prune_aliases() {
    local virtual=/etc/postfix/virtual
    [[ -f "$virtual" ]] || return 0
    awk -v m="$1" -v orphans="${virtual}.orphans" '
        function hit(x,   n, a) {
            if (m ~ /^@/) { n = split(x, a, "@"); return n == 2 && "@" a[2] == m }
            return x == m
        }
        NF < 2 || $1 ~ /^#/ { print; next }
        hit($1) { next }
        {
            key = $1; rest = $0
            sub(/^[^ \t]+[ \t]+/, "", rest)
            n = split(rest, t, ","); kept = ""
            for (i = 1; i <= n; i++) {
                gsub(/[ \t]/, "", t[i])
                if (t[i] == "" || hit(t[i])) continue
                if (kept == "") kept = t[i]; else kept = kept ", " t[i]
            }
            if (kept == "") { print key > orphans; next }
            print key "\t" kept
        }
    ' "$virtual" > "${virtual}.tmp"
    cat "${virtual}.tmp" > "$virtual"
    rm -f "${virtual}.tmp"
    if [[ -f "${virtual}.orphans" ]]; then
        cat "${virtual}.orphans"
        rm -f "${virtual}.orphans"
    fi
}
