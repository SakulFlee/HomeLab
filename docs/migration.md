# Migration checklist

This is the concrete version of `PLAN.md` phase 0/1. Run the export commands on
the current NixOS host as root, with the relevant services stopped.

The Incus-volume-specific export commands are in
[`incus-export.md`](incus-export.md).

## 1. Stop writers

```bash
incus exec forgejo -- systemctl stop forgejo
incus exec fluxer -- systemctl stop fluxer-compose
incus exec minecraft -- systemctl stop minecraft
incus exec hytale -- systemctl stop hytale
```

## 2. Forgejo

### Database

```bash
incus exec forgejo -- sudo -u postgres \
  pg_dump -Fc forgejo > /srv/backup/dumps/forgejo.dump
```

### Data

```bash
incus storage volume export persistent forgejo-data /srv/backup/forgejo-data.tar
incus file pull -r forgejo/var/lib/forgejo/custom /srv/backup/forgejo-custom
```

The data volume contains the repositories, LFS, packages, attachments, avatars,
`ssh` host keys and `git/.gnupg`. Keep all of it.

Do **not** copy the old `custom/conf/app.ini` over the new one. The new stack
generates `app.ini` from environment variables in `stacks/forgejo/compose.yaml`.
The old file is useful as a reference only. The five secret values come from
sops, not from the old config.

### New database password

Add a new `forgejo_db_password` to sops (see `docs/secrets.md`). The old NixOS
deployment used peer authentication over a Unix socket; Docker uses a password.

## 3. Fluxer

Fluxer already runs Docker Compose inside its VM. Its data lives in Docker named
volumes under `/var/lib/docker/volumes`.

```bash
incus exec fluxer -- docker compose -f /opt/fluxer/docker-compose.yml \
  -f /opt/fluxer/docker-compose.proxy.yml down

incus exec fluxer -- tar -C /var/lib/docker/volumes -czf /tmp/fluxer-volumes.tar.gz \
  fluxer_postgres-data fluxer_seaweedfs-data fluxer_meilisearch-data \
  fluxer_nats-data fluxer_valkey-data fluxer_edge-data fluxer_edge-config

incus file pull fluxer/tmp/fluxer-volumes.tar.gz /srv/backup/fluxer-volumes.tar.gz
```

Also dump PostgreSQL while the stack is up, before `down`:

```bash
incus exec fluxer -- docker exec -e PGPASSWORD="$(incus exec fluxer -- \
  cat /var/lib/incus-secrets/fluxer_postgres_password)" \
  fluxer-postgres-1 pg_dump -Fc -U fluxer -d fluxer \
  > /srv/backup/dumps/fluxer.dump
```

The container name may differ; check `incus exec fluxer -- docker ps`.

New host layout:

```text
/srv/docker/fluxer/postgres-data       <- restore from dump, not a live file copy
/srv/docker/fluxer/seaweedfs-data      <- copy the volume contents
/srv/docker/fluxer/meilisearch-data    <- optional, rebuildable
/srv/docker/fluxer/nats-data           <- optional, rebuildable
/srv/docker/fluxer/valkey-data         <- optional, rebuildable
```

The `compose.override.yaml` in `stacks/fluxer/` maps the upstream volumes to
those bind mounts.

## 4. Minecraft

```bash
incus storage volume export persistent minecraft-data /srv/backup/minecraft-data.tar
incus storage volume export persistent minecraft-backups /srv/backup/minecraft-backups.tar
```

The new host mounts the data at `/srv/docker/minecraft`. Preserve
`server.jar`, `.paper-build`, `plugins/`, the world and the config files. The
stack pins Paper 26.3 and Java 25; do not let a generic image update the world.

## 5. Hytale

```bash
incus exec hytale -- sudo systemctl start hytale
# wait for the server, then:
incus exec hytale -- sudo -u hytale tmux send-keys -t hytale '/backup' Enter
# wait for a new zip in /var/lib/hytale/Server/backups
incus exec hytale -- sudo systemctl stop hytale

incus storage volume export persistent hytale-data /srv/backup/hytale-data.tar
incus storage volume export persistent hytale-backups /srv/backup/hytale-backups.tar
incus storage volume export persistent hytale-secrets /srv/backup/hytale-secrets.tar
```

Keep `.machine-id` and `Server/auth.enc` together with the data. On the new
host, copy the old `/var/lib/hytale/.machine-id` to:

```text
/srv/docker/hytale/machine-id
```

Do this before starting the Hytale container. If the file is missing, Docker
creates a directory at that bind-mount path and the container refuses to start.
If the new container gets a different machine id, the server will need one
`/auth login device`.

## 6. Host keys and secrets

```bash
cp -a /etc/ssh/ssh_host_ed25519_key* /srv/backup/
cp -a /etc/nixos/.sops.yaml /srv/backup/
# On the old NixOS branch the encrypted file is nixos/secrets.yaml. On v2 it
# moves to secrets/secrets.yaml.
cp -a /etc/nixos/nixos/secrets.yaml /srv/backup/
```

The age key is derived from the host SSH key unless a dedicated
`/etc/sops/age/keys.txt` is used. Keep both paths.

Also back up the Caddy data volume if you want to avoid reissuing certificates:

```bash
incus storage volume export persistent caddy-data /srv/backup/caddy-data.tar
```

## 7. Copy to Dendra

```bash
rsync -aHAX --info=progress2 /srv/backup/ dendra:/srv/homelab-migration/
```

Verify the Forgejo dump and at least one game archive before wiping anything.
Stage the new stack on the laptop from this copy.

## 8. New host

1. Install Debian 13.
2. Run `scripts/bootstrap.sh`.
3. Restore the sops age key.
4. Restore `/srv/docker` from the exports.
5. Restore Forgejo and Fluxer PostgreSQL from the dumps (see
   `docs/restore.md`).
6. Run `scripts/render-secrets.sh` and `scripts/deploy.sh --force`.
7. Verify Forgejo SSH on port 22 and the host on 2222.
8. Format the SATA disk as `/srv/backup` only after the data is verified on the
   NVMe.
9. Run `scripts/backup.sh` and configure `scripts/restic-copy.sh`.
