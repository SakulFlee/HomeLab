# Agent Notes

This repository is a Debian 13 + Docker Compose homelab. On the host it is
checked out at `/opt/homelab` and `deploy.sh` runs as root from there.

## What owns what

| layer | owner |
| --- | --- |
| host OS, packages, firewall, users | Debian on the host, provisioned by `scripts/bootstrap.sh` |
| host-specific settings (ports, bind IPs, runner capacity) | `/etc/homelab/host.env` on the host |
| services | `stacks/<name>/compose.yaml` |
| IoT Wi-Fi AP | `scripts/bootstrap.sh` and `systemd/homelab-iot-*.service` |
| deploy, backup, restore, secrets | `scripts/` |
| timers and units | `systemd/` |
| secrets at rest | `secrets/secrets.yaml` (sops/age) |
| live data | bind mounts under `/srv/docker/<service>` |
| backups | `/srv/backup` (LUKS + btrfs), pulled to Dendra |

Docker Compose is the source of truth. Use `docker`/`compose` for inspection;
do not create or reshape containers, networks or volumes by hand during normal
operation.

## Normal deploy

```bash
git push origin main        # from a workstation
```

The host's `homelab-deploy.timer` fetches `main`, runs `render-secrets.sh`,
validates every stack, checks free space, snapshots `/srv/docker` with btrfs,
then applies each stack with `compose up -d --build --wait` and runs
`healthcheck.sh`. It keeps the last `DEPLOY_SNAPSHOT_KEEP` (default 3)
snapshots and refuses to start below `DEPLOY_MIN_FREE_MB` (default 10240).

If the fetch fails, a timer run is a no-op; it does **not** reapply every stack
every 30 minutes. The recovery path is:

```bash
sudo /opt/homelab/scripts/deploy.sh --force --offline
```

`--offline`/`DEPLOY_SKIP_FETCH=1` skips `git fetch` and applies the current
HEAD, so a Forgejo outage does not block a deploy.

**Push changes; never rsync the repository onto the host.** When the checkout is
ahead of `origin/main`, `deploy.sh` sees "HEAD != origin" on every run and
re-applies the whole stack every 30 minutes, restarting Fluxer, Caddy and Hytale
each time.

Secrets must go through sops. Do not leave plaintext in the repository, and do
not commit generated `.env` files; `render-secrets.sh` writes them and
`.gitignore` covers them.

## Adding a stack

1. `stacks/<name>/compose.yaml` with `name:`, a pinned image digest or tag, and
   a `restart: unless-stopped` policy.
2. Bind mounts under `/srv/docker/<name>`; create the directories with the UID
   the image expects in `scripts/prepare-data.sh`.
3. Add secrets to `secrets/secrets.yaml` and render them in
   `scripts/render-secrets.sh`.
4. Add the stack to the ordered list in `scripts/deploy.sh` and to
   `scripts/healthcheck.sh` if it has a user-visible endpoint.
5. If it needs a host port, set it in `/etc/homelab/host.env` and add a `ufw`
   rule in `bootstrap.sh`.
6. Expose it through Caddy (`stacks/caddy/Caddyfile`), not by publishing ports.
7. Update `docs/operations.md` and this file.

## Backups

```bash
sudo /opt/homelab/scripts/backup.sh        # dumps + restic + repo snapshot
sudo /opt/homelab/scripts/restic-check.sh  # weekly verification
```

- Local repo: `/srv/backup/restic`, password in sops (`restic_password`),
  daily at 02:01 via `homelab-backup.timer`.
- Off-box copy: **Dendra pulls** it every 30 minutes
  (`sftp:homelab:/srv/backup/restic` ->
  `/mnt/btrfs-raid1/backups/homelab/restic`, password
  `restic_dendra_password`). The homelab has no credential that can reach
  Dendra. Dendra's side is versioned in `scripts/dendra/` and installed to
  `~/.local/bin` with `scripts/dendra/install.sh`; the repository path is
  defined once in `homelab-restic-common.sh`.
