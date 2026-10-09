# Junk delivery and Bayes training, shared by setup.sh and enable-junk-filtering.sh.
# shellcheck shell=bash

# Rspamd marks spam with X-Rspamd-Deliver-To; Redis stores Bayes statistics.
write_rspamd_junk_config() {
    mkdir -p /etc/rspamd/local.d
    cat > /etc/rspamd/local.d/redis.conf << 'EOF'
servers = "127.0.0.1:6379";
EOF
    cat > /etc/rspamd/local.d/options.inc << 'EOF'
task_timeout = 10s;
EOF
    cat > /etc/rspamd/local.d/milter_headers.conf << 'EOF'
# Mark only messages Rspamd classifies as spam. Dovecot's global Sieve rule
# consumes this marker and files the message into Junk.
use = ["spam-header"];
routines {
  spam-header {
    header = "X-Rspamd-Deliver-To";
    value = "Junk";
    remove = 0;
  }
}
EOF
}

# Sieve files spam into Junk on delivery; IMAPSieve teaches Rspamd when a user
# moves mail into Junk (spam) or out of it (ham). Requires the Dovecot config
# that references these paths to be in place, because sievec reads it.
install_junk_sieve_rules() {
    install -d -o root -g vmail -m 0750 /etc/dovecot/sieve /usr/lib/dovecot/sieve
    cat > /etc/dovecot/sieve/spam-to-junk.sieve << 'EOF'
require ["fileinto", "mailbox"];

if header :is "X-Rspamd-Deliver-To" "Junk" {
    fileinto :create "Junk";
    stop;
}
EOF
    cat > /etc/dovecot/sieve/learn-spam.sieve << 'EOF'
require ["vnd.dovecot.pipe", "copy"];
pipe :copy "rspamd-learn-spam";
EOF
    cat > /etc/dovecot/sieve/learn-ham.sieve << 'EOF'
require ["vnd.dovecot.pipe", "copy", "imapsieve", "environment"];

# Deleting spam is not a ham report.
if environment :is "imap.mailbox" "Trash" {
    stop;
}
pipe :copy "rspamd-learn-ham";
EOF
    cat > /usr/lib/dovecot/sieve/rspamd-learn-spam << 'EOF'
#!/bin/sh
exec /usr/bin/rspamc -h 127.0.0.1:11334 learn_spam
EOF
    cat > /usr/lib/dovecot/sieve/rspamd-learn-ham << 'EOF'
#!/bin/sh
exec /usr/bin/rspamc -h 127.0.0.1:11334 learn_ham
EOF
    local rule
    for rule in spam-to-junk learn-spam learn-ham; do
        sievec -c /etc/dovecot/dovecot.conf "/etc/dovecot/sieve/${rule}.sieve"
    done
    chown root:vmail /etc/dovecot/sieve/* /usr/lib/dovecot/sieve/rspamd-learn-spam /usr/lib/dovecot/sieve/rspamd-learn-ham
    chmod 0640 /etc/dovecot/sieve/*.sieve /etc/dovecot/sieve/*.svbin
    chmod 0750 /usr/lib/dovecot/sieve/rspamd-learn-spam /usr/lib/dovecot/sieve/rspamd-learn-ham
}
