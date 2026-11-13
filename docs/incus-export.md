# Exporting the Incus data

Run this on the homelab host as root. The goal is to get application-level dumps
plus the volume roots onto the laptop, not to copy live database directories.

Create a staging directory:

```bash
install -d -m 0755 /srv/backup/migration
```

## 1. Stop writers

```bash
incus exec forgejo -- systemctl stop forgejo
incus exec minecraft -- systemctl stop minecraft
incus exec fluxer -- systemctl stop fluxer-compose
```

For Hytale, ask for an archive first, then stop it:

```bash
incus exec hytale -- sudo systemctl start hytale
# wait until it is serving
incus exec hytale -- sudo -u hytale tmux send-keys -t hytale '/backup' Enter
# wait for a new zip in /var/lib/hytale/Server/backups
incus exec hytale -- sudo systemctl stop hytale
```

Verify with:

```bash
incus exec hytale -- ls -lt /var/lib/hytale/Server/backups | head
```

## 2. Forgejo

Forgejo lives in the `forgejo` Incus project.

```bash
incus exec forgejo -- sudo -u postgres \
  pg_dump -Fc forgejo > /srv/backup/migration/forgejo.dump

incus --project forgejo storage volume export \
  persistent forgejo-data /srv/backup/migration/forgejo-data.tar

incus file pull -r forgejo/var/lib/forgejo/custom \
  /srv/backup/migration/forgejo-custom
```

`forgejo-postgres` is **not** needed; the dump is the logical database backup.
`forgejo-repo-archive` is a generated cache and can be skipped.

The data volume contains:

```text
git/gitea-repositories/
lfs/
attachments/
avatars/
packages/
ssh/
git/.gnupg/
```

Do not copy the old `custom/conf/app.ini` over the new one. The v2 stack
generates app.ini from environment variables. The old `custom` directory is
reference material.

## 3. Minecraft

```bash
incus storage volume export persistent minecraft-data \
  /srv/backup/migration/minecraft-data.tar

incus storage volume export persistent minecraft-backups \
  /srv/backup/migration/minecraft-backups.tar
```

The data volume contains the world, plugins, `server.properties`,
`whitelist.json`, `ops.json` and `eula.txt`.

## 4. Hytale

```bash
incus storage volume export persistent hytale-data \
  /srv/backup/migration/hytale-data.tar

incus storage volume export persistent hytale-backups \
  /srv/backup/migration/hytale-backups.tar

incus storage volume export persistent hytale-secrets \
  /srv/backup/migration/hytale-secrets.tar
```

The `.machine-id` is at the root of `hytale-data` (`.machine-id`). It must be
copied to `/srv/docker/hytale/machine-id` on the new host together with
`Server/auth.enc`.

## 5. Fluxer

Fluxer is a VM with an ext4 block volume mounted at `/var/lib/docker`. Do not
try to use that block image as a database backup. Dump PostgreSQL and tar the
Docker named volumes from inside the VM.

First find the PostgreSQL container name:

```bash
incus exec fluxer -- docker ps --format '{{.Names}}'
```

Then dump the database (adjust the container name if needed):

```bash
incus exec fluxer -- docker exec -e PGPASSWORD="$(incus exec fluxer -- \
  cat /var/lib/incus-secrets/fluxer_postgres_password)" \
  fluxer-postgres-1 pg_dump -Fc -U fluxer -d fluxer \
  > /srv/backup/migration/fluxer.dump
```

Stop the stack and tar the volumes:

```bash
incus exec fluxer -- docker compose \
  -f /opt/fluxer/docker-compose.yml \
  -f /opt/fluxer/docker-compose.proxy.yml down

incus exec fluxer -- tar -C /var/lib/docker/volumes -czf - \
  fluxer_postgres-data \
  fluxer_seaweedfs-data \
  fluxer_meilisearch-data \
  fluxer_nats-data \
  fluxer_valkey-data \
  fluxer_edge-data \
  fluxer_edge-config \
  > /srv/backup/migration/fluxer-volumes.tar.gz
```

Only `fluxer_seaweedfs-data` is structurally important for recovery. PostgreSQL
comes from the dump; Meilisearch, NATS and Valkey are rebuildable. Copying them
anyway makes staging faster.

## 6. Host keys and secrets

```bash
cp -a /etc/ssh/ssh_host_ed25519_key* /srv/backup/migration/
cp -a /etc/nixos/.sops.yaml /srv/backup/migration/
cp -a /etc/nixos/nixos/secrets.yaml /srv/backup/migration/
```

If you use a dedicated `/etc/sops/age/keys.txt`, copy that too.

## 7. Copy to the laptop

From the laptop:

```bash
rsync -aHAX --info=progress2 \
  -e 'ssh -p 2222' \
  saku@192.168.178.200:/srv/backup/migration/ \
  /srv/migration/
```

Adjust the user/port. Verify at least:

```bash
tar -tf /srv/migration/forgejo-data.tar | head
tar -tf /srv/migration/minecraft-data.tar | head
tar -tf /srv/migration/hytale-data.tar | head
tar -tzf /srv/migration/fluxer-volumes.tar.gz | head
```

If a tar contains a top-level directory instead of the volume contents, extract
it to a temporary directory and move the contents into the target path.

## 8. Restore on the laptop

Stop the staging stacks before replacing data:

```bash
cd /opt/homelab
sudo docker compose -f stacks/forgejo/compose.yaml down
sudo docker compose -f stacks/fluxer/compose.yaml down
sudo docker compose -f stacks/minecraft/compose.yaml down
sudo docker compose -f stacks/hytale/compose.yaml down
```

Extract the filesystem volumes:

```bash
# Incus exports wrap the payload in backup/volume/. Strip those two
# components so the volume contents land directly in the target directory.
sudo tar -xf /srv/migration/forgejo-data.tar --strip-components=2 -C /srv/docker/forgejo/data
sudo tar -xf /srv/migration/minecraft-data.tar --strip-components=2 -C /srv/docker/minecraft
sudo tar -xf /srv/migration/hytale-data.tar --strip-components=2 -C /srv/docker/hytale/data
sudo tar -xf /srv/migration/hytale-secrets.tar --strip-components=2 -C /srv/docker/hytale/secrets
sudo tar -xf /srv/migration/hytale-backups.tar --strip-components=2 -C /srv/docker/hytale/data/Server/backups
```

Fix ownership:

```bash
sudo chown -R 1000:1000 /srv/docker/forgejo/data /srv/docker/forgejo/custom
sudo chown -R 988:988 /srv/docker/minecraft
sudo chown -R 989:989 /srv/docker/hytale/data /srv/docker/hytale/secrets
```

Copy the old Hytale machine-id over the generated staging one:

```bash
sudo install -m 0444 /srv/docker/hytale/data/.machine-id \
  /srv/docker/hytale/machine-id
```

Fluxer volumes:

```bash
sudo mkdir -p /tmp/fluxer-volumes
sudo tar -xzf /srv/migration/fluxer-volumes.tar.gz -C /tmp/fluxer-volumes
sudo rsync -aHAX --numeric-ids /tmp/fluxer-volumes/fluxer_seaweedfs-data/ \
  /srv/docker/fluxer/seaweedfs-data/
```

Then restore PostgreSQL from the dumps using `docs/restore.md`.

Start with the database containers only, restore the dumps, then bring up the
full stacks.
