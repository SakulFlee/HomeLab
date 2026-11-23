# Restore runbook

The local restic repository is `/srv/backup/restic` (password
`/run/homelab/secrets/restic-password`). The off-box copy is on Dendra at
`/mnt/btrfs-raid1/backups/homelab/restic` on Dendra (password
`~/.config/restic/dendra-password`).

Dendra pulls the copy itself every 30 minutes over a read-only sftp key; the
homelab cannot reach Dendra. To restore from the copy, run restic on Dendra:

```bash
restic -r /mnt/btrfs-raid1/backups/homelab/restic --password-file ~/.config/restic/dendra-password \
  snapshots
```

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

Assuming the data is already below `/srv/docker/forgejo` (either restored in
the migration or from a restic snapshot):

1. Stop the whole stack:

   ```bash
   cd /opt/homelab/stacks/forgejo
   sudo docker compose down
   ```

2. Make sure the data is in place and owned correctly:

   ```bash
   sudo mkdir -p /srv/docker/forgejo/ssh-keys
   sudo cp /srv/docker/forgejo/data/ssh/ssh_host_ed25519_key \
           /srv/docker/forgejo/data/ssh/ssh_host_ed25519_key.pub \
           /srv/docker/forgejo/data/ssh/ssh_host_rsa_key \
           /srv/docker/forgejo/data/ssh/ssh_host_rsa_key.pub \
           /srv/docker/forgejo/ssh-keys/
   sudo chown -R 1000:1000 /srv/docker/forgejo/data
   sudo chown -R 1000:1000 /srv/docker/forgejo/custom
   sudo chown -R 1000:1000 /srv/docker/forgejo/ssh-keys
   sudo chmod 0600 /srv/docker/forgejo/ssh-keys/ssh_host_*_key
   sudo chmod 0644 /srv/docker/forgejo/ssh-keys/ssh_host_*_key.pub
   ```

   If you copied the old `custom` directory, remove its `app.ini`; the stack
   generates it from the environment:

   ```bash
   sudo rm -f /srv/docker/forgejo/custom/conf/app.ini
   ```

3. Start only the database, then restore the dump:

   ```bash
   sudo docker compose up -d db
   # wait for "database system is ready to accept connections"
   sudo docker compose exec -T db sh -c \
     'PGPASSWORD="$(cat /run/secrets/forgejo_db_password)" dropdb -U forgejo --if-exists forgejo'
   sudo docker compose exec -T db sh -c \
     'PGPASSWORD="$(cat /run/secrets/forgejo_db_password)" createdb -U forgejo forgejo'
   sudo docker compose exec -T db sh -c \
     'PGPASSWORD="$(cat /run/secrets/forgejo_db_password)" pg_restore -U forgejo -d forgejo --clean --if-exists --no-owner --no-acl' \
     < /srv/migration/forgejo.dump
   ```

4. Start Forgejo:

   ```bash
   sudo docker compose up -d
   sudo docker compose logs -f forgejo
   ```

5. Verify login, repositories, LFS and SSH push.

## Fluxer

1. Stop the stack:

   ```bash
   cd /opt/homelab/stacks/fluxer
   sudo ./compose.sh down
   ```

2. Restore the SeaweedFS media volume:

   ```bash
   sudo rsync -aHAX --numeric-ids \
     /tmp/fluxer-volumes/fluxer_seaweedfs-data/ \
     /srv/docker/fluxer/seaweedfs-data/
   ```

3. Start Postgres only, restore the dump, then start the rest:

   ```bash
   sudo ./compose.sh up -d postgres
   # wait for the healthcheck
   sudo ./compose.sh exec -T postgres sh -c \
     'PGPASSWORD="$POSTGRES_PASSWORD" dropdb -U fluxer --if-exists fluxer'
   sudo ./compose.sh exec -T postgres sh -c \
     'PGPASSWORD="$POSTGRES_PASSWORD" createdb -U fluxer fluxer'
   sudo ./compose.sh exec -T postgres sh -c \
     'PGPASSWORD="$POSTGRES_PASSWORD" pg_restore -U fluxer -d fluxer --clean --if-exists --no-owner --no-acl' \
     < /srv/migration/fluxer.dump
   sudo ./compose.sh up -d
   ```

