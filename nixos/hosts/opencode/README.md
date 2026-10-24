# opencode

A headless OpenCode server with the bundled web UI, reachable only over the
WireGuard VPN through Caddy.

## Architecture

- **Type**: Incus LXC container. OpenCode is a userspace Bun binary; it needs no
  Docker daemon, kernel modules or device passthrough.
- **Address**: `10.0.0.117/24` on `incusbr0`.
- **Web UI / API**: `opencode serve --hostname 0.0.0.0 --port 4096`. OpenCode
  2.1.1 serves both the v2 API and the web UI from `serve`.
- **External route**: `https://opencode.sakul-flee.de` only, VPN-gated by Caddy
  on `remote_ip 100.64.0.0/10`. There is no Incus network forward and no LAN
  listener.
- **Authentication**: the Caddy VPN gate plus OpenCode HTTP basic auth
  (`opencode` / `opencode_server_password`).
- **Limits**: 4 GiB RAM, 2 CPU.
- **Provider**: OpenCode Go, via `OPENCODE_API_KEY` rendered from sops. Models
  are selected as `opencode-go/<model-id>`.

## Volumes

| volume | mount | contents | snapshots |
| --- | --- | --- | --- |
| `opencode-home` | `/var/lib/opencode` | config, sessions, caches | none |
| `opencode-workspace` | `/srv/workspace` | git checkouts and uncommitted work | `@daily`, 7 days |

The root disk is disposable. Anything that must survive an image change lives on
one of these volumes.

## Secrets

The host renders three values into `/var/lib/incus-secrets` inside the guest:

| sops key | rendered file | consumer |
| --- | --- | --- |
| `opencode_server_password` | `opencode-server-env` | systemd EnvironmentFile |
| `opencode_go_api_key` | `opencode-go-env` | systemd EnvironmentFile |
| `opencode_forgejo_token` | `forgejo-token` (0440, group `opencode`) | git credential helper |

The Forgejo token is a dedicated access token with repository read/write. It is
read by the `git-credential-forgejo` helper at each git operation, not embedded
in a remote URL. The helper uses the Forgejo username `sakulflee`; change
`forgejoUser` in `default.nix` if the token belongs to another account.

Retrieve the web password on the host with:

```bash
sops -d --extract '["opencode_server_password"]' nixos/secrets.yaml
```

Rotate a value with `sops set` and then restart `incus-secrets.service`; the
service restarts `opencode.service` when a rendered file changes.

## Clients

Web UI, from a VPN-connected device:

```text
https://opencode.sakul-flee.de
```

Terminal client connected to the same server:

```bash
export OPENCODE_SERVER_PASSWORD='...'
opencode --server https://opencode.sakul-flee.de
```

The client must be the same major version as the server. The server is pinned to
OpenCode 2.1.1; `opencode attach` from the v1 CLI is not supported by v2.

The workspace starts empty. Clone repositories from Forgejo into
`/srv/workspace` from inside a session, or:

```bash
incus exec opencode -- su -s /bin/sh opencode -c \
  'cd /srv/workspace && git clone https://forgejo.sakul-flee.de/SakulFlee/HomeLab.git'
```

## Verification

```bash
incus exec opencode -- systemctl is-system-running
incus exec opencode -- systemctl is-active opencode
incus exec opencode -- curl -fsS -u "opencode:$PASSWORD" \
  http://127.0.0.1:4096/api/config >/dev/null
```

In v2 the API lives under `/api`; the web UI is served from `/`.

From the LAN the vhost must reject with 403:

```bash
curl --resolve opencode.sakul-flee.de:443:192.168.178.200 \
  https://opencode.sakul-flee.de/ -o /dev/null -w '%{http_code}\n'
```

From a VPN-connected client the same request must succeed (with basic auth).
