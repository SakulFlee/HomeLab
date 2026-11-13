# HomeLab v2 — Debian 13 + Docker

Status: plan for review. This branch (`v2`) is the clean Docker tree. `main`
remains the working NixOS configuration until cutover.

## 1. Goal

Replace the NixOS + Incus + OpenTofu host with a Debian 13 host running Docker
Compose. Keep every current service except `ttyd` and the Incus UI. Only four
services carry data that must be preserved: **Forgejo, Fluxer, Minecraft and
Hytale**.

The host keeps the LAN address `192.168.178.200`. Public services stay public;
administrative services stay on the LAN or WireGuard VPN.

## 2. Decisions

| Area | Decision |
| --- | --- |
| Base OS | Debian 13 stable on the homelab host |
| Workloads | Docker Compose, bind mounts under `/srv/docker` |
| Host config | systemd units and timers, shell scripts in this repo |
| Repo | `v2` branch; `main` stays NixOS until cutover |
| VPN | `wg-easy`, subnet `100.64.0.0/24`, full-tunnel profile supported |
| Public entry | Caddy on `:80/:443`, Cloudflare DNS-01 |
| DNS | CoreDNS container with split-horizon admin names |
| Admin UI | Dockge, LAN/VPN only |
| Deploy | host systemd timer pulls Git and runs `deploy.sh` |
| CI | Forgejo runner is CI-only, not the deploy path |
| Backup | local restic repo on SATA + repo snapshots + `restic copy` to Dendra |
| NAS | not used |
| Laptop | staging host and temporary-production fallback |
| Dendra | off-box restic copy target, online roughly 12h/day |

Dropped: `ttyd`, Incus UI, Incus, OpenTofu, NixOS modules and the image
pipeline.

## 3. Host layout

### Disks

| Disk | Contents |
| --- | --- |
| NVMe 1TB | Debian root, `/boot`, `/home`, `/var/lib/docker`, live data `/srv/docker` |
| SATA SSD 1TB | `/srv/backup` — restic repo, dumps, btrfs repo snapshots |

Suggested btrfs subvolumes:

```text
NVMe:
  @          /
  @home      /home
  @log       /var/log
  @pkg       /var/cache/apt
  @docker    /var/lib/docker
  @srv       /srv/docker

SATA:
  @backup    /srv/backup
```

`/srv/backup` contains:

```text
/srv/backup/restic/             restic repository
/srv/backup/dumps/              pg_dump and game archives before restic
/srv/backup/repo-snapshots/     btrfs snapshots of the restic repo
```

Rules:

- `docker.service` depends on the `/srv` mount.
- The backup service fails if `/srv/backup` is missing.
- The SATA disk is not formatted until live data is restored to the NVMe and
  verified.
- `snapper` for root snapshots; `fstrim.timer`, `btrfs-scrub.timer`, `smartd`.
- `zram` for swap, optional small swapfile.

### SSH ports

| Port | Service | Notes |
| --- | --- | --- |
| `22/tcp` | Forgejo Git SSH | Published by the Forgejo container |
| `2222/tcp` | Host OS SSH | Debian `sshd`, key-only |
| `2222/tcp` | dropbear-initramfs | Only during initramfs, before host sshd starts |

Forgejo keeps port 22 so existing clone URLs do not change. The host runs its
own SSH on 2222. This is easy with Docker: `22:22` is published by Forgejo and
the host `sshd` is configured on 2222.

`dropbear-initramfs` will also listen on 2222 during initramfs. Host `sshd` and
dropbear are not active at the same time (dropbear exists only in the initramfs
phase), so the port number can be the same. The consequence is that the same
`host:2222` has a different SSH host key before and after boot. Client
`known_hosts` may complain. Options:

- keep 2222 and use a `HostKeyAlias`/separate SSH config entry for the
  initramfs host, or
- move dropbear to 2223.

Default plan: keep dropbear on 2222, document the known_hosts caveat, and use a
separate SSH config alias if needed.

### LUKS + remote unlock

