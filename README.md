# HomeLab v2

Debian 13 + Docker Compose homelab. This branch (`v2`) is the replacement for
the NixOS + Incus configuration on `main`.

The full migration plan is in [PLAN.md](PLAN.md).

## Layout

| path | purpose |
| --- | --- |
| `stacks/` | one Docker Compose stack per service |
| `scripts/` | host bootstrap, deploy, backup, restore and secret rendering |
| `systemd/` | host units and timers |
| `secrets/secrets.yaml` | sops-encrypted secrets |
| `docs/` | operational notes and runbooks |

Service data lives on bind mounts under `/srv/docker/<service>`. Backups live on
the SATA SSD under `/srv/backup`.

## Host

- Debian 13, btrfs, NVMe for OS/live data, SATA SSD for backups.
- Host SSH: `2222`.
- Forgejo Git SSH: `22`.
- LUKS root with dropbear-initramfs remote unlock on `2222` during initramfs.

## First setup

On a fresh Debian 13 host:

```bash
sudo apt-get update
sudo apt-get install -y git
sudo git clone ssh://forgejo@forgejo.sakul-flee.de/SakulFlee/HomeLab.git /opt/homelab
sudo git -C /opt/homelab checkout v2
sudo /opt/homelab/scripts/bootstrap.sh
```

Then restore data and run:

```bash
sudo /opt/homelab/scripts/render-secrets.sh
sudo /opt/homelab/scripts/deploy.sh --force
```

## Normal operation

```bash
sudo /opt/homelab/scripts/deploy.sh      # pull, validate, deploy, health-check
sudo /opt/homelab/scripts/backup.sh      # dumps + restic + repo snapshot
sudo /opt/homelab/scripts/restic-copy.sh # copy to Dendra when reachable
```

Timers run these automatically after the host has been verified.

## Secrets

Secrets are encrypted with sops/age in `secrets/secrets.yaml`. The host's age
key is derived from `/etc/ssh/ssh_host_ed25519_key` unless a dedicated age key
is configured. Keep a copy of the age key offline.

## Migration

See [PLAN.md](PLAN.md) for the full migration, cutover and restore runbook. The
short version:

1. Back up Forgejo, Fluxer, Minecraft and Hytale to Dendra.
2. Stage the new stacks on the laptop.
3. Install Debian 13 on the homelab NVMe.
4. Restore the bind-mounted data to `/srv/docker`.
5. Start the stacks, verify, then format the SATA disk as `/srv/backup`.
6. Enable deploy/backup timers.
7. Merge `v2` into `main` after a stable period.
