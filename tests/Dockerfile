# Debian with systemd as PID 1, close enough to a fresh VPS to run setup.sh.
ARG DEBIAN_RELEASE=trixie
FROM debian:${DEBIAN_RELEASE}

ENV DEBIAN_FRONTEND=noninteractive
# policy-rc.d in the Docker image forbids package scripts from starting
# services; a VPS has no such file.
RUN apt-get update -q \
 && apt-get install -y -q systemd systemd-sysv iproute2 openssl ca-certificates procps \
        openssh-server sudo \
 && apt-get clean \
 && rm -f /usr/sbin/policy-rc.d

# Like a typical VPS: SSH on a non-default port and an admin user with sudo,
# so the test can run the installer through sudo the way people do.
RUN printf 'Port 2222\n' > /etc/ssh/sshd_config.d/port.conf \
 && useradd -m -s /bin/bash admin \
 && printf 'admin ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/admin \
 && chmod 0440 /etc/sudoers.d/admin

# Let's Encrypt cannot reach a container, so certbot issues a self-signed
# certificate instead. It fails while /root/fail-cert exists, which lets the
# test exercise resuming an interrupted installation.
COPY stubs/certbot /usr/local/bin/certbot
# Docker bind-mounts /etc/hostname, so hostnamectl cannot change it.
COPY stubs/hostnamectl /usr/local/bin/hostnamectl
RUN chmod 0755 /usr/local/bin/certbot /usr/local/bin/hostnamectl

CMD ["/sbin/init"]
