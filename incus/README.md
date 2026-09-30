# incus/

Tooling for building NixOS container images and turning them into running
Incus instances. Everything here is meant to be run on the homelab host, where
`/etc/nixos` is a clone of this repository.

## Layout

| path                       | what it is                                                  |
| -------------------------- | ----------------------------------------------------------- |
| `apply.sh`                 | the reconciler: build image, import, create/recreate         |
| `nixos/incus-instances.nix`| the registry — the only list of instance names               |
| `nixos/hosts/<n>/default.nix` | the OS config, built into the image                      |
| `nixos/hosts/<n>/incus.nix`   | the container config: limits, volumes, devices            |

An instance is defined in two files, deliberately split:

* **`default.nix`** is a NixOS module. Anything the guest can configure lives
  here, because it is what gets built into the image.
* **`incus.nix`** is plain data. Limits, storage volumes and devices are facts
  only Incus knows, so they cannot live in the image.

`nixos/incus-instances.nix` imports the `incus.nix` of every instance and is the
single source of the names. It is read twice — once by the flake, which exposes
it as `incusInstances`, and once by the host config, which generates the systemd
units. There is no second list to keep in sync.

## The model

Instances are **immutable images plus disposable root disks**, in the same
relationship a NixOS system has to its store path.

```
nixos/hosts/<name>/default.nix
        │
        ▼
   nix build …config.system.build.squashfs ──┐
   nix build …config.system.build.metadata ──┤
                                             ▼
                                   incus image import ──► homelab/<name>
                                                                     │
                                       ┌─────────────────────────────┘
                                       ▼
                        volatile.base_image  ==  fingerprint?  ──yes──► no-op
                                       │                          no
                                       no
                                       ▼
                              delete + recreate
```

Recreating replaces the root disk and nothing else. **Anything that must survive
a recreate lives on a storage volume**, declared in `incus.nix`. This is why
Caddy's ACME certificates are on the restic'd `backup` pool and Forgejo's
PGDATA is on the not-restic'd `persistent` one.

Recreate is not free — the instance is briefly unavailable while its root disk
is replaced. It only happens when the image actually changes, which is the
point: the fingerprint comparison is the exact test, so a dirty git tree that
rebuilds to identical bytes costs nothing.

## Running it

```bash
incus/apply.sh --all             # reconcile every instance
incus/apply.sh caddy             # just one
incus/apply.sh --check caddy     # build, report drift, change nothing
incus/apply.sh --no-start caddy  # reconcile but leave it stopped
systemctl start incus-apply-caddy.service
journalctl -u incus-apply-caddy -f
incus-status.service             # one-line-per-instance table
```

All of it needs root: `incus image import` and instance changes go through the
Incus daemon, and the Nix store is only writable by the daemon's group.

`incus-status.service` is the quickest way to see whether the automatic
redeploy actually did anything:

```
INSTANCE   STATE      BASE-IMAGE    ALIAS
caddy      Running    3f2a1b0c9d4e  homelab/caddy
forgejo    -          -             homelab/forgejo
```

## Automatic redeploy

The host runs one `incus-apply-<name>.service` and one `.path` unit per
instance. Any change under `nixos/` — a hand edit, or the hourly
`git merge --ff-only` in `nixos-auto-update` — triggers a rebuild. It is safe to
run on every change because the work is gated on the fingerprint comparison
above, and a no-op rebuild finds everything already built and returns.

Two things worth knowing:

* **Every instance watches the whole tree, not just its own directory.** An
  unnecessary rebuild costs a `nix build` that returns immediately; missing a
  shared-module change costs a stale image nobody notices. Revisit when the
  instance count makes the hourly sweep expensive.
* **The watch list is generated at host build time.** A file added after the
  last `nixos-rebuild` is not watched yet, though its parent directory is, so
  its creation is still noticed. Adding an instance means editing the registry,
  which is itself a rebuild, so this closes on its own.

## Storage pools

Three pools, split by backup policy rather than convenience:

| pool         | driver | restic'd | what goes here                              |
| ------------ | ------ | -------- | ------------------------------------------- |
| `backup`     | btrfs  | yes      | anything whose loss you would actually miss  |
| `persistent` | btrfs  | **no**   | live Postgres PGDATA, and instance root disks |
| `ephemeral`  | dir    | no       | VMs — added in the phase that provisions them |

`persistent` exists so that "never file-back-up a live Postgres data
directory" is structural rather than a convention anyone has to remember. A
torn PGDATA copy is worse than no copy. The authoritative artefact is always a
`pg_dump` landing in `backup`.
