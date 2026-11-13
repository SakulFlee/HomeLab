# Staging on the laptop

The laptop only needs Docker and the host-side tools. It does not need the
Debian bootstrap.

## Packages (CachyOS/Arch)

```bash
sudo pacman -S --needed docker docker-compose sops age restic jq git
sudo systemctl enable --now docker
```

## Clone and data

```bash
sudo git clone ssh://forgejo@forgejo.sakul-flee.de/SakulFlee/HomeLab.git /opt/homelab
sudo git -C /opt/homelab checkout v2
```

Restore copies of the data into `/srv/docker` with the ownership produced by
`scripts/prepare-data.sh`. For a full test, use the same bind-mount paths as
production; for a quick test, export `LIVE_DATA_DIR` to another directory.

Add the new sops keys from `docs/secrets.md` and place the age key where sops can
find it.

## Staging ports

The laptop is not the homelab, so change the host bindings:

```bash
export LAN_IP=127.0.0.1
export FORGEJO_SSH_HOST_PORT=2200
export HTTP_PORT=8080
export HTTPS_PORT=8443
export MINECRAFT_PORT=25566
export HYTALE_PORT=5521
export FLUXER_LIVEKIT_TCP_PORT=7883
export FLUXER_LIVEKIT_UDP_PORT=7884
```

`LAN_IP` changes CoreDNS, Dockge, Syncthing and Caddy's host-LAN target.
`FORGEJO_SSH_HOST_PORT` avoids the laptop's own sshd on 22.

## Start only what you need

Do not start CoreDNS (port 53), wg-easy (host networking) or Caddy on the laptop
unless you know the ports and DNS names are safe to use there.

```bash
sudo /opt/homelab/scripts/prepare-data.sh
sudo /opt/homelab/scripts/render-secrets.sh
sudo env \
  LAN_IP="$LAN_IP" \
  FORGEJO_SSH_HOST_PORT="$FORGEJO_SSH_HOST_PORT" \
  MINECRAFT_PORT="$MINECRAFT_PORT" \
  HYTALE_PORT="$HYTALE_PORT" \
  DEPLOY_STACKS="forgejo fluxer minecraft hytale" \
  SKIP_HEALTHCHECK=1 \
  /opt/homelab/scripts/deploy.sh --force
```

If you have not copied the Hytale payload yet, leave `hytale` out of
`DEPLOY_STACKS`; its entrypoint deliberately refuses to start without
`Server/HytaleServer.jar` and `Assets.zip`. The machine-id file itself is created
by `prepare-data.sh`.

Then check each stack:

```bash
sudo docker compose -f /opt/homelab/stacks/forgejo/compose.yaml ps
sudo docker compose -f /opt/homelab/stacks/minecraft/compose.yaml logs -f
sudo docker compose -f /opt/homelab/stacks/hytale/compose.yaml logs -f
```

For Forgejo, the SSH port is `2200` and the web port is `127.0.0.1:3000`.
Fluxer's internal edge is published on `127.0.0.1:8080` by its proxy overlay.

## Verify before moving

- Forgejo: login, 2FA, repository clone/push over SSH, LFS, packages, mail.
- Fluxer: login, message history, media, voice/video.
- Minecraft: world loads, plugins, whitelist, backup/restore.
- Hytale: auth, tmux console, `/backup`, restore.
- `restic backup` and `restic restore` against copies.

Once these pass, the same bind-mount trees can be moved to the homelab with
`rsync -aHAX --numeric-ids`.
