# HomeLab

Ansible + OpenTofu + NixOS: migrating from Debian LXC containers to NixOS.

## Architecture

```
HomeLab/
├── flake.nix        Dev shell (tofu + ansible via `nix develop` / direnv)
├── .envrc           Auto-loads dev shell
│
├── tofu/            OpenTofu — provisions LXC containers on Proxmox
│   ├── main.tf      LXC container resource + nixos-anywhere provisioner
│   ├── provider.tf  bpg/proxmox provider
│   ├── variables.tf Endpoint, token, SSH keys
│   └── outputs.tf   Container IP, CT ID
│
├── nixos/           NixOS — service configurations for each container
│   ├── flake.nix    nixpkgs 26.05, exports nixosConfigurations.*
│   ├── modules/     Shared NixOS modules (proxmox-lxc, auto-update, ...)
│   └── hosts/
│       └── caddy/   Example: Caddy reverse proxy (CT 100, 10.0.0.100)
│
└── ansible/         Existing Ansible configs for Debian containers (legacy)
    ├── inventory.ini
    ├── playbook.yml
    └── roles/
```

### Workflow

1. **OpenTofu** creates a bootstrapping Debian LXC on Proxmox via API
2. **nixos-anywhere** installs NixOS over SSH (official remote install tool)
3. Container reboots into **pure NixOS** with the flake's configuration
4. A **systemd timer** polls this repo every hour — if a change is detected,
   `git pull && nixos-rebuild switch` runs automatically

## Prerequisites

### 1. OpenTofu

```bash
# From the dev shell (direnv or nix develop)
tofu version

# Or install globally
nix profile install nixpkgs#opentofu
```

### 2. Proxmox API Token

Create a token in the Proxmox UI:
- **Datacenter → Permissions → API Tokens**
- User: `root@pam` (or a dedicated user)
- Token ID: `tofu`
- Copy the secret (shown once)

### 3. SSH Deploy Key

Generate a key pair that OpenTofu uses to connect through the bastion:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/tofu-deploy -N ""
ssh-add ~/.ssh/tofu-deploy
```

Also add it to the Proxmox host so the provisioner can connect via the bastion:

```bash
ssh-copy-id -p 2222 -i ~/.ssh/tofu-deploy root@192.168.178.200
```

### 4. SSH Config for Bastion

Add this to `~/.ssh/config` so OpenTofu finds containers through
the jump host automatically:

```
Host 10.0.0.*
  ProxyCommand ssh -p 2222 root@192.168.178.200 -W %h:%p
  IdentityFile ~/.ssh/tofu-deploy
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
```

### 5. NixOS Container Template (One-Time)

A pre-configured NixOS template CT must exist in Proxmox for cloning.
Create it manually once:

```bash
# On the Proxmox host:
pct create 9999 local:vztmpl/nixos-image-lxc-proxmox-26.05pre-git-x86_64-linux.tar.xz \
  --hostname nixos-base --ostype nixos --unprivileged 1 \
  --net0 name=eth0,bridge=aether,ip=dhcp \
  --storage local-lvm

pct start 9999
pct enter 9999
#  source /etc/set-environment
#  Write /etc/nixos/configuration.nix with:
#    - proxmox-lxc module (manageNetwork=false, privileged=false)
#    - SSH enabled + your public key
#    - nix.settings.sandbox = false
#    - system.stateVersion = "26.05"
#  nixos-rebuild switch
#  exit
pct stop 9999
pct template 9999
```

## Deploying the First NixOS Container (CT 100 — Caddy)

```bash
# Enter dev environment
direnv allow   # or: nix develop

# Initialize OpenTofu
cd tofu && tofu init

# Review what will be created
tofu plan \
  -var="proxmox_token_id=root@pam!tofu" \
  -var="proxmox_token_secret=<your-secret>" \
  -var="ssh_private_key_path=~/.ssh/tofu-deploy"

# Apply — clones template + deploys flake
tofu apply \
  -var="proxmox_token_id=root@pam!tofu" \
  -var="proxmox_token_secret=<your-secret>" \
  -var="ssh_private_key_path=~/.ssh/tofu-deploy"

# Verify
ssh -i ~/.ssh/tofu-deploy root@10.0.0.100
curl http://10.0.0.100
# → "Hello from NixOS on CT 100!"
```

### First Apply: What Happens

| Step | Duration | What |
|------|----------|------|
| Clone template CT 9999 → CT 100 | ~5s | Pre-configured NixOS LXC with SSH key ready |
| Wait for SSH | ~5s | Container boots, SSH available |
| `git clone` repo → /etc/nixos | ~3s | Clones the whole HomeLab repo |
| nixos-rebuild switch | 1-3 min | Applies Caddy config, auto-update timer |
| Caddy + auto-updater | ~5s | Services start automatically |

## Auto-Update Mechanism

Every NixOS container runs a systemd timer (`nixos-auto-update`) that:

1. `git pull origin main` in `/etc/nixos` every hour
2. `nixos-rebuild switch --flake /etc/nixos/nixos#<host>`
3. Logs to journald — check with `journalctl -u nixos-auto-update`

The timer runs as root in a `timers.target` context (no desktop dependency).

## Adding a New Container

1. Create a host directory under `nixos/hosts/<name>/`:
   ```
   nixos/hosts/<name>/
   ├── default.nix   → hostname, stateVersion, imports (service + shared modules)
   └── <service>.nix → service config (e.g. nginx.nix)
   ```

2. Register it in `nixos/flake.nix`:
   ```nix
   nixosConfigurations.<name> = nixpkgs.lib.nixosSystem {
     system = "x86_64-linux";
     modules = [ ./hosts/<name> ];
   };
   ```

3. Add a container resource in `tofu/main.tf` (or use a module).

4. Push to `main` → CI runs `tofu plan` → manually apply.

## CI/CD

| Pipeline | Trigger | Action |
|----------|---------|--------|
| `tofu-plan` | Any PR / push to main | `tofu plan` (read-only, shows what would change) |
| `tofu-apply` | Push to main | `tofu apply` with secrets from Woodpecker |
| `ansible-deploy` | Push to main | `ansible-playbook` for existing Debian containers |

## Legacy Ansible

The `ansible/` directory contains the original Ansible configuration for the
12 Debian LXC containers. These remain unchanged and will be migrated to
NixOS incrementally.

To run Ansible manually:

```bash
cd ansible
ansible-playbook -i inventory.ini playbook.yml --vault-password-file .vault_pass
```

## Development

```bash
# Enter the dev environment (tofu + ansible in PATH)
direnv allow   # automatic on cd
# or
nix develop    # one-shot shell

# Check NixOS config syntax
nix flake check nixos#caddy

# Build the caddy config (without deploying)
nix build nixos#nixosConfigurations.caddy.config.system.build.toplevel
```
