# Restore runbook

The local restic repository is `/srv/backup/restic`. The off-box copy is on
Dendra at `/srv/restic/homelab`, copied with `restic copy`.

Always restore into a staging directory or a stopped stack first. Do not restore
a live PostgreSQL data directory over a running database.

## Inspect

```bash
sudo /opt/homelab/scripts/restore.sh snapshots
sudo /opt/homelab/scripts/restore.sh ls latest /srv/docker/forgejo
```

## Restore everything to a staging directory

```bash
sudo /opt/homelab/scripts/restore.sh restore /srv/restore
```

Then copy the parts you need into `/srv/docker`. Use `rsync -aHAX --numeric-ids`
to preserve ownership.

## Forgejo

1. Stop Forgejo:

   ```bash
   cd /opt/homelab/stacks/forgejo
   sudo docker compose stop forgejo
   ```

2. Restore the data tree and the `custom` directory:

   ```bash
   sudo rsync -aHAX --numeric-ids /srv/restore/srv/docker/forgejo/data/ /srv/docker/forgejo/data/
   sudo rsync -aHAX --numeric-ids /srv/restore/srv/docker/forgejo/custom/ /srv/docker/forgejo/custom/
   ```

3. Restore PostgreSQL from the dump:

   ```bash
   cd /opt/homelab/stacks/forgejo
   sudo docker compose up -d db
   sudo docker compose exec -T db dropdb -U forgejo --if-exists forgejo
   sudo docker compose exec -T db createdb -U forgejo forgejo
   sudo docker compose exec -T db pg_restore -U forgejo -d forgejo --clean --if-exists \
     < /srv/restore/srv/backup/dumps/forgejo-YYYYMMDDTHHMMSSZ.dump
   ```

4. Start Forgejo and verify login, repositories, LFS, and SSH push.

## Fluxer

1. Stop the stack:

   ```bash
   cd /opt/homelab/stacks/fluxer
   sudo docker compose down
   ```

2. Restore the bind-mounted volumes:

   ```bash
   sudo rsync -aHAX --numeric-ids /srv/restore/srv/docker/fluxer/ /srv/docker/fluxer/
   ```

3. Start Postgres first, restore the dump, then start the rest:

   ```bash
   sudo docker compose up -d postgres
   sudo docker compose exec -T postgres dropdb -U fluxer --if-exists fluxer
   sudo docker compose exec -T postgres createdb -U fluxer fluxer
   sudo docker compose exec -T postgres pg_restore -U fluxer -d fluxer --clean --if-exists \
     < /srv/restore/srv/backup/dumps/fluxer-YYYYMMDDTHHMMSSZ.dump
   sudo docker compose up -d
   ```

4. Verify login, messages, media, and LiveKit.

## Minecraft

```bash
cd /opt/homelab/stacks/minecraft
sudo docker compose stop
sudo rsync -aHAX --numeric-ids /srv/restore/srv/docker/minecraft/ /srv/docker/minecraft/
sudo chown -R 988:988 /srv/docker/minecraft
sudo docker compose up -d
```

Verify the world version in the log and connect with a client.

## Hytale

```bash
cd /opt/homelab/stacks/hytale
sudo docker compose stop
sudo rsync -aHAX --numeric-ids /srv/restore/srv/docker/hytale/ /srv/docker/hytale/
sudo chown -R 989:989 /srv/docker/hytale/data /srv/docker/hytale/secrets
sudo docker compose up -d
```

The machine-id file must be restored with `auth.enc`. If it is missing or
mismatched, run `/auth login device` from the tmux console.

## Host loss

1. Install Debian 13 and run `scripts/bootstrap.sh`.
2. Restore the sops age key.
3. If Dendra is available, point `RESTIC_REPOSITORY` at the Dendra copy and
   restore from there. Otherwise restore from the SATA repo.
4. Restore `/srv/docker` and the database dumps.
5. Start the stacks with `scripts/deploy.sh`.
