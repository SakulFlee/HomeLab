# Operations

How the host is put together, how changes reach it, and what to check when
something breaks.

## Architecture

```text
Debian 13
├── NVMe, LUKS2 + btrfs (@rootfs)      /            OS
│   ├── /srv/docker                     bind mounts for every stack
│   └── /var/lib/docker                 Docker data root
└── SATA, LUKS2 + btrfs, keyfile        /srv/backup   restic repository
```

- `/opt/homelab` is the git checkout; `deploy.sh` runs as root.
- `/etc/homelab/host.env` holds non-secret host settings (ports, bind IPs,
  optional `DEPLOY_STACKS`/`SKIP_HEALTHCHECK`). `scripts/lib.sh` sources it.
- `/etc/homelab/notify.env` holds the optional notification endpoints. It is
  rendered from sops by `render-secrets.sh`.
- The backup disk unlocks at boot through `/etc/luks/backup.key` on the root
  filesystem, so one passphrase (dropbear or console) brings up everything.

## Deploy

```bash
git push origin main
```

`homelab-deploy.timer` runs `deploy.sh` every 30 minutes. It fetches `main`,
renders secrets, then works out which stacks actually changed since the
previous commit (`git diff --name-only`) and applies only those. A change to
`secrets/secrets.yaml` or `render-secrets.sh` recreates every stack, because the
rendered environment changes. Before applying it takes a btrfs snapshot of
`/srv/docker` under `/srv/snapshots`, pulls images, applies each selected stack
with `--build --wait`, then runs `healthcheck.sh`. A failure sends a
notification and stops before the next stack. `--force` applies everything.

Do not rsync the repository onto the host. If the checkout is ahead of
`origin/main`, every timer run re-applies all stacks.

Rollback of a bad deploy:

```bash
sudo btrfs subvolume list /srv/snapshots
# stop the affected stack, swap the subvolume back, start it again
```

## Backups

```text
homelab  02:01   backup.sh     dumps + restic backup + repo snapshot + prune
homelab  Sun     restic-check  restic check --read-data-subset=10%
Dendra   30 min  pull          restic copy from the homelab (read-only sftp)
Dendra   03:30   prune         forget --keep-daily 14 --keep-weekly 8 --keep-monthly 12
Dendra   Sun     check         restic check --read-data-subset=10%
```

- `backup.sh` stops Forgejo and Minecraft while it runs, dumps both PostgreSQL
  databases, asks Hytale for its own archive, then backs up `/srv/docker` and
  the dumps.
- Excluded: Forgejo's generated archive cache and PGDATA, Fluxer's Postgres and
  search/NATS/Valkey data, Minecraft's own backups, Hytale logs, the runner,
  Renovate, and the whole Syncthing tree.
- Retention: `--keep-daily 14 --keep-weekly 8 --keep-monthly 12` on both
  repositories.
- Dendra's copy sits on the btrfs RAID1 array:
  `/mnt/btrfs-raid1/backups/homelab/restic`. The pull, prune and check scripts
  are versioned in `scripts/dendra/` and installed to `~/.local/bin` on Dendra
  with `scripts/dendra/install.sh`. They take the path from
  `homelab-restic-common.sh`, which all three source — the earlier layout
  hardcoded it in each script and they drifted apart.
- `/mnt/btrfs-raid1` is an `x-systemd.automount` (5 minute idle timeout).
  `require_repo` in `common.sh` triggers the mount and then checks that the
  path resolves to that mountpoint, so a mount failure aborts the pull instead
  of letting restic create a mirror on Dendra's root filesystem. Because keep-daily keeps one snapshot per day, a same-day
  manual backup supersedes the nightly one.
- The Dendra copy is pulled by Dendra, using a dedicated key restricted to
  read-only sftp (`command="internal-sftp -R",restrict`). The homelab has no
  credential that can reach Dendra.
- `restic copy` does not propagate deletions; Dendra prunes its own repository.

Restore drill (safe, read-only):

```bash
sudo restic -r /srv/backup/restic \
  --password-file /run/homelab/secrets/restic-password \
  restore latest --target /tmp/restore-test --include "<some path>"
```

See [restore.md](restore.md) for the full procedure.

## Alerting

| channel | what | configured in |
| --- | --- | --- |
| ntfy (self-hosted) | any failed unit on either machine | sops `ntfy_url`, `ntfy_user`, `ntfy_password` |
| ntfy.sh (hosted) | same message, always sent as well | sops `ntfy_fallback_url` |
| Fluxer webhook | same events, posted to a channel | sops `fluxer_webhook_url` |
| Healthchecks.io | dead-man's switch: pings stop when the chain stops | sops `healthchecks_pull_url`, `healthchecks_check_url` |

