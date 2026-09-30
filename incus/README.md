# incus/

Tooling for building NixOS container images and turning them into running
Incus instances. Everything here is meant to be run on the homelab host, where
`/etc/nixos` is a clone of this repository.

## Layout

| path                          | what it is                                                      |
| ----------------------------- | --------------------------------------------------------------- |
| `incus/apply.sh`              | the reconciler: build image, import, create/recreate             |
| `nixos/incus-instances.nix`   | the registry — the only list of instance names                   |
| `nixos/hosts/<n>/default.nix` | the OS config, built into the image                              |
| `nixos/hosts/<n>/incus.nix`   | the container config: limits, volumes, devices                  |

**On the host**, this directory is `/etc/nixos/incus/`, so the reconciler lives
at **`/etc/nixos/incus/apply.sh`**. It runs straight from the checkout rather
than from a store path, which is what lets the `.path` unit watch it: a store
path is immutable, so a unit watching one could never fire.

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

**Run state is declarative.** An instance ends up running or stopped according to
`autostart` in its `incus.nix`, and nothing else. There is deliberately no
"preserve whatever it was doing" rule: that needs to tell a deliberate stop from
a create that died before its first start, and there is no reliable signal for
the difference — `volatile.last_state.power` records `STOPPED` after a stop, not
`RUNNING`. One rule beats a heuristic that silently reports success while being
wrong. To keep an instance down across a redeploy, set `autostart = false`,
which is itself a change, so applying it terminates rather than looping.

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
instance. Any change to that instance's inputs — a hand edit, or the hourly
`git merge --ff-only` in `nixos-auto-update` — triggers a rebuild. It is safe to
run on every change because the work is gated on the fingerprint comparison
above, and a no-op rebuild finds everything already built and returns.

**What each instance watches** is the closure of what its own build reads:

| watched                                 | why                                |
| --------------------------------------- | ---------------------------------- |
| `nixos/flake.{nix,lock}`                | inputs, and the `mkInstance` wrapper |
| `nixos/incus-instances.nix`              | the registry, which selects the spec |
| `nixos/hosts/<name>/`                   | that instance's `default.nix` and `incus.nix` |
| `nixos/modules/`                        | shared modules — unused today, but where the first one will land |
| `incus/apply.sh`                        | the reconciler itself              |

Deliberately **not** watched: `nixos/hosts/homelab/`, `nixos/hardware/`,
`nixos/users/`. Those are the *host*, and the host does not appear in any
instance's build closure — rebuilding every image because the host's NIC changed
would be pure waste.

Two things worth knowing:

* **The watch list is generated at host build time.** A *new* file added after
  the last `nixos-rebuild` is not watched yet. Its parent directory is, so its
  creation is still noticed, and the next rebuild closes the gap. Adding an
  instance means editing the registry, which is itself a rebuild.
* **Never delete an image.** A new import repoints the alias and leaves the
  previous image unreferenced for Incus's own GC. There is no `--reuse` here
  precisely because it deletes an image that already carries the alias.
* **`incus image import` is not idempotent.** Given content the pool already
  holds it fails with `Image with same fingerprint already exists`, *and it does
  not attach the alias on that path*. So the alias can go on naming a stale
  image while the fingerprint comparison reads it and declares a wrong instance
  up to date. Every no-op redeploy therefore takes a fast path that never
  imports at all, and the run ends with an assertion that the alias really does
  name the image just built — the failure mode here is silent, so it gets a
  guard rather than a comment.
* **`user.build-source` is a trusted record.** It is the only handle that maps a
  build output to a fingerprint, so it is written in exactly one place: after
  the alias provably names the right image. Writing it before resolving the
  alias is how an image ends up carrying someone else's build path, and once it
  has, the record lies and every later comparison inherits the lie.
* **A `.path` unit does not fire on activation.** Per `systemd.path(5)`, only
  `PathExists=` triggers immediately when the condition already holds. So the
  first deploy after installing these units is an explicit
  `systemctl start incus-apply-<name>.service`; everything after that is
  automatic.

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