- Root filesystem on LUKS.
- `cryptsetup-initramfs` and `dropbear-initramfs`.
- Network configured in the initramfs (DHCP or static `192.168.178.200`).
- Authorized key in `/etc/dropbear/initramfs/authorized_keys`.
- Remote unlock with `cryptroot-unlock` over SSH to port 2222.
- Host SSH on 2222 after boot.
- Keep a local console/physical access path and a recovery key.
- Add an initramfs SSH host key note to the docs; the pre-boot key differs from
  the post-boot host key.

## 4. Target architecture

```text
Homelab host (Debian 13)
├── Caddy                 public :80/:443
├── CoreDNS               split-horizon DNS, :53
├── wg-easy               WireGuard + UI, :51820/udp, :51821
├── Dockge                admin UI, :5001, LAN/VPN only
├── Forgejo + PostgreSQL   public, SSH :22
├── Fluxer stack          public, LiveKit :7881/tcp :7882/udp
├── Minecraft             public :25565/tcp
├── Hytale                public :5520/udp
├── Syncthing             personal files / game archives
├── OpenCode              admin, :4096
├── Forgejo runner        CI only
├── Cloudflare DDNS
├── Renovate
└── Website
```

All HTTP backends join the external Docker network `proxy`. Service data is
bind-mounted under `/srv/docker/<service>`.

## 5. Service inventory

| Service | Data | Migration |
| --- | --- | --- |
| Forgejo | yes | Postgres dump + `/var/lib/forgejo/data` + `custom/conf` + SSH/GPG keys |
| Fluxer | yes | Postgres + SeaweedFS + other named volumes; `.env` from sops |
| Minecraft | yes | `/var/lib/minecraft` |
| Hytale | yes | `/var/lib/hytale` + `hytale-secrets` + `.machine-id` + `auth.enc` |
| Caddy | certs only | recreate; optionally copy `/data` |
| CoreDNS | no | recreate from zone config |
| wg-easy | no | recreate; new client configs |
| Syncthing | config/identity | copy `syncthing-config`; data is a replica |
| OpenCode | workspace optional | recreate; copy workspace only if wanted |
| Forgejo runner | no | recreate with sops runner credentials |
| Cloudflare DDNS | no | recreate with token |
| Renovate | no | recreate with Forgejo token |
| Website | no | rebuild/recreate |
| Dockge | no | new |
| ttyd | no | drop |
| Incus UI | no | drop |

### Forgejo

- Image: `codeberg.org/forgejo/forgejo:16.0.5`
- Database: `postgres:18-alpine`
- Data:
  - `/data` ← `/var/lib/forgejo/data`
  - `/data/ssh` ← existing SSH host keys
  - `/data/git/.gnupg` ← existing GPG keyring
  - `/data/git/gitea-repositories` ← existing repository root
  - `custom/conf` copied separately; regenerate `app.ini` from environment
- Preserve `SECRET_KEY`, `INTERNAL_TOKEN`, `JWT_SECRET`, `LFS_JWT_SECRET`,
  SMTP password.
- Publish host port `22` for Forgejo SSH; host SSH stays on `2222`.
- Caddy: `forgejo.sakul-flee.de` → `forgejo:3000`.
- Verify the SSH host-key fingerprint before cutover.
- Test: login, 2FA, clone/push over SSH and HTTPS, LFS, packages, mail,
  webhooks.

### Fluxer

- Keep the upstream Compose stack and proxy overlay.
- Critical data: `postgres-data`, `seaweedfs-data`.
- Also copy: `meilisearch-data`, `nats-data`, `valkey-data`, `edge-data`,
  `edge-config`.
- Convert volumes to bind mounts under `/srv/docker/fluxer/`.
- `.env` generated from existing Fluxer sops secrets.
- Postgres 16.
- Host Caddy: `fluxer.sakul-flee.de` → `fluxer-edge:8080`.
- Publish LiveKit `7881/tcp` and `7882/udp`.
- Test: login, channels/messages, media upload, voice/video.

### Minecraft

- Keep the existing Paper 26.3 `server.jar` and plugins.
- Run with `eclipse-temurin:25-jre`.
- JVM: `-Xms1G -Xmx2G -XX:+UseG1GC -XX:MaxGCPauseMillis=200
  -XX:+ParallelRefProcEnabled -XX:+DisableExplicitGC`.
