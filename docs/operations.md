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
  repositories. Because keep-daily keeps one snapshot per day, a same-day
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

## Secrets

- `secrets/secrets.yaml` is sops/age encrypted. The host identity lives at
  `/etc/sops/age/keys.txt`; `scripts/sops.sh` is the wrapper that uses it.
- `render-secrets.sh` writes `/run/homelab/secrets/*`, per-stack `.env` files
  for Compose, the runner config, and `/etc/homelab/notify.env`.
- Store the age key, both restic repository passwords and the LUKS recovery
  passphrase offline.
- Never regenerate Forgejo's `SECRET_KEY` on an existing database.

## Troubleshooting

Start with the sharp-edges section in [../AGENTS.md](../AGENTS.md). The most
common symptoms:

| symptom | look at |
| --- | --- |
| VPN clients get no internet but ping works | `ufw route allow in on wg0`, wg-easy `interfaces_table.device` |
| Admin UIs return 403 | split-horizon DNS / `/etc/hosts`, Cloudflare proxy |
| Broken avatars or attachments in Forgejo | `FORGEJO__picture__*`, `FORGEJO__attachment__PATH` |
| Deploy timer restarts everything every 30 min | checkout ahead of `origin/main` |
| Backups suddenly much larger | new path under `/srv/docker` that is not excluded |

## Legacy

`PLAN.md`, `docs/migration.md` and `docs/incus-export.md` describe the retired
NixOS + Incus host and the cutover to this one.

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
