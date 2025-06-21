FROM alpine:latest

RUN apk add --no-cache \
    docker-cli \
    docker-compose \
    git \
    rsync \
    openssh-client \
    dcron

WORKDIR /app

COPY update_and_backup.sh .

RUN chmod +x update_and_backup.sh

RUN echo "0 4 * * * /app/update_and_backup.sh >> /var/log/cron.log 2>&1" > /etc/crontabs/root

CMD ["crond", "-f"]