`notify()` posts to both ntfy endpoints unconditionally: the self-hosted one
carries credentials and the hosted topic is anonymous. Both are sent because a
relay running on the homelab cannot report the homelab itself being down. The
self-hosted instance lives in `stacks/ntfy` with `NTFY_AUTH_DEFAULT_ACCESS=deny-all`
and one user with read-write access to the `homelab` topic; subscribe to it with
that user in the ntfy app (`https://ntfy.sakul-flee.de`).

- The pull pings Healthchecks only when a **new snapshot** arrives, so a failing
  homelab backup or a broken connection shows up as a missing ping rather than
  silence.
- The weekly check pings only on success.
- Test manually: `sudo /opt/homelab/scripts/notify-failure.sh test` on the
  homelab, or `~/.local/bin/homelab-alert.sh test` on Dendra.

## Network

- Caddy terminates TLS for every public name, using Let's Encrypt via the
  Cloudflare DNS-01 challenge. `ACME_CA` in `host.env` switches to staging.
- Public names are Cloudflare-proxied; admin names are DNS-only plus a Caddy
  `remote_ip` gate for the LAN and the WireGuard range.
- The router has no hairpin NAT, so the host maps the public names to
  `127.0.0.1` in `/etc/hosts` for its own `git fetch` and registry pulls.
- `*.sakul-flee.de` is a proxied wildcard, so every subdomain reaches Caddy.
  A wildcard certificate plus a `respond 404` site makes a typo obvious;
  without it Caddy aborts the TLS handshake and Cloudflare reports 525.
  `nfty.sakul-flee.de` redirects to the correctly spelled ntfy name.
- LAN clients need CoreDNS (`192.168.178.200`) to get the split-horizon answers;
  with the router's DNS the admin names resolve to Cloudflare and return 403.
- IPv6: the apex has an AAAA (DDNS), the game names are CNAMEs to it and
  inherit it. WireGuard stays IPv4 on the endpoint; the tunnel carries both
  families (`100.64.0.0/24`, `fd42:1::/64`) with NAT66.
- **IoT Wi-Fi**: `wlp2s0` (MT7921) serves a 2.4 GHz-only SSID on
  `192.168.179.1/24`, DHCP/DNS from a dedicated dnsmasq and NAT out `eno1`.
  ufw denies the LAN, WireGuard, Docker subnets and client-to-client, and a
  `DOCKER-USER` rule keeps the segment out of Docker-published ports. IPv6 is
  disabled on the interface. See [iot-wifi.md](iot-wifi.md).

## Home Assistant

`stacks/homeassistant` is Home Assistant Container, not HAOS. There is no
Supervisor, so there are no add-ons: anything that would be one is a separate
stack (ntfy already is), and custom integrations are installed through HACS.
Reach it at `https://home.sakul-flee.de` from the LAN or the WireGuard tunnel;
the Caddy site imports `vpn_only`.

- It uses **host networking**, which is required for mDNS/SSDP discovery and
  for a Thread/Matter border router later. Port 8123 therefore belongs to the
  host. ufw's default deny keeps it off the LAN, and `bootstrap.sh` allows it
  from `172.16.0.0/12` so Caddy (bridge network) can proxy it. Changing that
  rule is a host change: run `sudo /opt/homelab/scripts/bootstrap.sh` once.
- `home.sakul-flee.de` is in `cloudflare-ddns`'s `IP4_DOMAINS` and in the
  CoreDNS split-horizon pattern. Both are needed: the A record must be
  DNS-only so the `vpn_only` gate sees the client, and LAN clients using
  CoreDNS must not resolve it through Cloudflare.
- Configuration, integration credentials (`.storage`), the recorder database
  and logs all live in `/srv/docker/homeassistant`. There is no secret to
  render: the first start serves the onboarding page, where the owner account
  and integrations are created in the browser.
- `stacks/homeassistant/configuration.yaml` is the source of truth.
  `deploy.sh` installs it over
  `/srv/docker/homeassistant/configuration.yaml` and restarts the container
  when the content differs, so edits made on the host are overwritten.
  Integrations added through the UI live in `.storage` and are untouched;
  automations, scripts and scenes created in the UI are written to their own
  `!include`d files in the volume, not to the managed file.