- `restic copy` never deletes on the destination; Dendra runs its own
  `forget --prune`.
- Retention is `--keep-daily 14 --keep-weekly 8 --keep-monthly 12` on both.
- `homelab-docker-cleanup.timer` prunes unused images older than 14 days and
  build cache older than 7 days; `homelab-runner-cleanup.timer` removes runner
  cache files older than 14 days and job workspaces older than 7 days. Neither
  touches volumes, registration/config or the running job. Both are installed
  and enabled by `bootstrap.sh`.

## Destructive actions

Do not delete, format, prune or overwrite anything unless the operator has
named the target and explicitly approved it. That includes `btrfs subvolume
delete`, `restic forget --prune`, `docker volume rm`, partitioning and `rm -rf`
of data directories. Inspecting and reversible changes are fine.

## Known sharp edges

- **Forgejo `SECRET_KEY` must never be regenerated.** It decrypts 2FA secrets
  and other encrypted rows. A new key makes every 2FA account fail with
  "enable two-factor authentication", and the error also blocks API tokens.
  The old host set `SECRET_KEY_URI=file:.../custom/conf/secret_key`, so the key
  is the **content of that file**, never the URI string. Grepping `^SECRET_KEY`
  in the old `app.ini` matches the URI and yields a 44-character value that
  looks plausible and is wrong.
- **Forgejo's built-in SSH user is `BUILTIN_SSH_SERVER_USER`, not `SSH_USER`.**
  `SSH_USER` only changes the username advertised in clone URLs; the server
  authenticates against the other setting (default `git`). Clone URLs use
  `forgejo@`.
- **Forgejo image paths default under `WORK_PATH`.** With the data volume at
  `/data` and `custom` at `/data/gitea`, avatars, attachments, LFS and the
  issue indexer silently point at `/data/gitea/...` unless set explicitly. The
  symptom is 404s and broken images.
- **A dockerd restart leaves the runner and Dockge on a dead socket.** With
  `live-restore: true` containers keep running across `systemctl restart docker`
  (including the one an upgrade triggers), but their bind mount of
  `/var/run/docker.sock` still points at the replaced inode. The runner then
  fails every job instantly with `failed to query docker info: Cannot connect
  to the Docker daemon`, and Dockge stops seeing stacks, while both containers
  still look `Up`. `scripts/docker-socket-refresh.sh` compares inodes and
  restarts only the stale consumers; `deploy.sh` calls it on every tick and the
  `docker.service` drop-in from `bootstrap.sh` calls it right after dockerd.
- **`ufw` and wg-easy use different iptables backends.** ufw and Docker write
  nftables; wg-easy writes `iptables-legacy`. Forwarded VPN traffic is dropped
  unless ufw has `ufw route allow in on wg0`. Ping still works because
  `ufw-before-forward` accepts ICMP, which makes it look like a routing fault.
- **wg-easy 15 stores its uplink interface in the database**, seeded as `eth0`.
  On this host it must be `eno1`
  (`interfaces_table.device`), otherwise the generated MASQUERADE rules never
  match and the tunnel carries no traffic. It also refuses to start if
  `PASSWORD_HASH` (a v14 variable) is present in its environment.
- **The public names do not resolve locally.** `forgejo.sakul-flee.de` and the
  admin names are Cloudflare-proxied, and the router has no hairpin NAT. The
  host needs the `/etc/hosts` entry (public names -> `127.0.0.1`) for
  `deploy.sh`'s `git fetch` and for pulling the website image from Forgejo's
  registry.
- **AAAA records are inherited through CNAMEs.** `minecraft.` and `hytale.`
  are CNAMEs to the apex, so adding an AAAA to the apex publishes IPv6 for
  them too. Only do that when the router has IPv6 pinholes for `25565/tcp` and
  `5520/udp`; otherwise game clients that prefer IPv6 hit a black hole.
