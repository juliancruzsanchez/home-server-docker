FROM alpine:3.24

# NOTE: the `docker-compose` package no longer exists in Alpine 3.22+, so
# `apk add docker-compose` fails on alpine:latest and the image never built.
# `docker-cli-compose` ships the Compose v2 plugin that `docker compose` needs.
RUN apk add --no-cache \
    docker-cli \
    docker-cli-compose \
    rsync \
    openssh-client-default \
    dcron \
    curl \
    bash \
    tzdata

WORKDIR /app

COPY update_and_backup.sh .

RUN chmod +x update_and_backup.sh

# 04:00 daily
RUN echo "0 4 * * * /app/update_and_backup.sh >> /var/log/backup.log 2>&1" > /etc/crontabs/root

CMD ["crond", "-f"]
