# home-server-docker

A self-hosted Docker Compose suite for one home server, covering three jobs that
normally want three different machines:

| Job | What runs it |
| --- | --- |
| **Web development CI/CD** | GitLab (forge + CI + registry), Collabora Code for merge-request review |
| **Home media server** | Jellyfin, Sonarr/Radarr/Lidarr, qBittorrent, Nextcloud, Immich, Samba, Radicale |
| **Local AI endpoint** | OpenWebUI + Ollama (OpenAI-compatible API), Automatic1111 for image generation, Immich ML |

Everything runs behind a single Caddy reverse proxy with automatic TLS and
Authentik SSO in front of it. One NVIDIA GPU serves all three: inference and
image generation compute, plus NVENC hardware transcoding for Jellyfin.

> **New here?** Read **[`docs/HOST-SETUP.md`](docs/HOST-SETUP.md)** first — it
> walks through preparing the host machine (disk, software RAID, Docker, NVIDIA
> drivers) and has notes for other operating systems.

---

## Reference hardware

The setup below is written against, and was validated on:

| Component | Spec | Notes |
| --- | --- | --- |
| OS | Ubuntu Server 26.04 LTS (`resolute`) | NVIDIA's most-tested host for a reason — see `docs/HOST-SETUP.md` |
| GPU | NVIDIA RTX 4070 Super | Ada Lovelace, **12 GB VRAM**, NVENC 8th gen with AV1 encode, ~220 W |
| System disk | 1 TB SSD | OS, Docker layers, databases, Git repositories |
| Data disks | 2 × 16 TB HDD, software RAID1 (`mdadm`) | Media, models, backups |

