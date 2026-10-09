# Certbot renewal hooks, shared by setup.sh and install-renewal-hooks.sh.
# shellcheck shell=bash

# Port 80 is only needed while certbot proves domain ownership, so it stays
# closed and the pre/post hooks open it for the duration of a renewal. A port 80
# rule the administrator added on purpose (for a web server) is left alone.
install_certbot_hooks() {
    mkdir -p /etc/letsencrypt/renewal-hooks/{pre,post,deploy}

    cat > /etc/letsencrypt/renewal-hooks/pre/mailserver-open-http.sh << 'EOF'
#!/bin/bash
# Managed by mailserver: open port 80 for the certbot HTTP challenge.
command -v ufw >/dev/null || exit 0
ufw status | grep -q '^Status: active' || exit 0
ufw status | grep -Eq '^80(/tcp)? +ALLOW' && exit 0
ufw allow 80/tcp comment 'certbot renewal (temporary)' >/dev/null
touch /run/mailserver-http-opened
EOF

    cat > /etc/letsencrypt/renewal-hooks/post/mailserver-close-http.sh << 'EOF'
#!/bin/bash
# Managed by mailserver: close port 80 again if the pre hook opened it.
[[ -e /run/mailserver-http-opened ]] || exit 0
ufw delete allow 80/tcp >/dev/null
rm -f /run/mailserver-http-opened
EOF

    # Fix key permissions and reload services after every successful renewal.
    cat > /etc/letsencrypt/renewal-hooks/deploy/reload-mail.sh << 'EOF'
#!/bin/bash
for d in /etc/letsencrypt/live/*/privkey.pem; do
    chown root:dovecot "$d"
    chmod 640 "$d"
done
systemctl reload postfix dovecot rspamd
EOF

    chmod 0755 /etc/letsencrypt/renewal-hooks/pre/mailserver-open-http.sh \
        /etc/letsencrypt/renewal-hooks/post/mailserver-close-http.sh \
        /etc/letsencrypt/renewal-hooks/deploy/reload-mail.sh
}