- **Split-horizon DNS only works for clients using CoreDNS.** LAN clients on
  the router's DNS get Cloudflare's addresses for the admin names and hit the
  VPN-only 403 in Caddy.
- **Home Assistant uses host networking, so 8123 is a host port.** `ufw`
  denies it to the LAN and `bootstrap.sh` allows it only from
  `172.16.0.0/12` for Caddy. A host that has not re-run `bootstrap.sh` since
  that rule was added serves `home.sakul-flee.de` as a 502. The name is
  DNS-only on purpose: if the proxy wildcard catches it, Caddy's `vpn_only`
  gate sees a Cloudflare edge and returns 403 to everyone.
- **Home Assistant ignores `http:` in YAML after the first boot.** 2026.x
  migrates it into `.storage/http` once (`yaml_migration_done`) and then uses
  the store, so a later YAML edit does nothing but raise a repair issue.
  Without `use_x_forwarded_for`/`trusted_proxies` in that store every proxied
  request is a 400 from aiohttp, which looks like Caddy or DNS breaking.
  `deploy.sh` reconciles the store. `configuration.yaml` itself is installed
  from the repo on every deploy, so YAML edits on the host do not survive.
- **Home Assistant must not load the Bluetooth integration.** Host networking
  exposes the host's adapter through `/sys/bus/usb`, so HA asks for
  `NET_ADMIN`/`NET_RAW` and logs an error every few seconds; those caps in the
  host netns would allow rewriting the firewall. `configuration.yaml`
  therefore expands `default_config` without `bluetooth` (and without
  `cloud`). Unloading `btusb` is not enough: the USB device stays enumerated.
- **The Forgejo runner config must not live under `/run`.** A bind-mounted
  file there is gone after a reboot, and the container (restart policy) starts
  before `render-secrets.sh` re-creates it, so Docker creates a directory in
  its place. The runner then loops on `read /config.yaml: is a directory`, and
  `docker-socket-refresh.sh` cannot repair it because the container is not
  running. The rendered config lives at `/srv/docker/forgejo-runner/config.yaml`
  (excluded from backups, on the LUKS root).
- **Paperless refuses to start without `PAPERLESS_SECRET_KEY`.** It is rendered
  from sops to `/run/homelab/secrets/paperless/paperless_secret_key` and read
  through `PAPERLESS_SECRET_KEY_FILE`. The file must not end in a newline
  (`render-secrets.sh` uses `jq -j`); a hand-edited copy with one produces a
  key containing a newline and a confusing session/auth failure. Do not rotate
  the key on an existing install: every session and token is invalidated,
  though the documents are unaffected.
- **Paperless' PostgreSQL 18 mounts `/var/lib/postgresql`, not
  `/var/lib/postgresql/data`.** The image creates the major-version
  subdirectory itself, exactly like Forgejo's database.
- **Paperless is DNS-only.** `paperless.sakul-flee.de` is in
  `cloudflare-ddns`'s `IP4_DOMAINS` and the CoreDNS split-horizon pattern. If
  it resolves through Cloudflare, the `vpn_only` gate sees an edge and returns
  403. `PAPERLESS_URL` and Caddy's `header_up Host` are the matching pair for
  the reverse proxy; without them Django returns 400.
- **Tika's JVM defaults to 25% of host RAM.** The stack sets
  `JAVA_TOOL_OPTIONS=-Xmx2g` (the image does not read `JAVA_OPTS`); keep it, or
  Tika can crowd out the other stacks.
- **Ollama's iGPU support is best-effort.** `stacks/ollama` is a derived image
  with Mesa's RADV ICD, the host's `/dev/dri` is passed through, and
  `OLLAMA_VULKAN`/`OLLAMA_IGPU_ENABLE` are set. If `vulkaninfo` only reports
  `llvmpipe`, Ollama falls back to CPU; to make that explicit, remove the
  `devices:` block and both variables. AI configuration does not change.
