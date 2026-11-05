#!/usr/bin/env bash
# Install a daily Docker prune job.
#
# Usage:  sudo ./scripts/cronSetup.sh
#
# /etc/cron.daily only runs files that begin with a shebang, and cron silently
# ignores the ones that do not. The job file is rewritten rather than appended
# so that running this script twice does not create duplicate entries.

set -euo pipefail

JOB=/etc/cron.daily/docker-prune

cat > "$JOB" <<'EOF'
#!/bin/sh
# Remove stopped containers, unused images and build cache older than 24h.
docker system prune -af --filter "until=24h" >/dev/null
EOF

chmod +x "$JOB"

echo "Installed $JOB"
