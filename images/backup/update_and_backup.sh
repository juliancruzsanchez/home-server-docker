#!/bin/bash

# --- Configuration (Paths are inside the container) ---
# The project directory is mounted to /app
COMPOSE_DIR="/app"

# The data directory is mounted to /data
BACKUP_SOURCE_DIR="/data"

# Function for logging messages
log() {
  echo "--------------------------------------------------"
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
  echo "--------------------------------------------------"
}

# Navigate to the docker-compose directory
cd "$COMPOSE_DIR" || { echo "Error: Directory $COMPOSE_DIR not found."; exit 1; }

# 1. Stop Docker Compose services
log "Stopping Docker Compose services..."
docker-compose down

# 2. Pull latest changes from Git
log "Pulling latest updates from Git..."
git pull

# 3. Back up persistent data to remote server
log "Backing up persistent data to $REMOTE_HOST..."
# The SSH keys from the host are mounted to /root/.ssh
rsync -avz --delete "$BACKUP_SOURCE_DIR" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DEST_DIR"

# 4. Start Docker Compose services again
log "Starting Docker Compose services..."
docker-compose up -d

log "Update and backup process completed successfully! ✅"
