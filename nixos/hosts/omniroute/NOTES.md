# OmniRoute (Incus instance)

The homelab's AI gateway: a unified OpenAI-compatible `/v1` API in front of
many providers, with load balancing, failover, credential storage and a
dashboard. Upstream is [diegosouzapw/OmniRoute](https://github.com/diegosouzapw/OmniRoute)
(npm `omniroute`), packaged in-repo from the npm release -- see `package.nix`
for how the prebuilt Next.js `dist/` and the git tree's lock are combined.

- Address: `10.0.0.118` on `incusbr0`, `default` project.
- GUI/API: `https://omniroute.sakul-flee.de` only, VPN-gated by Caddy. There is
  no host-level forward for 20128.
- Data: `omniroute-data` at `/var/lib/omniroute` (SQLite DB, encrypted provider
  credentials, internal backups), `@hourly`/`7d` snapshots. `omniroute-secrets`
  at `/var/lib/incus-secrets` holds the host-rendered EnvironmentFiles and is
  deliberately not snapshotted.
- Limits: 4GiB / 2 CPU. Watch `incus info omniroute` under real traffic before
  tightening.

## Two gates, not one

1. The Caddy vhost refuses anything whose source is not the WireGuard tunnel
   (`@notvpn` / `100.64.0.0/10`), same as every other VPN-only name.
2. `REQUIRE_API_KEY=true`: `/v1` needs a gateway key minted in the dashboard.
   The guest firewall also confines 20128/tcp to traffic arriving on eth0, so
   only the host, the other LXCs and Caddy's proxy can reach the port at all.

The second gate is the one that matters if a VPN device is ever compromised --
an unauthenticated `/v1` is an open wallet.

## First login, and recovering the password

`INITIAL_PASSWORD` is a sops secret, generated on the host at first deploy. To
read it back (on the host):

```sh
SOPS_AGE_KEY=$(sudo ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key) \
  sops -d /etc/nixos/nixos/secrets.yaml | grep -A0 omniroute_initial_password
```

Change it on first login. Forgotten later: `incus exec omniroute -- omniroute
reset-password` (the CLI is in PATH in the guest).

## Minting a gateway key

Dashboard -> API keys (or Settings -> Keys): mint one, give it to each client
(opencode, curl, ...). Clients call `https://omniroute.sakul-flee.de/v1` with
`Authorization: Bearer <key>`. A dashboard login and a gateway key are
different things; only the key is accepted on `/v1`.

## Snapshots and rollback

```sh
incus storage volume snapshot list persistent omniroute-data
incus storage volume snapshot restore persistent omniroute-data <snapshot>
```

Provider credentials in the volume are ciphertext (the keys arrive via the
environment), so snapshots are safe to keep. Losing `STORAGE_ENCRYPTION_KEY`
from sops means losing the ability to decrypt them -- it is in the host's
secrets.yaml and restic-backed with everything else there.

## Known limitations

- The live-monitoring WebSocket (`LIVE_WS_PORT=20129`, loopback inside the
  guest) is not proxied by the vhost, so the dashboard's live view may fall
  back. `/healthz` and `journalctl -u omniroute` are the health checks that
  work through the normal path.
- Optional natives (`better-sqlite3`, `wreq-js`, `keytar`, `onnxruntime-node`)
  may be skipped if their offline source build fails; OmniRoute falls back to
  `sql.js` (WASM) for storage and degrades the features the others power. If
  that ever matters, the fix is in `package.nix`'s native-dependency notes.

## Recreate semantics

The instance is disposable; the volumes are not. Deleting and re-applying the
instance loses nothing that is not in a snapshot or re-rendered from the host
(same standard as `syncthing/NOTES.md`). Rollback of the whole service is
deleting the Caddy site block and the registry entries -- there is no k3s
deployment left to fall back to.