4. Verify login, messages, media and LiveKit.

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

## Paperless

The nightly backup contains a hot `pg_dump` plus the media, data, consume and
export directories. The search index is excluded because it is derived data.

1. Stop the stack:

   ```bash
   cd /opt/homelab/stacks/paperless
   sudo docker compose down
   ```

2. Create the mount points, then restore the directories and ownership:

   ```bash
   sudo /opt/homelab/scripts/prepare-data.sh
   sudo rsync -aHAX --numeric-ids /srv/restore/srv/docker/paperless/ /srv/docker/paperless/
   sudo chown -R 1000:1000 \
     /srv/docker/paperless/data \
     /srv/docker/paperless/media \
     /srv/docker/paperless/consume \
     /srv/docker/paperless/export
   sudo chown -R 70:70 /srv/docker/paperless/postgres
   sudo chown -R 999:999 /srv/docker/paperless/valkey
   ```

3. Start only the database, then restore the dump:

   ```bash
   sudo docker compose up -d db
   pw="$(sudo cat /run/homelab/secrets/paperless/paperless_db_password)"
   sudo docker compose exec -T -e PGPASSWORD="$pw" db \
     dropdb -U paperless --if-exists paperless
   sudo docker compose exec -T -e PGPASSWORD="$pw" db \
     createdb -U paperless paperless
   sudo docker compose exec -T -e PGPASSWORD="$pw" db \
     pg_restore -U paperless -d paperless --clean --if-exists --no-owner --no-acl \
     < /srv/backup/dumps/paperless-<stamp>.dump
   ```

4. Start the rest and rebuild the search index:

   ```bash
   sudo docker compose up -d --wait
   sudo docker compose exec paperless document_index reindex --recreate
   ```

5. Verify login, documents, and upload one PDF and one DOCX.

This runbook is for the Docker-era backups. The pre-Docker library left no
database, so there is nothing from that installation to restore.

Ollama's model store is not backed up. After a host rebuild, pull `gemma4:e4b`
and `embeddinggemma` again; the LLM index under `data/llm_index` is restored
from restic and remains valid for the same embedding model. Rebuild it with
`document_llmindex rebuild` if the embedding model changed.

## Hermes

`/srv/docker/hermes` is the whole state: `state.db` (sessions and memory
indexes), `config.yaml`, `.env`, `memories/`, `skills/`, `logs/` and
`workspace/`. `backup.sh` stops the container before restic runs, so the
restored SQLite database is consistent.

1. Stop the stack:

   ```bash
   cd /opt/homelab/stacks/hermes
   sudo docker compose down
   ```

2. Restore the tree and ownership:

   ```bash
   sudo /opt/homelab/scripts/prepare-data.sh
   sudo rsync -aHAX --numeric-ids /srv/restore/srv/docker/hermes/ /srv/docker/hermes/
   sudo chown -R 991:991 /srv/docker/hermes
   sudo chmod 0700 /srv/docker/hermes /srv/docker/hermes/home
   ```

3. Start it and check the webapp:

   ```bash
   sudo docker compose up -d --wait
   sudo docker exec hermes hermes webapp --status
   ```

   `config.yaml` is runtime state. Do not overwrite a restored copy with the
   seed in `stacks/hermes/config.yaml`.

## Host loss

1. Install Debian 13 and run `scripts/bootstrap.sh`.
2. Restore the sops age key.
3. If Dendra is available, point `RESTIC_REPOSITORY` at the Dendra copy and
   restore from there. Otherwise restore from the SATA repo.
4. Restore `/srv/docker` and the database dumps.
5. Start the stacks with `scripts/deploy.sh`.
