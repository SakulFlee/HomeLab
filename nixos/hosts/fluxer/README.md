# Fluxer (Incus VM, Docker Compose)

This hosts runs Fluxer using the official upstream self-hosting method (Docker Compose) inside an Incus VM. It follows the same pattern as the wireguard VM.

## Architecture

- **Type**: Incus VM (type=vm) - required because it runs Docker inside the guest.
- **IP**: 10.0.0.102/24 (on incusbr0)
- **Volumes**:
  - `fluxer-data` (block, ext4): mounted at `/var/lib/docker` inside the VM. Contains all Docker data (Postgres, SeaweedFS state, etc.). Snapshots enabled daily with 7d retention via Incus.
- **Network forwards** (public IP 192.168.178.200):
  - TCP 7881 -> 10.0.0.102:7881 (LiveKit)
  - UDP 7882 -> 10.0.0.102:7882 (LiveKit)
- **Edge**: Uses upstream `docker-compose.proxy.yml` overlay. Fluxer binds to `127.0.0.1:8080` in the compose (via `FLUXER_EDGE_BIND`), exposed on the VM as port 8080. Caddy on the host reverse-proxies to `http://10.0.0.102:8080`.

## Upstream files

The official stack files from `fluxerapp/fluxer` (deploy/self-hosting) are vendored in `vendor/` and copied into the VM at build time to `/opt/fluxer/`:
- `docker-compose.yml`
- `docker-compose.proxy.yml` (overlay)
- `Caddyfile`
- `livekit.yaml`
- `.env.example`

The VM's `fluxer-compose.service` starts the stack with: `docker compose -f docker-compose.yml -f docker-compose.proxy.yml up -d`.

## Configuration (.env)

On first start, `.env.example` is copied to `.env` in `/opt/fluxer/`. You'll need to:
1. Set the public hostname (`FLUXER_PUBLIC_HOSTNAME`, `FLUXER_CADDY_SITE_ADDRESS` as appropriate for your setup).
2. Generate secrets as per upstream docs (or from `.env.example` instructions). Many can be left as generated on first run depending on upstream behavior.

**Note**: Sensitive values can also be provided via environment/sops if needed, but for now the non-secret template is copied and can be edited in the VM.

## Data migration

From the k3s Fluxer deployment:

1. **Stop writers** in k3s (scale down Fluxer) to get consistent state.
2. **Database (Postgres)**: Copy PGDATA from the k3s Postgres PVC into the VM's Postgres data volume. Since we're using Incus volume snapshots (btrfs), volume-level snapshots are the backup mechanism. For migration, copy files while Postgres is stopped in k3s and ensure correct ownership/permissions in the VM.
3. **Media (SeaweedFS)**: Skipped per requirements - does not need to be copied.
4. **Caches (NATS/Meilisearch/Valkey)**: Skipped - rebuildable.

Start the VM stack after restoring DB data. Verify connectivity.

## Backups

Backups use **Incus volume snapshots** (atomic, crash-consistent). The `fluxer-data` block volume has:
- `snapshots.schedule = "@daily"`
- `snapshots.expiry = "7d"`

Restore from snapshots via `incus storage volume snapshot restore` as needed.

## Caddy cutover (when ready)

**Do not change Caddy now.** Once Fluxer is confirmed working, cut over routing:

1. Remove `"fluxer.sakul-flee.de"` from `nixos/hosts/caddy/hostnames.nix`
2. Add a site block in `nixos/hosts/caddy/default.nix` pointing to the VM:

```nix
"fluxer.sakul-flee.de" = {
  extraConfig = ''
    reverse_proxy http://10.0.0.102:8080
  '';
};
```

3. Rebuild and apply Caddy.

Until then, `fluxer.sakul-flee.de` continues routing to Traefik/k3s as-is.

## Rollback

- Revert Caddy changes (put hostname back in hostnames.nix, remove dedicated block). Traffic returns to k3s.
- k8s manifests remain untouched; can scale Fluxer back up.
- VM can be stopped; volumes remain intact for rollback.

## Build/deploy

The flake adds:
- `nixosConfigurations.fluxer` (kind=vm)
- `packages.image-fluxer` (qcow2 image)

Deploy via `incus/apply.sh fluxer` once registered. 