- **Ollama's model store is excluded from restic.** `/srv/docker/ollama` holds
  several GB of re-downloadable weights; there is no backup of it. Paperless'
  `data/llm_index` is backed up and can also be rebuilt with
  `document_llmindex rebuild`.
- **Ollama has no authentication and is reachable only on the `homelab-ai`
  network.** There is no published port; only Paperless, OpenCode and Hermes are
  attached. Do not put Caddy, Forgejo or another public-facing stack on it, and
  use `docker exec` for host-side checks. OpenCode's and Hermes' Ollama
  providers are optional, never the default. All consumers use the 65536-token
  window; Paperless still only sends 4,000 characters for suggestions.
- **The AI network is called `homelab-ai`, not `ai`.** Docker's embedded DNS
  resolves `<container>.<network>` as well as plain container names, so
  container `opencode` on a network named `ai` answered for `opencode.ai` and
  every request to the OpenCode Go API went to the container itself
  (`ECONNREFUSED` on 443). The same applies to any network whose name is a
  public TLD (`net`, `dev`, `cloud`, …). Keep network names out of the DNS
  namespace of real domains.
- **Paperless AI is request/response, not an offline queue.** Suggestions are
  synchronous: a timeout returns 503, a provider error 502, and nothing is
  retried. Chat streams and shows a generic error when the model is
  unreachable. The daily LLM index update does not retry. Core Paperless is
  unaffected. Suggestions only send the first 4,000 characters of a document;
  the 65,536-token window is shared with the agents and chat's five
  ~1,024-token chunks.
- **OpenCode sessions live in one SQLite database.** It is
  `/srv/docker/opencode/home/.local/share/opencode/opencode.db`. Never copy a
  database from a newer OpenCode into an older image, and stop the service (or
  use `sqlite3 .backup`) before copying it. `stacks/openchamber` is only a UI
  on the same server, not a second store.
- **Hermes' `state.db` is a single-writer SQLite database.** It lives at
  `/srv/docker/hermes/state.db`, and the gateway, cron and webapp all open it.
  Never point a second Hermes container (including a dashboard or a CLI
  gateway) at `/srv/docker/hermes`; `backup.sh` stops the container for a
  consistent copy.
- **Hermes' `config.yaml` is seeded once, not repo-managed.**
  `prepare-data.sh` installs `stacks/hermes/config.yaml` only when
  `/srv/docker/hermes/config.yaml` is absent. After that Hermes owns it; use
  the webapp or `docker exec hermes hermes config set ...` and restart the
  container. Editing the repo copy does not re-apply it.
- **Hermes may write only `/opt/data` and `/workspace`.**
  `HERMES_WRITE_SAFE_ROOT` has to keep both, and the stack deliberately has no
  Docker socket and no host network. The terminal backend is the container's
  own shell, not the host.
- **Hermes' webapp needs its public URL and trusted proxy.** The seed sets
  `webapp.public_url` and `dashboard.trusted_proxies=172.16.0.0/12`; a
  non-loopback webapp refuses to start without the basic-auth provider.
  Sign-in loops or a 502 behind Caddy usually mean one of those keys moved.
- **`forgejo_pat` is shared by OpenCode and Hermes and is an admin PAT.**
  Rotating it affects both agents. It can push to any repo the account can
  write, and the Forgejo runner mounts the Docker socket, so use a dedicated
  non-admin user or disable Actions on repos the agents can write.
- **Deploy snapshots are local rollback points, not backups.** `deploy.sh`
  snapshots all of `/srv/docker`, which includes Syncthing, the Forgejo runner
  cache/workspaces, OpenCode and the Ollama model store. Changes in those large
  trees create exclusive extents in older snapshots. Keep the retention short
  (`DEPLOY_SNAPSHOT_KEEP`, default 3), keep `DEPLOY_MIN_FREE_MB` (default
  10240) meaningful, and move bulk data outside `/srv/docker` if it grows
  again. `du -sh /srv/snapshots/*` counts shared extents; use
  `btrfs filesystem usage /`. `scripts/promote-subvolume.sh` prepares a bulk
  directory as a nested subvolume; nested data is excluded from the deploy
  snapshot and is not part of a parent-subvolume rollback.
