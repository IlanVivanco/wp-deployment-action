FROM alpine:3.23

LABEL "com.github.actions.name"="WordPress Deployment Action"
LABEL "com.github.actions.description"="Deploy code from GitHub to WordPress on Pressable, WP Engine or any SSH server using an SSH private key and rsync."
LABEL "com.github.actions.color"="red"
LABEL "repository"="https://github.com/IlanVivanco/wp-deployment-action"
LABEL "maintainer"="Ilán Vivanco <ilanvivanco@gmail.com>"

RUN apk add --no-cache bash openssh-client php rsync
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
