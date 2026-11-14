#!/bin/sh
# Install the public key passed in AUTHORIZED_KEY and start sshd
set -e
install -d -o deploy -g deploy -m 700 /home/deploy/.ssh
printf '%s\n' "$AUTHORIZED_KEY" >/home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys
# OpenSSH 9.8+ would block the tests' repeated connections; older sshd rejects the option
if /usr/sbin/sshd -t -o PerSourcePenalties=no 2>/dev/null; then
	echo "PerSourcePenalties no" >>/etc/ssh/sshd_config
fi
exec /usr/sbin/sshd -D -e