The compose files themselves are not hardware-specific. The 12 GB VRAM figure
does matter though — it sets your model ceiling — so read
[The AI endpoint](#the-ai-endpoint) before picking models.

---

## Quick start

```bash
git clone https://github.com/juliancruzsanchez/home-server-docker.git
cd home-server-docker

cp .env.example .env
chmod 600 .env
$EDITOR .env                      # fill in ROOT_DOMAIN, passwords, secrets

./scripts/generateKeys.sh         # appends AUTHENTIK_SECRET_KEY / UMAMI_APP_SECRET
mkdir -p config && touch config/owu.env   # required by open-webui (see Known issues)

docker compose config >/dev/null && echo "compose config OK"
docker compose up -d
docker compose ps
```

The host needs Docker Engine, the Compose v2 plugin, and the NVIDIA Container
Toolkit. All three are set up in [`docs/HOST-SETUP.md`](docs/HOST-SETUP.md).

### Required DNS

Every service is published as a subdomain of `ROOT_DOMAIN`, so that domain
needs an A/AAAA record pointing at the server (a split-horizon DNS entry on your
LAN is fine). Caddy obtains certificates over HTTP-01, which means port 80
must be reachable from the internet for the initial issuance — or use a DNS
challenge.

---

## Services

| Subdomain | Container | Purpose |
| --- | --- | --- |
| `auth.` | `authentik` | Single sign-on for everything else |
| `vault.` | `vaultwarden` | Password manager |
| `photos.` | `immich` | Photo library + mobile backup |
| `drive.` | `nextcloud` | Files, calendars, contacts |
| `dav.` | `radicale` | Lightweight CalDAV/CardDAV |
| `stream.` | `jellyfin` | Media streaming |
| `stream.` (`/sonarr`, `/radarr`) | `sonarr`, `radarr` | TV and movie automation |
| `lidarr.` | `lidarr` | Music automation |
| `torrent.` | `vuetorrent` | qBittorrent web UI |
| `ai.` | `open-webui` | Chat UI for the local models |
| `git.` | `gitlab` | Git forge + CI/CD (disabled by default) |
| `money.` | `wallos`, `actual-budgeting` | Subscriptions and budgeting |
| `getinfo.` | `umami` | Privacy-friendly analytics |
| `dns.` | `adguardhome` | DNS filtering + admin UI |
| `admin.` | `portainer` | Container management UI |
| — | `samba` | SMB share (LAN only, port 445) |
| — | `openai-edge-tts` | TTS backend for OpenWebUI |
| — | `stable-diffusion` | Automatic1111, internal to the AI network only |
| — | `immich-machine-learning` | Face/object recognition for Immich (GPU) |

Caddy routes are defined in [`services/caddy/Caddyfile`](services/caddy/Caddyfile).

### Services that are present but not deployed

`services/gitlab.yml` and `services/collabora-code.yml` are commented out in
[`docker-compose.yml`](docker-compose.yml). Uncomment them (and create the
Authentik OAuth provider, see below) to enable CI/CD.

---

## Configuration

All configuration lives in a single `.env` file at the repository root.
[`.env.example`](.env.example) is the annotated template and documents every
variable the stack reads.

**Two conventions matter:**

1. **`DATA_DIR` must end with a trailing slash.** The service files mix
   `${DATA_DIR}name` and `${DATA_DIR}/name` styles; a trailing slash makes both
   resolve to the same path. Without it you get paths like `/mnt/fast/datanextcloud`.
2. **`.env` is git-ignored.** Never commit it, never paste it into an issue.
   Set its mode to `600`.

`./scripts/generateKeys.sh` appends the random secrets for Authentik and Umami
to `.env`. It **appends** — running it twice gives you two values for the same
key, and the last one wins. Run it once, then move the keys into place.

### Secrets that were exposed

Two credentials were committed to this repository in plaintext before it went
public, and **remain readable in the git history** regardless of the current
state of the tree:

- the Samba share password (`services/samba.yml`)
- the Automatic1111 Gradio password (`images/stable-diffusion/Dockerfile`)

Both now come from `.env`. **Both must still be rotated** — treat the old
values as compromised and pick new, unrelated ones.

---

## Storage layout

`DATA_DIR` points at the fast disk. Bulk data lives on the RAID1 pool and is
bind-mounted into place, so no compose file needs to change:

```
/mnt/fast/data/          <- DATA_DIR (SSD)   app state: databases, config, Git repos
/mnt/raid/media/         <- RAID1            media library
/mnt/raid/ollama/        <- RAID1            model weights
/mnt/raid/picai/         <- RAID1            Stable Diffusion models
```

To bind-mount the RAID into the app-data tree so `${DATA_DIR}media` resolves to
the RAID automatically:

```bash
# /etc/fstab
/mnt/raid/media  /mnt/fast/data/media  none  bind  0 0
```

**RAID1 is not a backup.** A mirror protects you from a single disk failure,
not from deletion, corruption, or ransomware. Keep the off-site copy that the
backup daemon pushes to `REMOTE_HOST`.

---

## The AI endpoint

OpenWebUI is the front door; Ollama serves the models behind it.

```bash
# OpenAI-compatible API (OpenWebUI's bundled Ollama)
curl http://localhost:11434/api/tags

# Chat UI
open https://ai.$ROOT_DOMAIN
```

**12 GB VRAM is the real constraint.** Practical model ceilings on an RTX 4070 Super:

| Model size | Fits? | Notes |
| --- | --- | --- |
| 7–8B (Q4) | ✅ Comfortable | Fastest, most concurrent users |
| 14B (Q4) | ✅ Comfortable | The sweet spot for code and reasoning |
| 20B (MXFP4/Q4) | ⚠️ Tight | `gpt-oss:20b` runs with reduced context |
| 30B+ | ❌ | Does not fit in 12 GB |

For a production-grade OpenAI-compatible API with proper batching, swap the
bundled Ollama for **vLLM** serving an AWQ-quantised model, and point
OpenWebUI at it instead.

**The GPU is shared three ways.** Ollama inference, Automatic1111 image
generation, and Jellyfin NVENC transcoding all pull from the same card. They
will not saturate it simultaneously in normal use, but a heavy SD render will
make the chat endpoint feel slow.

The Automatic1111 UI is deliberately **not** exposed through Caddy (the
`picai` route is commented out). It is reachable only from OpenWebUI over the
internal `ai_network`.

---

## CI/CD

GitLab is included but disabled by default. To turn it on:

1. Uncomment `./services/gitlab.yml` in `docker-compose.yml`.
2. Create an OpenID Connect provider in Authentik for the GitLab application.
3. Put its client id and secret in `GL_AUTHENTIK_ID` / `GL_AUTHENTIK_SECRET`.
4. Start the stack and complete the initial GitLab root password prompt.

**Give it room.** GitLab Omnibus bundles Postgres, Redis, Puma, Sidekiq, Gitaly
and (in EE) Prometheus, Grafana and Alertmanager. It wants ~8 GB of RAM
minimum. On a shared box, disable the monitoring stack in
`GITLAB_OMNIBUS_CONFIG` — it is worth about 1.5 GB:

```yaml
prometheus_monitoring['enable'] = false
alertmanager['enable'] = false
grafana['enable'] = false
node_exporter['enable'] = false
redis_exporter['enable'] = false
```

Also pin the image tag. `gitlab/gitlab-ee:latest` means an unattended major
upgrade lands whenever the image is pulled.

**Isolate your runner.** A GitLab runner using the Docker executor needs the
Docker socket, which means a build job can reach the whole host — including
your photo library and SMB share. Do not run `privileged: true`, scope the
runner to one project, and set `concurrency: 1`. The safe version runs the
runner inside a VM or LXC.

---

## Media server

Jellyfin transcodes with NVENC on the same NVIDIA card. **Consumer NVIDIA
cards cap concurrent NVENC sessions at 5** — that is a driver limitation, not a
Jellyfin setting. It is fine for a household and worth knowing about if you
add viewers.

The Arr stack (Sonarr/Radarr/Lidarr), qBittorrent, and Jellyfin share
`${DATA_DIR}media` and `${DATA_DIR}torrent/downloads`, so downloads land
directly in the library.

Immich's machine-learning container runs the CUDA backend (via
`services/hwaccel.ml.yml`) for face detection and object recognition. It is
configured correctly, but see the known issue about `NVIDIA_DRIVER_CAPABILITIES`
below — as written, the *whole* GPU path in this stack needs that variable.

---

## Backups

`docker-compose.backup.yml` runs a container that, on a schedule (04:00 by
default), does:

