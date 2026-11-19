# Agent Notes

This repository is a Debian 13 + Docker Compose homelab. On the host it is
checked out at `/opt/homelab` and `deploy.sh` runs as root from there.

## What owns what

| layer | owner |
| --- | --- |
| host OS, packages, firewall, users | Debian on the host, provisioned by `scripts/bootstrap.sh` |
| host-specific settings (ports, bind IPs, runner capacity) | `/etc/homelab/host.env` on the host |
| services | `stacks/<name>/compose.yaml` |
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
validates every stack, snapshots `/srv/docker` with btrfs, then applies each
stack with `compose up -d --build --wait` and runs `healthcheck.sh`.

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
- **Syncthing folders live on the config volume.** `HOME=/var/syncthing`, so
  `~/…` paths resolve under `/srv/docker/syncthing/config`. `backup.sh`
  therefore excludes the whole `syncthing` tree, not just `syncthing/data`.
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