- **There is no `http:` block in the managed file.** Home Assistant 2026.x
  migrates it into `.storage/http` on first boot and then ignores YAML for it
  (`components/http/config.py`, `yaml_migration_done`), leaving a repair
  warning behind. A YAML edit after that changes nothing. `deploy.sh`
  reconciles `use_x_forwarded_for` and `trusted_proxies` in that store and
  restarts, because without them every proxied request gets **400: Bad
  Request** from aiohttp — which looks like Caddy or DNS being broken. The log
  line tells the two failure modes apart: `not set-up for reverse proxies`
  means the store lost the keys, `untrusted proxy <ip>` means the range is
  wrong (`sudo docker exec homeassistant grep -i forwarded
  /config/home-assistant.log`).
- `default_config` is expanded by hand, leaving out `bluetooth` (host
  networking exposes the host's adapter over USB, so HA would ask for
  `NET_ADMIN`/`NET_RAW`, which in the host netns also allow rewriting the
  firewall; unloading the driver does not help, the USB device stays visible)
  and `cloud` (Nabu Casa is unused). Adding a future default integration means
  adding its key to the managed file.

- The image is pinned to a release tag; Renovate bumps it. `deploy.sh` only
  pulls a stack whose directory changed, so upgrades land with that PR.
- `backup.sh` includes the whole tree. The SQLite recorder is copied while
  running, so a restore is crash-consistent; `.storage` and the YAML files are
  plain files and always consistent.
- Tuya devices are reachable two ways. The official **Tuya** integration goes
  through Tuya's cloud, so it works with the IoT segment still sealed. The
  HACS **tuya-local** integration talks to the device on `tcp/6668` and needs a
  narrow hole from the host to `192.168.179.0/24`. Both may be installed at
  the same time for evaluation; see [iot-wifi.md](iot-wifi.md) before punching
  that hole.

## OpenCode and OpenChamber

`stacks/opencode` runs the OpenCode server (`serve` on 4096). It owns sessions,
providers, permissions and tool execution; every UI is a client of it.

- **Web UI**: `https://opencode.sakul-flee.de`, username `opencode`, password
  from sops (`opencode_server_password`). The server serves the UI itself.
- **Desktop app**: paste a pair link from `opencode pair --url
  https://opencode.sakul-flee.de` into its server address field, or connect a
  TUI with `opencode --server https://opencode.sakul-flee.de`. Links are
  single-use and expire after five minutes.
- **Sessions** are rows in one SQLite database:
  `/srv/docker/opencode/home/.local/share/opencode/opencode.db`. Copying
  sessions between machines means copying that file (with the service stopped,
  or via `sqlite3 .backup`) into a server running the **same or newer**
  version. A newer database opened by an older binary is not supported.
- The workspace is the bind mount `/srv/docker/opencode/workspace`; the server
  can only touch files there and in the image. A client does not extend that:
  connecting the desktop app does not give the server access to the desktop's
  filesystem.
- The image is derived in `stacks/opencode/Dockerfile` because upstream ships
  only the opencode binary: it adds git, curl, jq, tea and an SSH client. The
  git credential helper reads `FORGEJO_TOKEN` from the environment, so pushes
  work without writing the token to disk, and `tea` or the Forgejo API manage
  pull requests. The token must be a PAT with `write:repository` (and
  `read:user` for identity).

`stacks/openchamber` is a second UI on the **same** server
(`OPENCODE_HOST=http://opencode:4096`, `OPENCODE_SKIP_START=true`). Sessions
are therefore shared with the web UI, the TUI and the desktop app — there is no
second database. Reach it at `https://chamber.sakul-flee.de`; its own login is
`openchamber_ui_password` from sops. It mounts the OpenCode workspace at the
same path so its git/diff views can read the files the server reports.

OpenChamber's own agent tools are plugins injected into a server it starts. With
the shared server they are not active unless its plugin folder is registered in
the OpenCode config; the session list, chats, diffs and git stay functional
without them.

It runs as UID 990, the same user as the OpenCode server, because both write to
the shared workspace. Its project-less chats live in
`/srv/workspace/.openchamber/chats`: OpenChamber passes that path to the server
as a location, so it cannot be inside its own container (`/data/chats` fails
with `LocationNotFoundError`).

## Secrets

- `secrets/secrets.yaml` is sops/age encrypted. The host identity lives at
  `/etc/sops/age/keys.txt`; `scripts/sops.sh` is the wrapper that uses it.
- `render-secrets.sh` writes `/run/homelab/secrets/*`, per-stack `.env` files
  for Compose, and `/etc/homelab/notify.env`. Two generated files are
  exceptions and live on disk, because a reboot empties `/run` and the
  containers start before the deploy re-renders it: `/etc/hostapd/iot.conf`
  and `/srv/docker/forgejo-runner/config.yaml`. Docker replaces a missing bind
  source with a directory, which is how the runner once ended up reading
  `/config.yaml` as a directory.