- Memory limit 3 GiB.
- Data: `/srv/docker/minecraft` → `/data`.
- Publish `25565/tcp`.
- Backup: stop container, archive, start. `stop_grace_period: 5m`.
- Do not let a generic image auto-update/downgrade the world.

### Hytale

- Keep the existing payload, universe, mods, `Assets.zip`,
  `Server/HytaleServer.jar`.
- Base image: Temurin 25 + `tmux`; create user UID 989 with a real shell.
- Data: `/srv/docker/hytale/data` → `/data`.
- Secrets: `/srv/docker/hytale/secrets` → `/secrets`.
- Machine ID: bind-mount `/srv/docker/hytale/machine-id` →
  `/etc/machine-id:ro`.
- Preserve `.machine-id`, `Server/auth.enc` and downloader credentials
  together. Expect one `/auth login device` if they do not match.
- Console: `docker exec -it hytale tmux attach -t hytale`.
- Memory limit 8 GiB; JVM `-Xmx4G`.
- Publish `5520/udp`.
- Backup: `tmux send-keys -t hytale '/backup' Enter`, wait for the zip, prune by
  age, restic.

### Other services

- **Syncthing:** copy config/identity; keep for personal files and game archive
  replication. Not authoritative for backups.
- **OpenCode:** recreate; copy workspace only if wanted.
- **Forgejo runner:** container with Docker socket; CI only. Works once Forgejo
  and runner credentials are restored.
- **Cloudflare DDNS:** token from sops.
- **Renovate:** Forgejo token from sops; opens image-tag PRs.
- **Website:** rebuild/recreate; public.

## 6. Network and domains

Host IP: `192.168.178.200/24`, gateway `192.168.178.1`.

Host SSH: `2222`, key-only. Forgejo SSH: `22`.

### Public ports

| Port | Service |
| --- | --- |
| `80/tcp`, `443/tcp` | Caddy |
| `22/tcp` | Forgejo SSH |
| `25565/tcp` | Minecraft |
| `5520/udp` | Hytale |
| `7881/tcp`, `7882/udp` | Fluxer LiveKit |
| `51820/udp` | WireGuard |

### Admin/LAN/VPN only

| Port | Service |
| --- | --- |
| `2222/tcp` | Host SSH |
| `53/tcp`, `53/udp` | CoreDNS |
| `5001/tcp` | Dockge |
| `51821/tcp` | wg-easy UI |
| `4096/tcp` | OpenCode |
| `8384/tcp` | Syncthing |

Docker publishes ports past UFW. Use `DOCKER-USER`/`ufw-docker` or bind admin
ports explicitly to the LAN address.

### Domains

Public:

- `forgejo.sakul-flee.de` and aliases
- `fluxer.sakul-flee.de`
- `sakul-flee.de`, `www.sakul-flee.de`

Admin/VPN:

- `opencode.sakul-flee.de`
- `syncthing.sakul-flee.de`
- `vpn.sakul-flee.de`
- `dockge.sakul-flee.de`

Caddy:

- Public vhosts: no IP gate.
- Admin vhosts: allow `100.64.0.0/10` and `192.168.178.0/24`; respond 403
  otherwise.
- Cloudflare DNS-01 via `CF_API_TOKEN`.
- Admin names should be DNS-only in Cloudflare so Caddy sees the real client
  source.
- CoreDNS answers admin names with `192.168.178.200` for LAN/VPN clients and
  forwards everything else upstream.
- WireGuard clients use `192.168.178.200` as DNS.

### WireGuard / wg-easy

- `WG_HOST=vpn.sakul-flee.de`
- `WG_PORT=51820`
- `WG_DEFAULT_ADDRESS=100.64.0.x`
- `WG_DEFAULT_DNS=192.168.178.200`
- Full tunnel: `AllowedIPs=0.0.0.0/0, ::/0`
- Enable host `ip_forward` and NAT for the tunnel.
- Split-tunnel profile optional.
- UI on LAN/VPN only.

### CoreDNS

- Container with the existing split-horizon zone.
- Admin names → `192.168.178.200`.
- Forward everything else upstream.
- Bind to `192.168.178.200:53` to avoid conflicting with Debian
  `systemd-resolved`.
- Router DNS for LAN clients can point at `192.168.178.200`.

## 7. Secrets

