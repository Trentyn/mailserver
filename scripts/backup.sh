#!/bin/bash
# Encrypted daily backups to S3-compatible storage (AWS S3, Backblaze B2,
# Wasabi, Hetzner, MinIO and others) with restic.
#
#   backup.sh setup                      connect to a bucket, start daily backups
#   backup.sh run                        back up now
#   backup.sh list                       show the backups (snapshots)
#   backup.sh restore [SNAPSHOT]         restore this whole server (new VPS)
#   backup.sh restore-mailbox EMAIL [SNAPSHOT]   bring back deleted mail
#   backup.sh check                      verify that the backups are readable
#
# SNAPSHOT defaults to the newest backup. Backed up: all mail, mailboxes and
# passwords hashes, aliases and send-as grants, DKIM keys, Postfix, Dovecot
# and Rspamd configuration, spam training and sending limits. Kept: 7 daily,
# 4 weekly and 12 monthly backups.
#
# Restoring onto a new VPS: run setup.sh there with the same mail host name,
# then "backup.sh restore". It asks for the bucket and the backup password.
# The answers can also come from BACKUP_S3_ENDPOINT, BACKUP_S3_BUCKET,
# BACKUP_S3_FOLDER, BACKUP_S3_REGION, BACKUP_S3_ACCESS_KEY,
# BACKUP_S3_SECRET_KEY and BACKUP_PASSWORD (see setup.conf.example).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/maps.sh
. "$SCRIPT_DIR/lib/maps.sh"
# shellcheck source=lib/password.sh
. "$SCRIPT_DIR/lib/password.sh"
# shellcheck source=lib/pop3.sh
. "$SCRIPT_DIR/lib/pop3.sh"
require_root

usage() { sed -n '2,23s/^# \{0,1\}//p' "$0"; }

ENV_FILE=/etc/mailserver/backup.env
LAST_FILE=/etc/mailserver/backup-last
export RESTIC_CACHE_DIR=/var/cache/restic
BACKUP_PATHS=(
    /var/mail/vhosts
    /etc/postfix
    /etc/dovecot
    /etc/rspamd/local.d
    /etc/rspamd/dkim_selectors.map
    /var/lib/rspamd/dkim
    /etc/mailserver
    /etc/fail2ban/jail.d/mailserver-trusted.local
    /var/lib/redis/dump.rdb
)

need_restic() {
    command -v restic >/dev/null && return 0
    info "Installing restic"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q restic >/dev/null
}

load_env() {
    [[ -r "$ENV_FILE" ]] || die "Backups are not set up yet. Run: sudo bash $0 setup"
    set -a
    # shellcheck source=/dev/null
    . "$ENV_FILE"
    set +a
}

# probe_repository: 0 = opened, 10 = no repository there, 12 = wrong password,
# anything else = storage unreachable or keys rejected. restic keeps retrying
# rejected requests for minutes, so give up after one.
probe_repository() {
    local out rc=0
    out=$(timeout 60 restic cat config 2>&1 >/dev/null) || rc=$?
    # restic before 0.17 (Debian 12) has no dedicated exit codes.
    if (( rc == 1 )); then
        if grep -q 'wrong password' <<< "$out"; then rc=12
        elif grep -Eq 'does not exist|Is there a repository' <<< "$out"; then rc=10
        fi
    fi
    PROBE_OUTPUT="$out"
    return "$rc"
}

read_required() {  # read_required PROMPT [DEFAULT] [silent]
    local val
    while true; do
        if [[ -n "${2:-}" ]]; then ask "$1 [$2]:"; else ask "$1:"; fi
        if [[ "${3:-}" == silent ]]; then read -rs val; echo; else read -r val; fi
        val="${val:-${2:-}}"
        [[ -n "$val" ]] && { REPLY="$val"; return; }
        warn "A value is required"
    done
}

# Preset: the S3 settings come from BACKUP_* variables (setup.sh --config,
# cloud-init, Ansible) instead of questions. Unset optional ones take their
# defaults then, and required ones must be set.
preset() { [[ "${MAILSERVER_NONINTERACTIVE:-0}" == 1 || -n "${BACKUP_S3_BUCKET:-}" ]]; }