- Store the age key, both restic repository passwords and the LUKS recovery
  passphrase offline.
- Never regenerate Forgejo's `SECRET_KEY` on an existing database.

## Troubleshooting

Start with the sharp-edges section in [../AGENTS.md](../AGENTS.md). The most
common symptoms:

| symptom | look at |
| --- | --- |
| VPN clients get no internet but ping works | `ufw route allow in on wg0`, wg-easy `interfaces_table.device` |
| CI jobs fail instantly with `Cannot connect to the Docker daemon` | runner socket inode is stale; run `scripts/docker-socket-refresh.sh` or `docker restart forgejo-runner` |
| Admin UIs return 403 | split-horizon DNS / `/etc/hosts`, Cloudflare proxy |
| `home.sakul-flee.de` returns 400 | HA rejects Caddy's `X-Forwarded-For`; set `http.trusted_proxies` |
| `home.sakul-flee.de` returns 502 | the 8123 ufw rule is missing; re-run `bootstrap.sh` |
| `home.sakul-flee.de` returns 403 while on VPN | the name resolved to the WAN IP and WireGuard sent it outside the tunnel |
| Broken avatars or attachments in Forgejo | `FORGEJO__picture__*`, `FORGEJO__attachment__PATH` |
| Deploy timer restarts everything every 30 min | checkout ahead of `origin/main` |
| Backups suddenly much larger | new path under `/srv/docker` that is not excluded |

## Legacy

The NixOS + Incus trees (`nixos/`, `incus/`, `PLAN.md` and the migration docs)
were removed in November 2026. Earlier commits still contain them; nothing from
them runs on the host.

## Forgejo runner

`stacks/forgejo-runner` runs the Forgejo runner with the host's Docker socket
mounted, and `docker_host: "automount"` in the rendered config passes that
socket into job containers. Workflows can therefore build images with the
Docker CLI without a separate DinD setup.

The security consequence is the important half: **any workflow in any
repository the runner serves can run containers as root on the host** (mount
`/`, publish ports, read every secret the host can read). Actions must only be
enabled on repositories whose workflows are trusted — a single-user instance is
fine, an instance with external contributors is not. If that ever changes, the
alternatives are a dedicated runner for untrusted repositories, a rootless
runner, or a build service outside the host.

Labels are declared at registration and refreshed when the runner restarts:
`default`, `ubuntu-latest`, `ubuntu-24.04` and `docker`, all backed by
`ghcr.io/catthehacker/ubuntu:act-24.04`.

How many jobs run in parallel is `FORGEJO_RUNNER_CAPACITY` from
`/etc/homelab/host.env` (default 2), rendered into the config's `capacity`. It
is a sizing decision, not a secret, so it is not in sops. To change it:

```bash
sudo sed -i 's/^FORGEJO_RUNNER_CAPACITY=.*/FORGEJO_RUNNER_CAPACITY=4/' /etc/homelab/host.env
sudo /opt/homelab/scripts/render-secrets.sh
sudo docker restart forgejo-runner
```

The restart is required, not optional: `/run/homelab/secrets/forgejo-runner/config.yaml`
is a bind mount, so the running process keeps the copy it opened at container
start. `deploy.sh` re-renders the file on every run but a `host.env`-only change
selects no stack, so it would apply nothing. Each slot is a full job container
plus whatever `docker build` starts inside it; on 16 cores / 30 GB, 4 is
comfortable.

### After a Docker restart

`daemon.json` sets `live-restore: true`, so containers survive `systemctl
restart docker` and the package upgrades that trigger it. Their bind mount of
`/var/run/docker.sock` does not: the mount is tied to the inode that existed
when the container was created, and dockerd replaces the socket on start. The
runner then fails every job immediately with

```text
failed to query docker info: Cannot connect to the Docker daemon at unix:///var/run/docker.sock
```

while `docker ps` still shows it as `Up`, and Dockge loses its view of stacks
for the same reason. `scripts/docker-socket-refresh.sh` compares the inode
inside each socket-mounting container with the live one and restarts only the
stale ones. `deploy.sh` runs it on every timer tick, and the `docker.service`
drop-in from `bootstrap.sh` runs it right after dockerd starts. To repair it by
hand:

```bash
sudo /opt/homelab/scripts/docker-socket-refresh.sh
# or, if the script is not on the host yet:
sudo docker restart forgejo-runner dockge
```
