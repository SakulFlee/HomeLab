# HomeLab

A NixOS homelab managed as code. The bare-metal host runs Incus; the guests are
built as NixOS containers or VMs, and their Incus lifecycle is owned by
OpenTofu.

This is **not** a Kubernetes/Flux repository any more. k3s and Flux have been
removed; the remaining HTTP entry point is the `caddy` Incus instance.

## Layout

| path | what it is |
| --- | --- |
| `nixos/` | the flake; host and guest NixOS configurations |
| `nixos/hosts/homelab/` | the bare-metal host |
| `nixos/hosts/<name>/` | one guest: `default.nix` is the OS, `incus.nix` is the Incus definition |
| `nixos/incus-instances.nix` | the registry of guests |
| `incus/gen-tf.sh` | builds guest images and regenerates the Tofu JSON |
| `incus/infra/` | OpenTofu provider and static infrastructure |
| `incus/import.sh` | one-time adoption / disaster-recovery import tool |
| `AGENTS.md` | operating rules, including add/remove deployment checklists |
| `incus/README.md` | image, secret, network and provider details |
| `nixos/README.md` | host onboarding and NixOS layout |

On the homelab host this repository is `/etc/nixos`, and the flake is
`/etc/nixos/nixos`.

## How a deploy works

The registry and the per-host Nix files are the source of truth:

```text
nixos/incus-instances.nix
        │
        ├── nixos/hosts/<name>/default.nix   guest OS
        └── nixos/hosts/<name>/incus.nix     limits, volumes, devices, secrets
                    │
                    ▼
              nixos/flake.nix outputs
                    │
                    ▼
              incus/gen-tf.sh
                    │  builds images + writes generated.tf.json
                    ▼
              tofu plan / apply
                    │
                    ▼
              Incus resources
```

Secrets are the one exception: the host decrypts sops values and
`incus-secrets.service` renders them into the guests. Tofu never holds
plaintext secrets.

Normal deploy, run on the host:

```bash
cd /etc/nixos
incus/gen-tf.sh
cd incus/infra
tofu plan -out=deploy.tfplan
tofu apply deploy.tfplan
systemctl start incus-secrets.service
tofu plan   # must be clean
```

Do not run an unattended `tofu apply`: an image change replaces instances.

## Current guests

| guest | kind | role |
| --- | --- | --- |
| `caddy` | container | TLS and HTTP reverse proxy |
| `dns` | container | split-horizon DNS |
| `forgejo` | container | git forge and package registry |
| `forgejo-runner` | VM | Forgejo Actions runner |
| `fluxer` | VM | self-hosted chat |
| `paperless` | container | document management, VPN-only through Caddy |
| `syncthing` | container | replication hub |
| `minecraft` | container | Minecraft server |
| `hytale` | container | Hytale server |
| `cloudflare-ddns` | container | DNS record updater |
| `renovate` | container | dependency updates |
| `website` | VM | public website |
| `wireguard` | VM | VPN and WireGuard UI |

`forgejo` lives in its own Incus project; everything else is in `default`.

## Storage

There is one Incus pool, `persistent` (btrfs). Anything that must survive an
instance replacement is declared as a volume in that instance's `incus.nix`.
Snapshots are declared per volume, not inherited from a pool.

A volume's presence in an instance spec also makes it Tofu-owned: removing the
instance from the registry plans the volume for destruction. Read the removal
checklist in `AGENTS.md` before removing a data-bearing guest.

## Adding or removing a guest

Start with the checklists in `AGENTS.md`. The short version:

- **Add:** create `nixos/hosts/<name>/{default,incus}.nix`, add the registry
  entry and `nixosConfigurations` entry, add secrets/projects/forwards as
  needed, then `incus/gen-tf.sh` and a reviewed `tofu apply`.
- **Remove:** remove external routes and secrets first, back up data, remove the
  registry/config entries, inspect the plan, and explicitly decide whether the
  volumes are destroyed or retained.

## Emergency operation

Use `incus` for inspection and recovery, but not as a second source of truth:

```bash
incus list --all-projects -c n,p,s
incus exec <name> -- systemctl --failed --no-pager
tofu -chdir=/etc/nixos/incus/infra state list
tofu -chdir=/etc/nixos/incus/infra plan
```

If a VM reports `maintenance` from `systemctl is-system-running`, its boot
dependencies failed; check `boot.mount` before assuming the workload is broken.
