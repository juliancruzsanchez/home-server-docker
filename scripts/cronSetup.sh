echo 'docker system prune -af --filter "until=$((24))h"' >> /etc/cron.daily/docker-prune
sudo chmod +x /etc/cron.daily/docker-prune