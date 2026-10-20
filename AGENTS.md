# Agent Notes

This repository is a NixOS homelab. On the homelab host it is checked out at
`/etc/nixos`; the flake is `nixos/`, not the repository root. The host is the
only place where `incus`, `tofu`, `gen-tf.sh` and `nixos-rebuild` are run.

## What owns what

| layer | owner |
| --- | --- |
| host OS, packages, services, users, sops declarations | NixOS under `nixos/hosts/homelab/` |
| guest OS and installed software | `nixos/hosts/<name>/default.nix` |
| Incus limits, devices, volumes, forwards, secrets, VM/container type | `nixos/hosts/<name>/incus.nix` |
| instance registry | `nixos/incus-instances.nix` |
| Incus lifecycle: images, instances, volumes, networks, profiles, projects, forwards | OpenTofu in `incus/infra/` |
| plaintext secret rendering into guests | `incus-secrets.service` on the host |

OpenTofu is the source of truth for Incus objects. Do not create, delete or
reshape instances, volumes, images, networks or forwards by hand during normal
operation. Use `incus` for inspection and incident recovery.

## Normal deploy

Run from the homelab host:

```bash
cd /etc/nixos
incus/gen-tf.sh
cd incus/infra
tofu init
tofu plan -out=deploy.tfplan
tofu apply deploy.tfplan
systemctl start incus-secrets.service
tofu plan   # must be clean
```

`incus/gen-tf.sh` builds every image and writes `incus/infra/generated.tf.json`.
That file, the `.artifacts/` out-links, `.terraform/`, plans and state are
local-only and must not be committed. The generated out-links are GC roots;
do not delete them while a plan is pending.

The host's automatic updater may rebuild the host, regenerate the Tofu JSON,
and apply a plan when the plan is safe. A plan that deletes an instance with no
replacement, a storage volume, project, network, forward, pool or server is
blocked and left for manual review. Do not bypass that guard by applying such a
plan automatically.

## Adding a deployment

1. Create `nixos/hosts/<name>/default.nix` for the guest OS. Follow the split
   used by the existing hosts: guest configuration belongs here.
2. Create `nixos/hosts/<name>/incus.nix` for the Incus-level data: limits,
   volumes, devices, forwards, rendered secrets and `type = "vm"` when needed.
3. Add the instance to `nixos/incus-instances.nix`.
4. Add a matching `nixosConfigurations.<name>` entry in `nixos/flake.nix`.
   Use `kind = "vm"` for a VM; containers omit it.
5. If the instance is not in Incus's `default` project, add it to
   `nixos/incus-instance-projects.nix` and declare the project in
   `nixos/incus-projects.nix`.
6. If it owns data that another instance replicates, add that volume to
   `nixos/replicated-volumes.nix`.
7. If it needs host-rendered secrets:
   - declare the source under `sops.secrets` in `nixos/modules/sops.nix`;
   - add the encrypted value to `nixos/secrets.yaml`;
   - add the destination to `renderedSecrets` in the instance's `incus.nix`;
   - add the consuming unit to `secretConsumers`.
8. Add external exposure deliberately:
   - HTTP: a Caddy site block in `nixos/hosts/caddy/default.nix`;
   - DNS: the split-horizon records for VPN-gated names;
   - raw TCP/UDP: `networkForward`/`networkForwards` in the instance spec.
9. Update the host's documentation.
10. On the host, run `incus/gen-tf.sh`, review `tofu plan`, apply the saved
    plan, start `incus-secrets.service`, and verify the service from inside the
    guest and through its public route.

## Removing a deployment

Removing an entry from `nixos/incus-instances.nix` removes the generated
`incus_instance` **and its `incus_storage_volume` resources**. That is a real
destroy, not a detach.

1. Remove external exposure first: Caddy site block, DNS record, network
   forward, and any secrets declarations.
2. Back up or snapshot every volume that matters and verify the backup.
3. Remove the instance from `nixos/incus-instances.nix`.
4. Remove its `nixosConfigurations` entry and, if no longer used, its
   `nixos/hosts/<name>/` directory.
5. Remove its project entry if it was the last instance in that project.
6. Remove replicated-volume entries, sops declarations and documentation.
7. Run `incus/gen-tf.sh` and inspect `tofu plan` before applying.
   - To destroy the volumes with the instance, apply normally.
   - To retain the data, run `tofu state rm incus_storage_volume.<name>` for
     each volume that must survive, then apply. Manage or delete those volumes
     manually afterwards; they are no longer owned by Tofu.
8. Apply, verify the remaining plan is clean, and delete unreferenced images
   and aliases deliberately.

## Secrets

- The host decrypts sops values into `/run/secrets`; `incus-secrets.service`
  copies rendered values into the guests.
- Tofu state must never contain plaintext secrets.
- A guest gets only the values it declares. It never gets the host's SSH
  identity key or a general decryption capability.
- `incus-secrets` is the only routine imperative component. Changes to it must
  be tested against a real instance, not just by reading the script.

## Importing existing resources

`incus/import.sh` is the one-time adoption/disaster-recovery tool. It reads
`generated.tf.json` and imports live objects. It is not part of a normal deploy.
`incus_image` and `incus_server` cannot be imported. The provider's import IDs
have a project quirk: default-project volumes use a leading slash
(`/persistent/<name>`), project volumes use `<project>/persistent/<name>`, and
forwards use `/<network>/<address>`.

## Verification

```bash
incus list --all-projects -c n,p,s
incus config show <name>
incus exec <name> -- systemctl --failed --no-pager
incus exec <name> -- ss -ltnp
tofu -chdir=incus/infra plan
```

For a VM, check that systemd reached multi-user, not just that the Incus
instance is "RUNNING":

```bash
incus exec <name> -- systemctl is-system-running
```

`maintenance` means a boot dependency failed and the workload services never
started.

## Known sharp edges

- **`incus-secrets` must not read its loop's stdin.** Guest reads and direct
  `incus` calls need `</dev/null`; the instance list is held in an array. A
  `while read ... < <(jq ...)` loop can be drained by an `incus exec` and skip
  every instance after the first.
- **VM `/boot` is not needed at runtime.** The ESP is mounted by label and can
  appear late under load; the VM image sets `nofail` and a bounded device
  timeout so a late ESP does not push the whole guest into maintenance.
- **Instance replacement is expected on an image change.** Data that must
  survive belongs on an Incus storage volume, never on the root disk.
- **Forgejo's SSH host keys live on `forgejo-data`.** They are deliberately at
  `/var/lib/forgejo/data/ssh`, not the container root's `/etc/ssh`: the root disk
  is replaced on every image change, and rekeying there breaks every Git
  client's `known_hosts` entry. If moving or restoring Forgejo, preserve that
  directory.
- **Old images may remain after replacement.** Delete them only when
  unreferenced; `incus-image-gc.sh` only handles images carrying
  `user.build-source`, so it does not cover every Tofu-created image.
- **`create_before_destroy` can surface "Image is in use by an instance".**
  Rerun the apply after the old instance is gone.
- **Do not edit `generated.tf.json`.** It is regenerated from the flake.

## More documentation

- `nixos/README.md` — host onboarding and NixOS layout.
- `incus/README.md` — image build, secrets, networking and provider details.
- `nixos/hosts/<name>/README.md` — service-specific notes where present.