# answer VAR PROMPT [DEFAULT] [silent]: REPLY from the variable VAR, otherwise
# asked, or with a preset the default.
answer() {
    local var="$1"
    if [[ -n "${!var:-}" ]]; then REPLY="${!var}"; return; fi
    if preset; then
        [[ -n "${3:-}" ]] || die "${var} is required for backups"
        REPLY="$3"
        return
    fi
    read_required "$2" "${3:-}" "${4:-}"
}

# configure_repository MODE: ask for the bucket and keys and write ENV_FILE.
# MODE "new" may create the repository; "existing" must find one.
# Sets REPO_STATE to "new" or "existing".
configure_repository() {
    local mode="$1" endpoint bucket folder region key secret rc
    if ! preset; then
        echo "S3 endpoint examples: https://s3.amazonaws.com, https://s3.eu-central-003.backblazeb2.com,"
        echo "https://s3.eu-central-1.wasabisys.com, https://fsn1.your-objectstorage.com (Hetzner)"
    fi
    answer BACKUP_S3_ENDPOINT "S3 endpoint" "https://s3.amazonaws.com"; endpoint="${REPLY%/}"
    [[ "$endpoint" =~ ^https?://[^/]+$ ]] || die "The endpoint must look like https://host"
    answer BACKUP_S3_BUCKET "Bucket name"; bucket="$REPLY"
    answer BACKUP_S3_FOLDER "Folder in the bucket" "mail-backup"; folder="${REPLY#/}"; folder="${folder%/}"
    if preset; then
        region="${BACKUP_S3_REGION:-}"
    else
        ask "Region (Enter if unsure):"; read -r region
    fi
    answer BACKUP_S3_ACCESS_KEY "Access key ID"; key="$REPLY"
    answer BACKUP_S3_SECRET_KEY "Secret access key" "" silent; secret="$REPLY"

    export RESTIC_REPOSITORY="s3:${endpoint}/${bucket}/${folder}"
    export AWS_ACCESS_KEY_ID="$key" AWS_SECRET_ACCESS_KEY="$secret"
    if [[ -n "$region" ]]; then export AWS_DEFAULT_REGION="$region"; else unset AWS_DEFAULT_REGION; fi

    # A random password tells "no repository" (10) from "repository" (12).
    export RESTIC_PASSWORD
    RESTIC_PASSWORD=$(generate_password)
    info "Connecting to ${RESTIC_REPOSITORY}"
    rc=0; probe_repository || rc=$?
    case "$rc" in
        10)
            [[ "$mode" == new ]] || die "No backup was found at ${RESTIC_REPOSITORY}"
            RESTIC_PASSWORD="${BACKUP_PASSWORD:-$(generate_password)$(generate_password)}"
            restic init >/dev/null || die "Could not create the backup repository"
            REPO_STATE=new
            ;;
        12)
            while true; do
                answer BACKUP_PASSWORD "Backup password of the existing repository" "" silent
                RESTIC_PASSWORD="$REPLY"
                rc=0; probe_repository || rc=$?
                (( rc == 0 )) && break
                (( rc == 12 )) || die "Cannot open the repository: ${PROBE_OUTPUT}"
                [[ -z "${BACKUP_PASSWORD:-}" ]] || die "BACKUP_PASSWORD is wrong for ${RESTIC_REPOSITORY}"
                warn "Wrong password, try again"
            done
            REPO_STATE=existing
            ;;
        124)
            die "No answer from S3 within 60 seconds. Check the endpoint, bucket, region and keys."
            ;;
        *)
            echo "$PROBE_OUTPUT" | tail -5 >&2
            die "Cannot reach the bucket. Check the endpoint, bucket, region and keys."
            ;;
    esac

    install -d -m 0755 /etc/mailserver
    (
        umask 077
        {
            echo "# Managed by backup.sh. Holds the S3 keys and the backup password: root only."
            printf 'RESTIC_REPOSITORY=%q\n' "$RESTIC_REPOSITORY"
            printf 'AWS_ACCESS_KEY_ID=%q\n' "$AWS_ACCESS_KEY_ID"
            printf 'AWS_SECRET_ACCESS_KEY=%q\n' "$AWS_SECRET_ACCESS_KEY"
            [[ -n "$region" ]] && printf 'AWS_DEFAULT_REGION=%q\n' "$region"
            printf 'RESTIC_PASSWORD=%q\n' "$RESTIC_PASSWORD"
        } > "$ENV_FILE"
    )
    chmod 600 "$ENV_FILE"
}