- Keep sops + age.
- Current age key is derived from `/etc/ssh/ssh_host_ed25519_key`; copy that key
  before wiping.
- Either reuse the host SSH key on Debian (preserves decryption and host
  identity), or create a new age key, add it to `.sops.yaml`, and re-encrypt
  using the old key.
- Store a dedicated age key offline eventually.
- Render secrets to `/run/homelab/secrets` at deploy time.
- Use file-based secrets where supported:
  - Forgejo `*_URI`
  - Postgres `POSTGRES_PASSWORD_FILE`
  - Caddy token via an entrypoint wrapper
  - Fluxer `.env` generated from sops
  - wg-easy password hash
  - restic source/destination passwords
- No plaintext secrets in Git or Compose.

## 8. Repository layout

```text
/opt/homelab/
├── stacks/
│   ├── caddy/
│   ├── coredns/
│   ├── dockge/
│   ├── fluxer/
│   ├── forgejo/
│   ├── hytale/
│   ├── minecraft/
│   ├── opencode/
│   ├── renovate/
│   ├── syncthing/
│   ├── website/
│   └── wg-easy/
├── scripts/
│   ├── bootstrap.sh
│   ├── deploy.sh
│   ├── backup.sh
│   ├── restic-copy.sh
│   ├── restore.sh
│   ├── healthcheck.sh
│   └── render-secrets.sh
├── secrets/
│   └── secrets.yaml
├── docs/
└── README.md
```

- `main` stays NixOS until cutover.
- `v2` is a clean Docker tree.
- Build/test on the laptop.
- On the new host: clone, checkout `v2`, bootstrap, restore data, deploy.
- After stable: merge `v2` into `main` or make `v2` the new main and tag `main`
  as `nixos-final`.

### Deploy script

`deploy.sh`:

1. Acquire a lock.
2. `git fetch`; `git merge --ff-only origin/v2`.
3. Render secrets.
4. Validate every `docker compose config -q`.
5. Take a btrfs snapshot of `/srv/docker` or the affected service.
6. `docker compose pull`.
7. `docker compose up -d --wait --remove-orphans`.
8. Run health checks.
9. Notify on success/failure.
10. On failure, alert; do not automatically roll back database migrations.

Run via a systemd timer every 15–60 minutes. The Forgejo Actions runner is
CI-only: compose validation, shellcheck, YAML lint. It is not the deploy
mechanism, because it cannot recover Forgejo when Forgejo is down.

### Bootstrap script

`bootstrap.sh` on a fresh Debian host:

- Install Docker CE, Compose plugin, sops, age, restic, btrfs-progs, snapper,
  wireguard-tools, nftables/ufw, git, jq, curl, tmux.
- Create `/srv/docker` and `/srv/backup`.
- Install systemd units/timers.
- Configure Docker (`live-restore`, log limits, `data-root`).
- Configure firewall.
- Check the `/srv` mount dependency.
- Place the sops age key.
- Prepare the CoreDNS port binding.
- Enable timers only after verification.

## 9. Backup design

### Local copies

- Live data: `/srv/docker` on NVMe.
- Restic repo: `/srv/backup/restic` on SATA.
- Dumps: `/srv/backup/dumps`.
- Repo snapshots: `/srv/backup/repo-snapshots`.

This protects against a single disk failure. It does not protect against host
loss.

### Backup jobs

| Time | Job |
| --- | --- |
| 02:00 | Forgejo: stop briefly, `pg_dump -Fc`, restic backup `/srv/docker/forgejo` + dump |
| 02:30 | Fluxer: `pg_dump -Fc`, restic backup `/srv/docker/fluxer` + dump |
| 03:00 | Minecraft: stop, archive/tar, restic, start |
| 03:30 | Hytale: `/backup` via tmux, restic backup data/secrets/backups |
| 04:00 | `restic check --read-data-subset=10%`; btrfs snapshot of repo |
| Every 15–30 min | If Dendra reachable: `restic copy` |
| Weekly | `restic check --read-data-subset=5%` on Dendra |
| Monthly | Full `restic check --read-data` if size allows |

### Restic repo snapshots

After a successful backup and check:

```bash
btrfs subvolume snapshot -r /srv/backup/restic \
  /srv/backup/repo-snapshots/restic-$(date +%F-%H%M)
```