- **A full root can leave Docker network endpoints orphaned.** A stopped/crashed
  container can leave an endpoint named like the container in its project
  network, so `compose up` fails with "endpoint with name … already exists"
  and `compose down` cannot remove the network. Restart dockerd (live restore
  keeps containers up) or give the stack a fresh network name; do not remove
  `/var/lib/docker/network/files/local-kv.db`.
- **Syncthing folders live on the config volume.** `HOME=/var/syncthing`, so
  `~/…` paths resolve under `/srv/docker/syncthing/config`. `backup.sh`
  therefore excludes the whole `syncthing` tree, not just `syncthing/data`.
- **The IoT AP is a host unit, not a stack.** `wlp2s0` (MT7921) is a 2.4 GHz-only
  routed network: `hostapd`, a dedicated dnsmasq and a `DOCKER-USER` rule.
  `bootstrap.sh` installs it; `deploy.sh` does not. After changing
  `bootstrap.sh`, run bootstrap once by hand or the AP changes never land.
  Docker DNATs published ports before ufw's filter, which is why the segment is
  blocked in `DOCKER-USER` (`scripts/iot-firewall.sh`) instead of with a plain
  ufw route rule. See `docs/iot-wifi.md`. ufw's stock `before.rules` also accepts
  ICMP echo-request before user rules, so the same unit adds an `inet
  homelab_iot` nftables chain at priority -10 to drop private destinations and
  ICMP before ufw runs. Do not remove it just because the ufw rules look
  sufficient: pings would start working again.
- **The IoT AP depends on the host being unlocked and up.** Root is LUKS, so
  after a power loss the devices stay offline until the host is unlocked. It is
  one radio: no 5 GHz SSID, no DFS, and no client/AP concurrency in use.
- **`/etc/hostapd/iot.conf` contains the WPA passphrase.** hostapd cannot read
  it from a file and the AP must start before the first deploy renders `/run`,
  so the generated config persists at 0600 on the LUKS-encrypted root. sops
  (`iot_wifi_passphrase`) is still the source; `render-secrets.sh` rewrites it
  and restarts the unit only when the rendered config changed.
- **Deploy keys**: root on the host holds a Forgejo deploy key for
  `SakulFlee/HomeLab`. That key is what lets the timer fetch. Do not remove it
  without replacing the fetch mechanism.

## Verification

```bash
docker ps --format '{{.Names}}\t{{.Status}}'
systemctl --failed
systemctl list-timers | grep homelab
sudo /opt/homelab/scripts/healthcheck.sh
```

For Hermes:

```bash
docker exec hermes hermes webapp --status
docker logs --tail 50 hermes
```

For the IoT AP:

```bash
systemctl status homelab-iot-ap homelab-iot-dhcp homelab-iot-firewall
iw dev wlp2s0 info
cat /var/lib/misc/dnsmasq-iot.leases
```

When testing the segment from a phone, turn off its WireGuard tunnel first: an
authenticated VPN client reaches the LAN through `wg0`, not through `wlp2s0`,
and will make the isolation look broken.

For the backup chain:

```bash
sudo restic -r /srv/backup/restic --password-file /run/homelab/secrets/restic-password snapshots
# on Dendra:
restic -r /mnt/btrfs-raid1/backups/homelab/restic --password-file ~/.config/restic/dendra-password snapshots
```

## Legacy

The repository described a NixOS + Incus host until November 2026. `nixos/`,
`incus/`, `PLAN.md` and the migration docs were deleted; `git log -- nixos
incus` and the commits before their removal still contain them. None of it is
deployed, and nothing on the host runs `nix`, `nixos-rebuild`, `incus`, `tofu`
or `gen-tf.sh` any more.
