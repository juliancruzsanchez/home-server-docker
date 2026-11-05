#!/bin/bash
# Nightly backup for the home-server-docker stack.
#
# The previous version of this script ran:
#     docker-compose down -> git pull -> rsync --delete -> docker-compose up -d
# which took the entire stack offline for the whole backup window, pulled
# whatever happened to be on 'main' at 04:00, and pulled ':latest' images on
# top of that. This version keeps the stack up, dumps databases properly, and
# makes image updates opt-in and tag-safe.
#
# Environment:
#   REMOTE_USER / REMOTE_HOST / REMOTE_DEST_DIR   rsync target
#   SSH_KEY_PATH                                  dedicated deploy key
#   AUTO_UPDATE                                   "true" to pull images
#   ALLOW_FLOATING_TAGS                           "true" to allow ':latest' pulls
#   BACKUP_RETENTION_DAYS                         local dump retention
#   ALERT_WEBHOOK_URL                             optional failure webhook

set -euo pipefail

COMPOSE_DIR="/app"
DATA_DIR="/data"
DUMP_DIR="${DATA_DIR}/backups/dumps"
RETENTION="${BACKUP_RETENTION_DAYS:-14}"

log()   { echo "$(date '+%Y-%m-%d %H:%M:%S') - $*"; }
fail()  { log "ERROR: $*"; notify "home-server backup FAILED: $*"; exit 1; }

notify() {
  [ -n "${ALERT_WEBHOOK_URL:-}" ] || return 0
  curl -fsS -m 15 -X POST -H 'Content-Type: application/json' \
    -d "{\"text\":\"$1\"}" "$ALERT_WEBHOOK_URL" >/dev/null 2>&1 \
    || log "WARNING: could not deliver the alert webhook"
}

cd "$COMPOSE_DIR" || fail "compose directory $COMPOSE_DIR not found"

# Never rsync --delete onto the source filesystem.
case "${REMOTE_HOST:-}" in
  ""|localhost|127.0.0.1|0.0.0.0)
    fail "REMOTE_HOST is '${REMOTE_HOST:-}' - refusing to rsync onto the source"
    ;;
esac

STAMP="$(date +%Y%m%d-%H%M%S)"

# Is a compose service up right now?
service_running() {
  local cid
  cid="$(docker compose ps -q "$1" 2>/dev/null || true)"
  [ -n "$cid" ] || return 1
  [ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || echo false)" = "true" ]
}

# --- 1. database dumps -------------------------------------------------------
# Each dump uses the tooling that ships inside the database image, so the
# client version always matches the server version.
mkdir -p "$DUMP_DIR"

dump() {
  local svc="$1"; shift
  if ! service_running "$svc"; then
    log "skipping $svc (not running)"
    return 0
  fi
  local out="${DUMP_DIR}/${svc}-${STAMP}.dump"
  log "dumping $svc"
  if ! docker compose exec -T "$svc" "$@" > "$out" 2>"${out}.err"; then
    log "--- $svc dump stderr ---"
    sed 's/^/    /' "${out}.err" 2>/dev/null || true
    rm -f "$out" "${out}.err"
    fail "dump of $svc failed"
  fi
  rm -f "${out}.err"
  log "  -> $(du -h "$out" | cut -f1) $out"
}

dump immich-db    pg_dumpall -U "${DB_USER:-postgres}"
dump umami-db     pg_dumpall -U "${DB_USER:-postgres}"
dump nextcloud-sql mysqldump -u"${DB_USER}" -p"${DB_PASS}" nextcloud

if service_running gitlab; then
  log "creating a GitLab backup"
  if docker compose exec -T gitlab gitlab-backup create CRON=1 >/dev/null 2>&1; then
    log "  -> GitLab backup created"
  else
    fail "GitLab backup failed"
  fi
fi

# --- 2. prune old dumps ------------------------------------------------------
if [ "$RETENTION" -gt 0 ]; then
  log "removing dumps older than ${RETENTION} days"
  find "$DUMP_DIR" -type f -name '*.dump' -mtime "+${RETENTION}" -print -delete 2>/dev/null | sed 's/^/    /'
fi

# --- 3. rsync to the remote --------------------------------------------------
log "rsyncing ${DATA_DIR} to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DEST_DIR}"
rsync -az \
  --delete --delete-delay \
  --partial \
  -e "ssh -i ${SSH_KEY_PATH} -o StrictHostKeyChecking=accept-new -o BatchMode=yes" \
  "${DATA_DIR}" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DEST_DIR}"

# --- 4. optional image update ------------------------------------------------
# Off by default. Even when enabled it refuses to pull images whose tag
# floats (:latest), because that is how an unattended major upgrade happens.
if [ "${AUTO_UPDATE:-false}" = "true" ]; then
  if ! docker compose config >/dev/null 2>&1; then
    fail "docker compose config is invalid - not updating images"
  fi

  FLOATING="$(docker compose config --images 2>/dev/null | grep -vE ':[0-9]' || true)"
  if [ -n "$FLOATING" ] && [ "${ALLOW_FLOATING_TAGS:-false}" != "true" ]; then
    log "refusing to update - these images use a floating tag:"
    echo "$FLOATING" | sed 's/^/    /'
    fail "set ALLOW_FLOATING_TAGS=true to allow pulling floating tags"
  fi

  log "pulling images and recreating only the containers that changed"
  docker compose pull
  docker compose up -d --remove-orphans
else
  log "AUTO_UPDATE is not enabled - skipping the image update"
fi

# --- 5. sanity check ---------------------------------------------------------
RUNNING="$(docker compose ps --services 2>/dev/null | wc -l | tr -d ' ')"
log "compose project defines ${RUNNING} services"

log "backup complete"
notify "home-server backup completed successfully"
