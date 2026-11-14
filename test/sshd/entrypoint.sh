#!/bin/sh
# Install the public key passed in AUTHORIZED_KEY and start sshd
set -e
install -d -o deploy -g deploy -m 700 /home/deploy/.ssh
printf '%s\n' "$AUTHORIZED_KEY" >/home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys
exec /usr/sbin/sshd -D -e