Also snapshot immediately before `restic forget --prune`.

Retain e.g. 14 daily and 8 weekly repo snapshots. If restic corrupts its repo,
restore the btrfs snapshot of the repo, not the live data. Do not run
`restic repair` on the only copy.

### `restic copy` to Dendra

Dendra is the off-box target, online roughly 12h/day.

Recommended direction: push from the homelab.

- Dendra runs SSH/SFTP.
- Homelab initializes a restic repo on Dendra:

```bash
restic -r sftp:dendra:/srv/restic/homelab init
```

- Regular copy:

```bash
restic -r /srv/backup/restic \
  copy --repo2 sftp:dendra:/srv/restic/homelab
```

- Use a read-only btrfs snapshot of the local repo as the copy source so
  concurrent prune/backup cannot disturb it.
- Timer every 15–30 minutes:
  - `ssh -o BatchMode=yes -o ConnectTimeout=5 dendra true`
  - If reachable, `flock` + `restic copy`.
  - Update `/var/lib/homelab/restic-copy.last`.
- Alert if the last successful copy is older than 72 hours.
- Dendra does not need the source repo password in push mode.
- Install restic on Dendra for `restic check` and restores.
- Dendra runs its own `restic forget --prune` with its own retention.

`restic copy` writes a normal restic repository. It is incremental,
deduplicated, and can be interrupted/resumed. It can later target a NAS via
SFTP/S3/REST, but not SMB/NFS for reliability.

### Syncthing

- Keep for personal files and existing game archive replication.
- Send-only is fine for immutable archives.
- Do not point Syncthing at the live restic repo.
- If Syncthing must carry a restic repo, point it at a read-only btrfs snapshot
  and keep separate point-in-time copies on the target.
- Syncthing is not the restic replication mechanism; `restic copy` is.

### Restore drill

- Restore Forgejo DB and data to a staging stack; verify login/repos.
- Restore Fluxer Postgres/SeaweedFS; verify login/media.
- Restore Minecraft/Hytale; start and connect.
- Restore from the Dendra copy once, to prove the off-box copy works.

## 10. Migration runbook

### Phase 0 — Prepare the safe copies

1. On the homelab, stop Forgejo, Fluxer, Minecraft, Hytale.
2. Forgejo:
   - `pg_dump -Fc forgejo`
   - copy `/var/lib/forgejo/data`
   - copy `/var/lib/forgejo/custom/conf`
   - copy `/data/ssh` and `/data/git/.gnupg`
3. Fluxer:
   - `docker compose down`
   - copy `postgres-data`, `seaweedfs-data`, `meilisearch-data`, `nats-data`,
     `valkey-data`, `edge-data`, `edge-config`
4. Minecraft: copy `/var/lib/minecraft`.
5. Hytale: `/backup`, then copy `/var/lib/hytale`, `hytale-secrets`,
   `.machine-id`.
6. Copy host SSH keys `/etc/ssh/ssh_host_ed25519_key*`.
7. Copy `.sops.yaml`, `secrets.yaml`, Caddyfile, DNS config, router forward
   notes.
8. Copy everything to Dendra. Verify archives open and the Forgejo dump is
   readable.
9. Optionally copy to the laptop for staging.

### Phase 1 — Stage on the laptop

1. Install Docker on the laptop.
2. Clone the repository, checkout `v2`.
3. Restore copies of Forgejo, Fluxer, Minecraft, Hytale.
4. Run the full stack; verify the four data services and the support services.
5. Test backup and restore.
6. If the homelab reinstall will take more than a day, promote the laptop to
   temporary production:
   - Stop homelab services.
   - Copy real data to the laptop.
   - Give the laptop `192.168.178.200` or update DNS/router forwards.
   - Start stacks; keep services running.
7. Otherwise the laptop remains a tested fallback.

### Phase 2 — Reinstall the homelab

1. Install Debian 13 on the NVMe.
2. Configure static `192.168.178.200`, gateway `.1`, host SSH `2222`.
3. Create btrfs subvolumes; mount `/srv`.
4. Run `bootstrap.sh`; install Docker and packages.
5. Restore the sops key and repo.
6. Mount the old SATA disk and copy data to `/srv/docker` on NVMe. If mounting
   is awkward, restore from Dendra.
