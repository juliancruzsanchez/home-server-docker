# Host Setup

How to prepare the machine that runs this stack: operating system, disks,
software RAID, Docker, and the NVIDIA GPU runtime.

- [1. Which OS?](#1-which-os)
- [2. Before you start](#2-before-you-start)
- [3. Ubuntu Server 26.04 LTS (recommended)](#3-ubuntu-server-2604-lts-recommended)
  - [3.1 Install Ubuntu Server](#31-install-ubuntu-server)
  - [3.2 Assemble the software RAID1](#32-assemble-the-software-raid1)
  - [3.3 Mount and persist the array](#33-mount-and-persist-the-array)
  - [3.4 Optional: ZFS instead of mdadm](#34-optional-zfs-instead-of-mdadm)
  - [3.5 Install Docker Engine and Compose](#35-install-docker-engine-and-compose)
  - [3.6 NVIDIA driver and Container Toolkit](#36-nvidia-driver-and-container-toolkit)
  - [3.7 Remote access with Tailscale](#37-remote-access-with-tailscale)
  - [3.8 Deploy the stack](#38-deploy-the-stack)
  - [3.9 Verify](#39-verify)
- [4. Other operating systems](#4-other-operating-systems)
  - [Debian 13 (trixie)](#debian-13-trixie)
  - [Ubuntu 24.04 LTS (noble)](#ubuntu-2404-lts-noble)
  - [Proxmox VE 9](#proxmox-ve-9)
  - [TrueNAS SCALE 25.10](#truenas-scale-2510)
  - [Unraid](#unraid)
  - [Windows / WSL2 and macOS](#windows--wsl2-and-macos)
- [5. Sizing](#5-sizing)
- [6. Troubleshooting](#6-troubleshooting)

---

## 1. Which OS?

**Use Ubuntu Server 26.04 LTS.** It is the most-tested host for this exact
stack, and "most-tested" is doing a lot of work in that sentence.

| OS | Verdict | Why |
| --- | --- | --- |
| **Ubuntu Server 26.04 LTS** | ✅ **Recommended** | Listed in NVIDIA's CUDA 13.3 support table *and* the Container Toolkit's tested-platform list. Dedicated NVIDIA apt repo, Docker's official repo already publishes `resolute`, 5 years of support (to 2031). |
| Debian 13 (trixie) | ✅ Good alternative | ZFS is first-class in `main`. Docker 26.1.5 + Compose 2.26.1 ship in `main`. The NVIDIA path needs more work — see below. |
| Ubuntu 24.04 LTS (noble) | ✅ Fine | Maximum third-party image compatibility, very well trodden. Two years less support life. |
| Proxmox VE 9 | ✅ If you want VMs | Best when you need real isolation for CI or want to run other VMs. Overkill for a Docker-only box. |
| TrueNAS SCALE 25.10 | ⚠️ Storage only | Great ZFS appliance, awkward GPU host. Details below. |
| Unraid | ⚠️ If you want it paid | Easiest NVIDIA-in-Docker story of any consumer option. Licence cost, less scriptable. |
| Windows / macOS | ❌ | SMB + GPU + this compose stack do not fit. |

### Why the OS hinges on NVIDIA

One of the three workloads — the AI endpoint — is entirely dependent on the
NVIDIA Container Runtime being present and registered with the Docker daemon.
Your compose files already use the modern Compose GPU reservation:

```yaml
deploy:
  resources:
    reservations:
      devices:
        - driver: nvidia
          count: all
          capabilities: [gpu]
```

That only works once `nvidia-ctk runtime configure --runtime=docker` has run.
On Debian and Ubuntu that is a supported `apt` install. On appliance operating
systems it frequently is not, and the failure is silent — the container starts
and simply has no GPU.

Ubuntu 26.04 is the release NVIDIA explicitly tests: it appears in the CUDA
13.3 support table, in the Container Toolkit platform list, and it has a
first-party apt repository with driver branches 595 / 610 / 615 / 620.

### Why not TrueNAS SCALE

This repository's layout *looks* TrueNAS-shaped (`${DATA_DIR}` prefixes,
`/mnt/16tb/...` paths), and TrueNAS's Custom App system does consume Compose
files. But it is a poor host for the AI endpoint specifically:

- TrueNAS 25.10 ships NVIDIA's **open** kernel modules, which require the GSP
  chip found in **Turing and newer**. Pascal and older are unsupported.
- `apt` is **disabled** on the appliance host, so a toolkit installed by hand
  is not persistent and does not survive an upgrade.
- `daemon.json` is managed by the iX middleware, which regenerates it. The
  `nvidia` runtime is provisioned by a middleware call rather than by the
  toolkit, so plain `docker run --gpus all` often fails even when `nvidia-smi`
  works.
- GitLab Omnibus is painful to run there.

TrueNAS is a good *storage* appliance. If you want ZFS management, run it on
its own box and point this stack at it over NFS or SMB — or use ZFS on Debian
or Ubuntu directly, as shown below.

---

## 2. Before you start

**Hardware**

- 1 TB SSD (system) and 2 × 16 TB HDD (data, software RAID1)
- NVIDIA GPU. The RTX 4070 Super (12 GB, Ada) is what this was validated on.
- 64 GB RAM recommended — see [Sizing](#5-sizing)

**BIOS / firmware**

- Enable **IOMMU** (Intel VT-d / AMD-Vi) if you ever plan GPU passthrough.
- Enable **Above 4G Decoding** for large GPUs.
- Decide about **Secure Boot** — if it is enabled you must enrol the DKMS
  signing key before the NVIDIA driver will load. See
  [Troubleshooting](#6-troubleshooting).

**Network**

- A DNS name for the server (used as `ROOT_DOMAIN`) with an A/AAAA record
  pointing at it.
- Port 80 reachable from the internet for the first Let's Encrypt issuance,
  or a DNS-01 challenge.

**Accounts**

- `sudo` access to the host.

---

## 3. Ubuntu Server 26.04 LTS (recommended)

### 3.1 Install Ubuntu Server

Install **Ubuntu Server 26.04 LTS** (codename `resolute`) from a USB stick.
During the installer:

| Step | Choice |
| --- | --- |
| Disk | Manual partitioning. Put `/` on the **SSD** (1 TB is plenty — give it ~200 GB and leave the rest unallocated for later, or use all of it). |
| EFI | A 512 MB EFI System Partition on the SSD. |
| Data disks | **Leave both 16 TB disks untouched.** Do not format them, do not create partitions. You will assemble the array after install. |
| Hostname / user | Your choice — the hostname here does not need to match `ROOT_DOMAIN`, but it is less confusing if it does. |
| OpenSSH | Enable it. |
| Snap/lxd/etc | Optional extras are fine; skip them if you want a lean host. |

Finish the install and log in over SSH.

### 3.2 Assemble the software RAID1

**If the array already exists** (you built it in a previous install), just make
sure it is known to initramfs:

```bash
# Confirm the array is present and healthy
cat /proc/mdstat
sudo mdadm --detail /dev/md0

# If /etc/mdadm/mdadm.conf does not already know about it:
sudo bash -c 'echo "DEVICE partitions" > /etc/mdadm/mdadm.conf'
sudo mdadm --detail --scan >> /etc/mdadm/mdadm.conf
sudo update-initramfs -u
```

You should see both drives as active (`[UU]`) and a `State : clean` line.

**If you are building it from scratch:**

```bash
sudo apt update
sudo apt install -y mdadm

# Identify your data disks — check size and confirm they are empty
lsblk -o NAME,SIZE,MODEL,MOUNTPOINTS

# Clear any old filesystem/LVM signatures so mdadm can claim the disks
sudo wipefs -a /dev/sdb /dev/sdc

# Create the mirror
sudo mdadm --create /dev/md0 \
  --level=1 --raid-devices=2 --metadata=1.2 \
  /dev/sdb /dev/sdc

# Persist it across reboots
sudo bash -c 'echo "DEVICE partitions" > /etc/mdadm/mdadm.conf'
sudo mdadm --detail --scan >> /etc/mdadm/mdadm.conf
sudo update-initramfs -u
```

Verify:

```bash
cat /proc/mdstat
# md0 : active raid1 sdc[1] sdb[0]
#       3906882560 blocks super 1.2 [2/2] [UU]
sudo mdadm --detail /dev/md0
```

### 3.3 Mount and persist the array

```bash
# Format (ext4 is the low-maintenance choice; see 3.4 for ZFS)
sudo mkfs.ext4 -L raid1 /dev/md0

sudo mkdir -p /mnt/raid
sudo blkid /dev/md0        # copy the UUID
```

Add to `/etc/fstab` — **use the UUID, not `/dev/md0`**, because md device names
are not stable across reboots:

```
# <file system> <mount point> <type> <options> <dump> <pass>
UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx  /mnt/raid  ext4  defaults,noatime  0  2
```

```bash
sudo mount -a
df -h /mnt/raid
```

`noatime` matters on a media library — it stops the write amplifier from
atime updates on every file read.

### 3.4 Optional: ZFS instead of mdadm

ZFS brings checksums, snapshots, and scrubs on top of the mirror. It is worth
it for a media library. The trade-off is that ZFS manages the disks itself, so
you cannot keep mdadm on top of it.

**This is destructive.** Only do it on disks you are willing to recreate, and
back up anything valuable first.

```bash
sudo apt install -y zfsutils-linux    # 2.4.1 on Ubuntu 26.04

# Tear down the md array and clear its metadata
sudo mdadm --stop /dev/md0
sudo mdadm --zero-superblock /dev/sdb /dev/sdc

# Create a mirrored pool
sudo zpool create tank mirror /dev/sdb /dev/sdc
sudo zfs set compression=zstd tank
sudo zfs set atime=off tank
sudo zfs set mountpoint=/mnt/raid tank

# Make sure it survives a reboot
sudo zpool enable -u tank

# Scrub weekly
echo '[pool weekly scrub]'"$(date +%u)"' 4 00 * 0' | sudo tee /etc/cron.d/zfs-scrub
```

Now update `/etc/fstab` — with `mountpoint` set on the pool, remove the old
md entry:

```
# /mnt/raid is managed by ZFS — no fstab entry needed
```

Verify with `zpool status tank` (both drives should show `ONLINE`) and
`zfs list`.

### 3.5 Install Docker Engine and Compose

Ubuntu's own `docker.io` package works, but Docker's official repository gives
you newer Engine and Compose releases. Compose **v2.20.3 or newer is
required** — this repo uses the top-level `include:` directive.

```bash
sudo apt update
sudo apt install -y ca-certificates curl gnupg

sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo ${UBUNTU_CODENAME}) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

# Let your user run docker without sudo
sudo usermod -aG docker "$USER"
newgrp docker    # or log out and back in

docker --version
docker compose version    # must be >= v2.20.3
```

### 3.6 NVIDIA driver and Container Toolkit

NVIDIA publishes one repository per Ubuntu release. For 26.04 that is
`ubuntu2604`.

```bash
# Add NVIDIA's CUDA repository (it carries both the driver and the toolkit)
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2604/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt update

# Install the driver. 'nvidia-open' uses NVIDIA's open kernel modules,
# which support Turing and newer — including the RTX 4070 Super.
sudo apt install -y nvidia-open
sudo reboot
```

```bash
nvidia-smi
```

You want to see your GPU, a driver version, and a CUDA version. If `nvidia-smi`
fails, see [Troubleshooting](#6-troubleshooting) — Secure Boot is the usual
cause.

Now the Container Toolkit, which is what makes the GPU visible *inside*
containers:

```bash
export NVIDIA_CONTAINER_TOOLKIT_VERSION=1.20.1-1
sudo apt-get install -y \
  nvidia-container-toolkit=${NVIDIA_CONTAINER_TOOLKIT_VERSION} \
  nvidia-container-toolkit-base=${NVIDIA_CONTAINER_TOOLKIT_VERSION} \
  libnvidia-container-tools=${NVIDIA_CONTAINER_TOOLKIT_VERSION} \
  libnvidia-container1=${NVIDIA_CONTAINER_TOOLKIT_VERSION}

# Register the runtime with Docker and restart it
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

Prove it end to end:

```bash
docker run --rm --gpus all ubuntu:26.04 nvidia-smi
```

If that prints your GPU, every GPU service in this stack will work.

<details>
<summary>Prefer an older, longer-tested driver branch?</summary>

The `ubuntu2604` repository currently ships branches 595, 610, 615 and 620.
`nvidia-open` installs the newest (620.x). To pin an older branch:

```bash
sudo apt install -y nvidia-driver-pinning-595 nvidia-open
sudo reboot
nvidia-smi
```

</details>

### 3.7 Remote access with Tailscale

Do not port-forward your whole stack to the open internet. Tailscale gives you
a private network with no inbound ports opened:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

Your services stay reachable at `https://ai.<ROOT_DOMAIN>` from any device on
your tailnet, and nothing is exposed to the internet. If you *do* want public
access, terminate TLS in Caddy and make sure Authentik protects everything —
the config already does this for most routes.

### 3.8 Deploy the stack

```bash
cd ~/home-server-docker

cp .env.example .env
chmod 600 .env
$EDITOR .env

# Generate the random secrets (run once — it appends)
./scripts/generateKeys.sh

# open-webui expects this file to exist
mkdir -p config && touch config/owu.env

# Validate before starting
docker compose config >/dev/null && echo "compose config OK"

docker compose up -d
docker compose ps
```

Set `DATA_DIR` in `.env` to your fast-disk path **with a trailing slash**:

```
DATA_DIR=/mnt/fast/data/
```

Then keep bulk data on the RAID by bind-mounting it into that tree:

```bash
# /etc/fstab — add alongside the /mnt/raid entry
/mnt/raid/media  /mnt/fast/data/media  none  bind  0 0

sudo mkdir -p /mnt/fast/data/media
sudo mount -a
```

Optionally enable the daily docker prune:

```bash
sudo ./scripts/cronSetup.sh
```

### 3.10 Deploy the backup daemon (optional)

The backup daemon lives in its own compose file so it does not start with the
main stack. It needs a **dedicated** SSH key for the backup target — the
container holds the Docker socket, so treat that key as a
host-compromising credential.

```bash
# 1. Create a dedicated key (do NOT reuse your personal key)
sudo mkdir -p /etc/home-server
sudo ssh-keygen -t ed25519 -N '' -f /etc/home-server/backup_key \
  -C 'home-server backup'
sudo chmod 600 /etc/home-server/backup_key

# 2. Install the public key on the backup target
ssh-copy-id -i /etc/home-server/backup_key.pub backup@backup.example.com

# 3. Point the stack at it
cat >> .env <<'EOF'
BACKUP_SSH_KEY_PATH=/etc/home-server/backup_key
REMOTE_HOST=backup.example.com
REMOTE_USER=backup
REMOTE_DEST_DIR=/mnt/16tb/backup
EOF

# 4. Build and start it
docker compose -f docker-compose.backup.yml build
docker compose -f docker-compose.backup.yml up -d
docker compose -f docker-compose.backup.yml logs -f backup-daemon
```

It runs at 04:00 and keeps the main stack up while it works. See
[Backups](../README.md#backups) for the behaviour and the optional image
update and alerting settings.

### 3.9 Verify

```bash
# 1. Containers are up
docker compose ps

# 2. The GPU is visible to Docker
docker run --rm --gpus all ubuntu:26.04 nvidia-smi

# 3. The AI endpoint responds
curl -fsS http://localhost:11434/api/tags | head -c 300

# 4. The reverse proxy answers with a valid certificate
curl -I https://ai.$ROOT_DOMAIN

# 5. The RAID is healthy
cat /proc/mdstat
sudo mdadm --detail /dev/md0
```

If step 3 fails, check that the `open-webui` container is running —
`docker compose logs open-webui`.

---

## 4. Other operating systems

### Debian 13 (trixie)

Debian is the "boring" alternative, and arguably the better choice for ZFS.

**Docker** — both packages ship in `main`:

```bash
sudo apt update
sudo apt install -y docker.io docker-compose
sudo usermod -aG docker "$USER"
```

That gives you Docker Engine 26.1.5 and Compose 2.26.1. Both satisfy this
stack's requirements (Engine ≥ 26.1.0 for the NVIDIA toolkit, Compose ≥ 2.20.3
for `include:`). If you want newer versions, use Docker's official repository
with `debian` instead of `ubuntu` in the URL.

**NVIDIA** — use the same CUDA repository approach, pointed at `debian13`:

```bash
wget https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt update
sudo apt install -y nvidia-open
sudo reboot
```

Debian also ships NVIDIA drivers in `main`. The wiki notes that on trixie the
**proprietary** flavour compiles against the base kernel, while the **open**
flavour needs `trixie-backports`:

```bash
# Debian-packaged alternative
sudo apt install -y nvidia-driver nvidia-kernel-dkms
# or, from backports:
sudo apt install -y -t trixie-backports nvidia-open-kernel-dkms nvidia-driver
```

Prefer the NVIDIA repository route above — it is the same path Ubuntu users
take and it is the one NVIDIA tests.

**ZFS** — first-class in Debian `main`, unlike Ubuntu:

```bash
sudo apt install -y zfsutils-linux    # zfs-linux 2.3.9
```

### Ubuntu 24.04 LTS (noble)

Use this if some image or tool you depend on has not been rebuilt for 26.04
yet. The steps are identical; two paths change:

```bash
# Docker — 'noble' instead of '$(. /etc/os-release && echo ${UBUNTU_CODENAME})'
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# NVIDIA — 'ubuntu2404' instead of 'ubuntu2604'
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt update
sudo apt install -y nvidia-open
```

Everything after that — Container Toolkit, Tailscale, deploying the stack — is
unchanged.

### Proxmox VE 9

Choose this when you want real isolation (run GitLab in its own VM), want to run
other VMs, or want to run the whole stack in a disposable guest that you can
snapshot and rebuild.

Proxmox VE 9 is Debian 13 (trixie) based with kernel 6.17, and supports ZFS
and mdadm natively.

**Plan**

1. Install Proxmox VE 9 on the SSD.
2. Create a Linux VM (Ubuntu 24.04 or Debian 13) for the stack, 16 vCPU, 48 GB
   RAM, and a virtual disk on the SSD.
3. Attach the RAID array to the VM. Either:
   - pass the raw `/dev/md0` through as a virtio disk, or
   - let Proxmox manage the pool directly (`Storage → ZFS` with a mirror on the
     two 16 TB disks) and expose it to the VM.
4. Pass the NVIDIA GPU through with PCIe passthrough. Enable VT-d/AMD-Vi in the
   BIOS first, then bind the GPU to `vfio-pci` on the host and add it to the
   VM.
5. Inside the VM, follow the Ubuntu or Debian section above, unchanged.

**Two caveats**

- Kernel 6.17 shipped AppArmor 5.0.0, which has reported regressions breaking
  LXC and Docker container operations. Check the Proxmox forum and release
  notes for your patch level before committing, and keep a kernel fallback
  selected in the boot menu.
- With the GPU passed through to a VM, the host has no NVIDIA GPU for display
  or transcoding. That is fine — Jellyfin can use the CPU's Intel iGPU via
  `/dev/dri` for QSV instead, which is often better than NVENC anyway.

**Why not just run the stack on the Proxmox host?** You can, via an unprivileged
LXC, but NVIDIA GPU support in LXC is fiddly and you lose the clean
snapshot-and-rollback story. A VM is the honest isolation boundary.

### TrueNAS SCALE 25.10

Usable as the **storage** layer, awkward as the **compute** layer.

If you run this stack in a TrueNAS VM:

- Install the NVIDIA drivers from **System → Advanced Settings**. 25.10 ships
  the open kernel modules, so **Turing or newer only** — Pascal and older will
  not load, and `nvidia-smi` will fail with an unhelpful error.
- The `nvidia` container runtime is provisioned by the iX middleware, not by
  `nvidia-ctk`. Plain `docker run --gpus all` may fail even when `nvidia-smi`
  works. Test it before committing:
  ```bash
  midclt call -job docker.update '{"nvidia": true}'
  docker run --rm --gpus all ubuntu nvidia-smi
  ```
- `apt` is disabled on the appliance host, so anything you install by hand is
  non-persistent.
- Deploy the stack as a **Custom App** (it accepts Compose YAML) rather than
  through the UI.
- GitLab Omnibus will fight you for memory. Put it in a separate VM.

### Unraid

The smoothest NVIDIA-in-Docker experience of any consumer option, at the cost
of a licence and a less automatable setup than a plain Linux host.

- Unraid handles GPU passthrough for Docker natively — pick the NVIDIA card,
  assign it to the Ollama / Automatic1111 / Jellyfin containers.
- The compose stack can be deployed as an Unraid "Docker template" or as a
  `docker-compose` via CA. Because Unraid's paths differ, set `DATA_DIR` to an
  Unraid share path (for example `/mnt/user/appdata`) and mind the trailing
  slash.
- Expect to translate `/dev/dri` group permissions rather than the
  `deploy.resources` GPU blocks, depending on the template.

### Windows / WSL2 and macOS

Not recommended for this stack.

- **WSL2** can work for the AI endpoint alone: the NVIDIA driver on Windows
  exposes the GPU to WSL2 through `/dev/dxg`, and several compose files here
  already contain `openvino-wsl` and `dxg` device variants. But SMB (port 445),
  the media server, and Caddy are a poor fit, and WSL2's filesystem layer
  slows down the heavy database I/O this stack does.
- **macOS** — no NVIDIA GPU, and the SMB and media pieces do not map onto
  Docker Desktop cleanly. Skip it.

---

## 5. Sizing

Rough RAM requirements with everything enabled:

| Service | RAM | Notes |
| --- | --- | --- |
| GitLab Omnibus | 8 GB | Disable the monitoring stack to reclaim ~1.5 GB |
| Jellyfin | 2–4 GB | With NVENC, CPU transcoding needs far more |
| Immich + ML container | 4–6 GB | The ML container holds a model in memory |
| Nextcloud + MySQL | 2 GB | |
| OpenWebUI + Ollama | 4–8 GB | Model weights are on the GPU, but KV cache is in RAM |
| Automatic1111 | 2–4 GB | |
| Authentik + Postgres | 2 GB | |
| Caddy, Portainer, AdGuard, Umami, Wallos, Actual, Radicale, Arr stack | ~2 GB | Combined |
| **Total** | **~28–38 GB** | **64 GB RAM is the comfortable minimum** |

CPU: any modern 8-core server CPU is fine. The workloads are I/O and GPU
bound, not CPU bound — except Jellyfin software transcoding, which you should
avoid by fixing the NVENC capability issue.

Disk: the SSD carries Docker images, databases and Git repositories. Give the
SSD at least 250 GB. The RAID carries media and models.

---

## 6. Troubleshooting

**`nvidia-smi` fails with "couldn't communicate with the NVIDIA driver"**

Almost always Secure Boot. The DKMS module is signed with a local key that
has not been enrolled:

```bash
sudo mokutil --import /var/lib/dkms/mok.pub
sudo reboot       # choose "Enroll MOK" in the blue screen
```

Or disable Secure Boot in the BIOS.

**`docker: Error response from daemon: could not select device driver "" with capabilities: [[gpu]]`**

The Container Toolkit is not registered with Docker:

```bash
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
docker run --rm --gpus all ubuntu:26.04 nvidia-smi
```

**`unknown or invalid runtime name: nvidia`**

The driver did not load, so the runtime was never registered. Run `nvidia-smi`
first — if that fails, fix the driver; the runtime error is a symptom.

**`compose` complains about `include`**

Compose is older than v2.20.3:

```bash
docker compose version
docker compose up -d --remove-orphans    # after upgrading the plugin
```

**`env file ... /config/owu.env not found`**

Expected — `services/openwebui.yml` points at a file the repository does not
ship. Create it, or change the line to `../.env`:

```bash
mkdir -p config && touch config/owu.env
```

**Jellyfin transcodes on the CPU even though you have an NVIDIA GPU**

`NVIDIA_DRIVER_CAPABILITIES` is missing from `services/jellyfin.yml`. The
toolkit defaults to `utility,compute`; you need `video` as well:

```yaml
environment:
  - NVIDIA_VISIBLE_DEVICES=all
  - NVIDIA_DRIVER_CAPABILITIES=compute,utility,video
```

**Containers cannot write to their data directories**

The container UID does not own the directory. Find the GID and fix ownership:

```bash
id
sudo chown -R 1000:1000 /mnt/fast/data/nextcloud
```

**The RAID is degraded**

```bash
cat /proc/mdstat
sudo mdadm --detail /dev/md0
```

A failed drive shows as `[U_]` or `[_U]`. Replace it and rebuild:

```bash
sudo mdadm --manage /dev/md0 --fail /dev/sdc --remove /dev/sdc
# replace the disk, then:
sudo mdadm --manage /dev/md0 --add /dev/sdc
```

**Caddy cannot get a certificate**

Check that port 80 is reachable from the internet, that `ROOT_DOMAIN` resolves
to the server's public IP, and that the system clock is correct:

```bash
timedatectl status
sudo apt install -y chrony && sudo systemctl enable --now chrony
```

**A service will not start and the logs are unhelpful**

```bash
docker compose ps
docker compose logs --tail=100 <service>
docker compose config | head -60    # shows the fully resolved configuration
```