```
docker compose down  →  git pull  →  rsync --delete  →  docker compose up -d
```

It pushes `${DATA_DIR}` to `REMOTE_USER@REMOTE_HOST:${REMOTE_DEST_DIR}` over
SSH.

**Read [Known issues](#known-issues) before trusting it.** As written this
script takes the entire stack offline for the duration of the backup, pulls
unpinned `main` in the middle of the night, and pulls `:latest` images. It is
sensible in spirit and needs rework in detail.

---

## Security notes

- **Port 445 is published on all interfaces.** Samba is LAN-only by
  intention; make sure the router does not forward it.
- **Do not port-forward the whole stack.** Use Tailscale or WireGuard for
  remote access instead of exposing Caddy to the open internet. If you do
  expose Caddy, put Authentik in front (which the config already does).
- **The Immich ML API is published** at `ai.photos.<ROOT_DOMAIN>`. It is an
  internal service and does not need to be reachable from outside.
- **Portainer and the Docker socket.** Portainer mounts
  `/var/run/docker.sock`, which is root-equivalent access to the host.
  Protect it with a strong password and keep it behind Authentik.
- **`collabora-code` runs with `cap_add: dSYS_ADMIN`.** That is a
  broad capability; scope the service if you enable it.
- **The backup container mounts the host's `~/.ssh`.** Use a dedicated
  read-only deploy key rather than your personal key.

---

## Known issues

Found while auditing this repository. None of them are fixed yet — they are
listed here so you do not lose an afternoon to them.

**Blockers**

1. **`open-webui` will not start as-is.** `services/openwebui.yml` declares
   `env_file: ../config/owu.env`, but no `config/` directory exists in the
   repository. Either create it (`mkdir -p config && touch config/owu.env`) or
   switch the line to `../.env`.
2. **NVENC does not work.** `services/jellyfin.yml` sets `runtime: nvidia` and
   `NVIDIA_VISIBLE_DEVICES=all`, but not
   `NVIDIA_DRIVER_CAPABILITIES=compute,utility,video`. The toolkit's default
   is `utility,compute` — without `video` there is no encoder, and Jellyfin
   silently falls back to CPU transcoding.

**Configuration**

3. **`gitlab.yml` uses `gitlab/gitlab-ee:latest`** — unpinned, and it drags in
   the whole Prometheus/Grafana stack. See [CI/CD](#cicd).
4. **`desec-caddy-sync` exits at startup by design.** It syncs Caddy's DNS
   records to deSEC.io and has `restart: no`, so it fails once and stays down
   unless deSEC credentials are present. If you are not hosting DNS at
   deSEC.io that is expected; if you are, add its API token to `.env` (the
   deSEC tooling reads `DESEC_TOKEN`).
5. **`scripts/prune.sh` stops every container** — including itself — via
   `docker stop $(docker ps -q)`.
6. **`scripts/restart.sh` runs compose under `sudo`**, which leaves root-owned
   files in the repository.
7. **`generateKeys.sh` appends rather than replacing.** Running it twice
   duplicates keys.
8. **`images/stable-diffusion/` is never built.** The compose service uses the
   published `jcsdev/automatic1111` image and has no `build:` key, so that
   Dockerfile is dead code.

**Routing**

9. **`admin1.<ROOT_DOMAIN>` is a leftover debug route** pointing at
   `host.docker.internal:19999`. Remove it or point it at something real.
10. **`smb.<ROOT_DOMAIN>` cannot work.** Caddy cannot reverse-proxy SMB; that
    route needs to go. Reach Samba over `smb://` directly.
11. **The `edit.` Caddy block is tab-indented** and points at `collabora-code`,
    which is disabled by default.

**Operations**

12. **The nightly backup daemon takes the whole stack down**, pulls unpinned
    `main`, pulls `:latest` images, and has no alerting if `up -d` fails.
13. **`gitlab.yml` advertises `172.11.0.5`** for memberlist and Prometheus but
    never assigns that static IP, so GitLab's clustering will advertise an
    address it does not hold.
14. **`services/.stable-diffusion.yml.swp`** (a nano swap file) was committed;
    it has been removed in the security fix branch.

---

## Repository layout

```
docker-compose.yml            root stack, pulls in services/*.yml via `include:`
docker-compose.backup.yml     the backup daemon
.env.example                  annotated environment template
services/
  caddy/Caddyfile             routing, TLS, Authentik forward-auth
  caddy/caddy.yml             Caddy + desec-caddy-sync
  <service>.yml               one file per service
  unused/                     services kept but not enabled
images/
  backup/                     the backup daemon image
  stable-diffusion/           optional custom Automatic1111 image (not built)
scripts/
  generateKeys.sh             random secrets for Authentik and Umami
  cronSetup.sh                docker prune cron job
  prune.sh / restart.sh       maintenance helpers
docs/
  HOST-SETUP.md               host OS preparation — read this first
```

`include:` requires **Docker Compose v2.20.3 or newer**. Each included file is
loaded with its own project directory, so relative paths inside a service file
resolve relative to `services/`.

---

## License

Private repository — no license granted. All rights reserved.