7. Restore Forgejo DB and data; restore Fluxer DB/volumes; restore game data.
8. Start Postgres → Forgejo/Fluxer → game servers → Caddy/DNS/WireGuard/Dockge.
9. Verify everything.
10. Only after verification, format the SATA disk as btrfs and mount at
    `/srv/backup`.
11. Run the first restic backup and repo snapshot.
12. Configure `restic copy` to Dendra.

### Phase 3 — Cutover

- If the laptop is temporary production, stop it and move the bind mounts back
  to the homelab.
- Assign `192.168.178.200` to the homelab.
- Keep router forwards unchanged:
  - `80/443`, `22`, `25565/tcp`, `5520/udp`, `7881/tcp`, `7882/udp`,
    `51820/udp`.
- Verify from outside:
  - Forgejo HTTPS and SSH push.
  - Fluxer web and media/voice.
  - Minecraft connection.
  - Hytale connection/auth.
  - Caddy certificates.
  - WireGuard handshake and DNS.
  - Dockge/OpenCode/Syncthing over VPN/LAN.
- Keep Dendra's copy and the old SATA data until satisfied.

### Phase 4 — Stabilize

- Enable deploy/backup timers.
- Run a restore drill from Dendra.
- Add Renovate and notifications.
- After 2–4 clean weeks:
  - Merge `v2` into `main` or make `v2` the new main.
  - Tag old main as `nixos-final`.
  - Archive the NixOS tree.
  - Delete old Incus images/volumes after final verification.

## 11. Verification checklist

- `systemctl is-system-running` on Debian.
- `docker compose ps` all healthy.
- Forgejo login, 2FA, SSH push, LFS, packages, mail.
- Fluxer login, messages, media, voice/video.
- Minecraft world loads, plugins, whitelist, backup/restore.
- Hytale auth, tmux console, `/backup`, restore.
- Caddy certificates for all names.
- CoreDNS admin/public resolution.
- WireGuard handshake, split DNS, full-tunnel internet.
- Dockge/OpenCode/Syncthing reachable only via LAN/VPN.
- Restore from local restic repo.
- Restore from Dendra `restic copy`.
- Last-copy alert works.
- Docker firewall: admin ports not publicly reachable.

## 12. Known risks / gotchas

- Forgejo `custom/conf` lives on the container root, not the data volume.
- Forgejo `SECRET_KEY` loss breaks 2FA.
- Forgejo SSH host keys must be preserved.
- Hytale `.machine-id` + `auth.enc` must travel together.
- Minecraft world is version-forward-only; pin Paper 26.3.
- Docker publishes ports past UFW; configure `DOCKER-USER`/`ufw-docker`.
- `systemd-resolved` may occupy port 53; bind CoreDNS to
  `192.168.178.200:53`.
- Cloudflare-proxied admin names would break `remote_ip` gates; keep admin
  names DNS-only.
- Dockge and the runner mount the Docker socket; root-equivalent, keep them off
  the public internet.
- Do not sync the live restic repo with Syncthing; use `restic copy`.
- Do not run `restic repair` on the only repo.
- Dendra is offline sometimes; stale-copy alert is required.
- The laptop as temporary production must use the same IP/ports or DNS/router
  changes are needed.
- Snapshots on the same disk are not backups; the Dendra copy is the off-box
  tier.
- dropbear-initramfs and host sshd share port 2222; the pre-boot host key
  differs. Use a separate SSH config alias or move dropbear to 2223.

## 13. Implementation order

1. Create this `v2` branch and `PLAN.md`.
2. Add repository skeleton: `stacks/`, `scripts/`, `secrets/`, `docs/`.
3. Write `bootstrap.sh` and the systemd units/timers.
4. Write `render-secrets.sh`, `deploy.sh`, `backup.sh`, `restic-copy.sh`,
   `healthcheck.sh`.
5. Add the Compose stacks, starting with Forgejo, Minecraft, Hytale, Fluxer.
6. Add Caddy, CoreDNS, wg-easy, Dockge and the remaining services.
7. Test on the laptop with copies of the data.
8. Reinstall the homelab and perform the cutover.