install_timer() {
    cat > /etc/systemd/system/mailserver-backup.service << EOF
[Unit]
Description=Back up the mail server to S3
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash ${SCRIPT_DIR}/backup.sh run
Nice=10
IOSchedulingClass=idle
EOF
    cat > /etc/systemd/system/mailserver-backup.timer << 'EOF'
[Unit]
Description=Daily mail server backup

[Timer]
OnCalendar=*-*-* 03:30
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now mailserver-backup.timer >/dev/null 2>&1
}

run_backup() {
    local paths=() p
    # Bayes statistics live in Redis memory; write them to dump.rdb first.
    if systemctl is-active --quiet redis-server; then
        redis-cli -h 127.0.0.1 SAVE >/dev/null 2>&1 || warn "Redis did not save; spam training may be out of date"
    fi
    for p in "${BACKUP_PATHS[@]}"; do
        [[ -e "$p" ]] && paths+=("$p")
    done
    restic backup --tag mailserver \
        --exclude "$ENV_FILE" --exclude "$LAST_FILE" "${paths[@]}"
    restic forget --tag mailserver --group-by host,tags \
        --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune >/dev/null
    date -Is > "$LAST_FILE"
}

resolve_snapshot() {  # resolve_snapshot [ID]: prints a snapshot ID or dies
    local id="${1:-latest}" found
    found=$(restic snapshots --tag mailserver --json "$id" 2>/dev/null \
        | grep -o '"short_id":"[0-9a-f]*"' | tail -1 | cut -d'"' -f4) || true
    [[ -n "$found" ]] || die "Backup '${id}' was not found. List them with: sudo bash $0 list"
    echo "$found"
}

