# NixOS Configuration

This repository is the HomeLab flake. The bare-metal host is
`nixosConfigurations.HomeLab`; every other `nixosConfigurations.<name>` is a
guest image built for Incus. The flake root is this directory, not the
repository root.

## Hosts and Incus guests

There are two different kinds of "host" here:

- **The bare-metal host** is `nixos/hosts/homelab/`. It is rebuilt with
  `nixos-rebuild`.
- **An Incus guest** is `nixos/hosts/<name>/`. Its `default.nix` is the OS
  inside the image; its `incus.nix` describes the container or VM that Tofu
  creates. Adding a guest is not done with `incus` by hand, and it is not a
  `nixos-rebuild` of the bare-metal host.

The registry is `nixos/incus-instances.nix`. OpenTofu consumes the generated
JSON from `incus/gen-tf.sh`. See `AGENTS.md` for the complete add/remove
deployment checklists and `incus/README.md` for the image pipeline.

On the homelab host:

```bash
cd /etc/nixos
incus/gen-tf.sh
cd incus/infra
tofu plan -out=deploy.tfplan
tofu apply deploy.tfplan
systemctl start incus-secrets.service
tofu plan
```

Do not run `tofu apply` unattended; an image change replaces running guests.

## Adding a new device
To add a new device, first boot from and install via the official NixOS ISO.
Run through the whole setup, create your user, parition the disks, etc.

### Enrollment
Since we use SOPS secrets in this repository, you will have to "enroll" your new installation first.
You need to activate the SSH server first at least once in the NixOS config, then rebuild and switch for it to generate the host keys!

On your new installation, run the following:

```bash
nix-shell -I nixpkgs=channel:nixos-unstable -p ssh-to-age --run 'ssh-to-age -i /etc/ssh/ssh_host_ed25519_key.pub'
```

The generated aged string needs to be placed into the `.sops.yaml` file.
Next, you will need to move to a **known** machine (or gain access to their secret key) and run:

```bash
nix-shell -I nixpkgs=channel:nixos-unstable -p sops --run 'SOPS_AGE_KEY=$(sudo ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key) sops updatekeys secrets.yaml'
```

> [!INFO]
> This repository should include sops and ssh-to-age ... you may have it installed already, thus no need for the nix-shell!
> To edit or update keys directly (without nix-shell):
> ```bash
> SOPS_AGE_KEY=$(sudo ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key) sops edit secrets.yaml
> ```

Finally, commit and push the updated `secrets.yaml` **and** `.sops.yaml`.

### User SSH Key (Home-Manager SOPS)
Home-Manager also needs access to SOPS secrets (like the GPG private key).
Generate a user SSH key and enroll it:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
```

Derive its AGE key and add it to `.sops.yaml` as `<Name> (User)`:

```bash
nix-shell -p ssh-to-age --run 'ssh-to-age -i ~/.ssh/id_ed25519.pub'
```

After adding both the host and user AGE keys to `.sops.yaml`, re-encrypt secrets from a **known** machine:

```bash
nix-shell -p sops --run 'SOPS_AGE_KEY=$(sudo ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key) sops updatekeys secrets.yaml'
```

### Backup
Next, make a backup of the generated configuration:
```bash
cp -r /etc/nixos /etc/nixos_bak
```

### Checkout
Clean the generated configuration and initialize this repository:
```bash
rm -f /etc/nixos/*
cd /etc/nixos
git init
git remote add origin https://forgejo.sakul-flee.de/SakulFlee/HomeLab.git
```

### Adjustments
A new machine _most likely_ also requires an entry under `./hosts/` (also update `flake.nix`!).
You need to **at least** copy the hardware configuration from your backup (/etc/nixos_bak/hardware.nix) into the configuration.
However, most host configs are sharded, you may only need boot-loader flags and **definitely the parititon layout**!
Check an example config for guidance.

### Build & Apply
Finally, build and apply your configuration via:

```bash
sudo nixos-rebuild switch --flake /etc/nixos/nixos#<your-chosen-hostname>
```

> [!NOTE]
> The hostname is optional on subsequent runs — `nixos-rebuild switch` defaults to the current hostname.
> After first setup, run `sudo chown -R root:root /etc/nixos` to avoid git's "dubious ownership" check.
> Also, a service will be installed that regularly checks for updates in this repository.

> [!INFO]
> You may want to enroll your new SSH keys (`ssh-keygen`) to Forgejo and switch to SSH+GIT instead of HTTPS:  
> `git remote set-url origin forgejo@forgejo.sakul-flee.de/SakulFlee/HomeLab.git`

> [!WARNING]
> You will also need to run a FULL Rclone sync:
> `RCLONE_CONFIG_NAS_SMB_TYPE="smb" RCLONE_CONFIG_NAS_SMB_HOST="192.168.178.250" RCLONE_CONFIG_NAS_SMB_HOST="IP" RCLONE_CONFIG_NAS_SMB_USER="USER" RCLONE_CONFIG_NAS_SMB_PASS=$(rclone obscure "PASSWORD") rclone bisync /home/sakulflee/Sync NAS_SMB:personal_folder/ --workdir /home/sakulflee/.local/state/rclone/bisync --resync --exclude '/#recycle/**' --exclude '/.Trash-1000/**' --conflict-resolve newer --verbose --links --resilient`

