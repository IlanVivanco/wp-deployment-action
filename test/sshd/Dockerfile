# SSH server used by test/e2e.sh. Listens on 22 and 2222 and fakes WP-CLI.
FROM alpine:3.23
RUN apk add --no-cache bash findutils openssh rsync \
	&& ssh-keygen -A \
	&& printf 'Port 22\nPort 2222\nPasswordAuthentication no\n' >>/etc/ssh/sshd_config \
	&& adduser -D -s /bin/bash deploy \
	&& passwd -u deploy \
	&& printf '#!/bin/sh\necho "$*" >>"$HOME/wp.log"\n' >/usr/local/bin/wp \
	&& chmod +x /usr/local/bin/wp
COPY --chmod=755 entrypoint.sh /usr/local/bin/sshd-entrypoint
CMD ["/usr/local/bin/sshd-entrypoint"]