ACTION="${1:-}"
case "$ACTION" in
    setup)
        [[ $# -eq 1 ]] || { usage >&2; exit 2; }
        [[ -f /etc/postfix/main.cf ]] || die "Install the mail server first: sudo bash ${SCRIPT_DIR}/setup.sh"
        need_restic
        step "Backup storage"
        configure_repository new
        if [[ "$REPO_STATE" == existing ]]; then
            COUNT=$(restic snapshots --tag mailserver --json | grep -o '"short_id"' | wc -l)
            warn "This folder already holds ${COUNT} backups."
            if [[ "${MAILSERVER_NONINTERACTIVE:-0}" == 1 ]]; then
                info "Adding this server's backups to it (non-interactive run)"
            else
                warn "To restore this server from them, answer N and run: sudo bash $0 restore"
                ask "Add this server's backups to it? [y/N]:"
                read -r confirm
                [[ "${confirm,,}" == y ]] || { rm -f "$ENV_FILE"; info "Cancelled."; exit 0; }
            fi
        else
            ok "Created an encrypted backup repository"
            if [[ -n "${BACKUP_PASSWORD:-}" ]]; then
                info "The backup password is the BACKUP_PASSWORD you gave"
            elif [[ "${MAILSERVER_NONINTERACTIVE:-0}" == 1 ]]; then
                # Never print it into cloud-init or Ansible logs.
                warn "A backup password was generated and stored only in ${ENV_FILE} (root only)."
                warn "Copy it to a password manager: restoring onto a new server needs it."
            else
                echo
                echo -e "  ${BOLD}Backup password:${NC}  ${BOLD}${GREEN}${RESTIC_PASSWORD}${NC}"
                warn "Without this password the backups cannot be read, and restoring onto a"
                warn "new server needs it. Store it outside this server, in a password manager."
                warn "It is shown only now; this server keeps a root-only copy in ${ENV_FILE}."
            fi
        fi
        install_timer
        ok "Daily backups at about 03:30"
        step "First backup"
        run_backup
        ok "Backup complete"
        ;;
    run)
        [[ $# -eq 1 ]] || { usage >&2; exit 2; }
        load_env
        need_restic
        exec 9> /run/mailserver-backup.lock
        flock -n 9 || die "Another backup is running"
        run_backup
        ;;
    list)
        load_env
        restic snapshots --tag mailserver --compact
        [[ -f "$LAST_FILE" ]] && info "Last successful backup: $(cat "$LAST_FILE")"
        ;;
    check)
        load_env
        restic check --read-data-subset=5%
        ;;
    restore)
        [[ $# -le 2 ]] || { usage >&2; exit 2; }
        [[ -f /etc/postfix/main.cf ]] \
            || die "Run setup.sh first with the same mail host name, then restore"
        need_restic
        if [[ -r "$ENV_FILE" ]]; then
            load_env
        else
            step "Backup storage"
            configure_repository existing
        fi
        SNAP=$(resolve_snapshot "${2:-}")
        HOST_THEN=$(restic dump "$SNAP" /etc/postfix/main.cf | awk -F' *= *' '$1 == "myhostname" {print $2}')
        HOST_NOW=$(postconf -h myhostname)
        [[ "$HOST_THEN" == "$HOST_NOW" ]] \
            || die "The backup is of ${HOST_THEN:-an unknown host}, this server is ${HOST_NOW}. Run setup.sh with ${HOST_THEN} first."
        restic snapshots --compact "$SNAP"
        warn "This replaces the mailboxes, mail and configuration on this server with backup ${SNAP}."
        ask "Type RESTORE to continue:"
        read -r confirm
        [[ "$confirm" == RESTORE ]] || { info "Cancelled."; exit 0; }

        step "Restoring ${SNAP}"
        systemctl stop postfix dovecot rspamd redis-server
        restic restore "$SNAP" --target /
        # User and group IDs can differ on a new server; set owners by name.
        chown -R vmail:vmail /var/mail/vhosts
        chown root:dovecot /etc/dovecot/users && chmod 640 /etc/dovecot/users
        [[ -d /etc/dovecot/sieve ]] && chown -R root:vmail /etc/dovecot/sieve
        chown -R _rspamd:_rspamd /var/lib/rspamd/dkim
        chmod 700 /var/lib/rspamd/dkim && chmod 440 /var/lib/rspamd/dkim/*.key
        [[ -f /var/lib/redis/dump.rdb ]] && chown redis:redis /var/lib/redis/dump.rdb
        postmap /etc/postfix/vmailbox
        sync_postfix_maps
        systemctl start redis-server rspamd dovecot postfix
        systemctl reload fail2ban 2>/dev/null || true
        # The restored Dovecot config decides about POP3; open or close its ports.
        sync_pop3_firewall
        install_timer
        ok "Restored $(cut -d: -f1 /etc/dovecot/users | grep -c .) mailboxes from backup ${SNAP}"
        info "Daily backups continue into the same storage. Check: sudo bash ${SCRIPT_DIR}/verify-mailserver.sh"
        ;;
    restore-mailbox)
        [[ $# -ge 2 && $# -le 3 ]] || { usage >&2; exit 2; }
        EMAIL="${2,,}"
        has_user "$EMAIL" || die "Mailbox ${EMAIL} does not exist"
        load_env
        need_restic
        SNAP=$(resolve_snapshot "${3:-}")
        DIR="/var/mail/vhosts/${EMAIL#*@}/${EMAIL%@*}"
        TMP=$(mktemp -d /var/tmp/mailserver-restore.XXXXXX)
        trap 'rm -rf "$TMP"' EXIT
        restic restore "$SNAP" --target "$TMP" --include "$DIR" >/dev/null
        [[ -d "$TMP$DIR" ]] || die "Backup ${SNAP} has no mail for ${EMAIL}"

        # Maildir keeps the read/replied flags in the file name after ':', so
        # compare the part before it: only messages missing now are copied back.
        declare -A HAVE=()
        msg_key() { local k="${1/\/cur\//\/}"; k="${k/\/new\//\/}"; printf '%s' "${k%%:*}"; }
        while IFS= read -r f; do
            HAVE["$(msg_key "$f")"]=1
        done < <(cd "$DIR" && find . -type f \( -path '*/cur/*' -o -path '*/new/*' \))
        RESTORED=0
        while IFS= read -r f; do
            [[ -n "${HAVE["$(msg_key "$f")"]:-}" ]] && continue
            install -d -o vmail -g vmail -m 700 "$DIR/$(dirname "$f")" "$DIR/$(dirname "$(dirname "$f")")/tmp"
            cp -p "$TMP$DIR/$f" "$DIR/$f"
            chown vmail:vmail "$DIR/$f"
            RESTORED=$((RESTORED + 1))
        done < <(cd "$TMP$DIR" && find . -type f \( -path '*/cur/*' -o -path '*/new/*' \))
        doveadm force-resync -u "$EMAIL" '*' >/dev/null 2>&1 || true
        ok "Restored ${RESTORED} messages to ${EMAIL} from backup ${SNAP}"
        ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
esac
