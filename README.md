# HomeLab

Debian 13 + Docker Compose homelab. `main` is the current deployment.

This repository used to describe a NixOS + Incus host. Those trees were removed;
`git log -- nixos incus` still has them if the history is ever needed.

## Layout

| path | purpose |
| --- | --- |
| `stacks/` | one Docker Compose stack per service |
| `scripts/` | bootstrap, deploy, backup, restore and secret rendering |
| `systemd/` | host units and timers |
| `secrets/secrets.yaml` | sops/age encrypted secrets |
| `docs/` | operational notes and runbooks |

Service data lives on bind mounts under `/srv/docker/<service>`. The restic
repository lives on the SATA SSD under `/srv/backup`. The repository is checked
out at `/opt/homelab` on the host; `deploy.sh` runs as root from there.

## Host

- Debian 13, btrfs root inside LUKS, unencrypted `/boot`.
- NVMe: OS and live data (`/srv/docker`). SATA: LUKS + btrfs, `/srv/backup`.
- Host SSH `2222`. Initramfs dropbear `2223` (unlocks the root disk). Forgejo
  Git SSH `22`.
- Public services behind Caddy (`80`/`443`, Let's Encrypt via DNS-01).
- WireGuard through wg-easy: `51820/udp`, UI on `51821`, tunnel `100.64.0.0/24`
  plus `fd42:1::/64`.
- Split-horizon DNS on `192.168.178.200` (CoreDNS) for the admin names.
- IoT Wi-Fi AP on `wlp2s0`: 2.4 GHz only, isolated `192.168.179.0/24`, internet
  access only. See [docs/iot-wifi.md](docs/iot-wifi.md).

### Services

| stack | reachable at |
| --- | --- |
| Forgejo | `forgejo.sakul-flee.de`, SSH `forgejo@…:22` |
| Fluxer | `fluxer.sakul-flee.de` |
| Website | `sakul-flee.de` |
| Minecraft | `minecraft.sakul-flee.de:25565` |
| Hytale | `hytale.sakul-flee.de:5520/udp` |
| Admin (LAN/VPN only) | `dockge.`, `vpn.`, `syncthing.`, `opencode.` |
| ntfy (self-hosted relay) | `ntfy.sakul-flee.de`, authenticated |

## First setup

On a fresh Debian 13 host:

```bash
sudo apt-get update && sudo apt-get install -y git
sudo git clone ssh://forgejo@forgejo.sakul-flee.de/SakulFlee/HomeLab.git /opt/homelab
sudo /opt/homelab/scripts/bootstrap.sh
```

Place the sops age identity at `/etc/sops/age/keys.txt`, then:

```bash
sudo /opt/homelab/scripts/render-secrets.sh
sudo /opt/homelab/scripts/deploy.sh --force
```

## Normal operation

```bash
sudo /opt/homelab/scripts/deploy.sh     # pull, validate, deploy, health-check
sudo /opt/homelab/scripts/backup.sh     # dumps + restic + repo snapshot
```

`deploy.sh` is also driven by `homelab-deploy.timer` every 30 minutes. Push to
`main` instead of rsyncing files: when the checkout is ahead of the remote, the
timer treats that as a deploy and re-applies every stack on each run.

The off-box copy is pulled *from* Dendra, not pushed by the homelab. See
[docs/operations.md](docs/operations.md).

## Secrets

Everything is encrypted with sops/age in `secrets/secrets.yaml`. The host keeps
its identity at `/etc/sops/age/keys.txt`; `scripts/sops.sh` is a wrapper that
uses it. Store the age key and the restic repository passwords offline.

**The Forgejo `SECRET_KEY` must never be regenerated on an existing database.**
It decrypts 2FA secrets and other encrypted rows; rotating it silently breaks
every account that has 2FA enabled.

## Documentation

- [docs/operations.md](docs/operations.md) — deployment, backups, alerting,
  VPN/DNS, and the known sharp edges. Start here.
- [docs/iot-wifi.md](docs/iot-wifi.md) — the isolated 2.4 GHz IoT SSID.
- [docs/ssh.md](docs/ssh.md) — host SSH, Forgejo SSH and initramfs unlock.
- [docs/secrets.md](docs/secrets.md) — sops layout and how to read a value.
- [docs/restore.md](docs/restore.md) — restoring and inspecting backups.
- [docs/staging.md](docs/staging.md) — running the stacks off-production.
