# Syncthing (Incus instance)

The homelab's replication hub. One always-on node that holds a peer's personal
files and is meant to expose other instances' data volumes read-only so they get
an off-box copy. It replaced the k3s HelmRelease that used to live in
`apps/syncthing/`.

- Address: `10.0.0.104` on `incusbr0`, in the `default` Incus project.
- GUI: `https://syncthing.sakul-flee.de` only, VPN-gated by Caddy. No GUI
  password: the VPN gate is the authentication, and there is no host-level
  forward for 8384.
- Sync port: `22000/tcp` and `22000/udp`, forwarded on `192.168.178.200`. This is
  *not* VPN-gated -- a peer needs it to transfer, and VPN clients route
  `192.168.178.0/24` but not `10.0.0.0/24`, which is why the forward exists.
- Volumes: `syncthing-config` at `/var/lib/syncthing` (config, TLS identity,
  index) and `syncthing-data` at `/data` (the synced files). Both on
  `persistent`, `@daily`/`7d` snapshots.

## Edit the Nix, not the WebUI

`overrideDevices` and `overrideFolders` are both `true`. `syncthing-init` POSTs
the declared set on every boot and DELETEs anything else, so a device or folder
added in the WebUI works until the next restart and then vanishes. The WebUI is
a status and diagnostics view; changes are a commit to
`nixos/hosts/syncthing/default.nix`.

This is safe for peers because adding one is never interactive on the server:
you paste the peer's ID, you do not accept anything on the server side. The one
thing the server cannot do without a human is *receive* a folder it did not
originate -- see the rule below.

### Adding a peer

1. On the peer: Actions -> Show ID (or `syncthing --device-id`).
2. Add it under `settings.devices.<name>` with that `id`.
3. Add `<name>` to the relevant folder's `devices` list.
4. `incus/apply.sh syncthing`; on the peer, accept the folder.

A wrong or malformed ID does not error -- it simply never connects.

### Folders the server originates vs. receives

The rule: **folders the server originates live in Nix; folders it receives live
in the WebUI.** A folder the server generates (this instance's own data, and the
replicated volumes below) is declared in Nix and enforced. A folder a phone or
laptop originates is accepted on the server and would be deleted at the next
boot if `overrideFolders` were enforcing only the declared set; in practice the
module POSTs declared folders rather than PUTting the whole list, so received
folders survive, but treat that as an implementation detail and keep the rule.

## The identity volume is load-bearing

The server's device ID is the certificate in `syncthing-config`. Losing that
volume changes the ID and breaks every peer until each is re-paired. The
snapshot on that volume is the rollback; without it, restoring from anywhere
else re-keys the server.

## Inotify

`fsWatcherEnabled` watches a folder through inotify. Containers share the host
kernel, so the budget is set once on the host in
`nixos/hosts/homelab/kernel.nix` (`fs.inotify.max_user_watches`). If it is
exceeded, Syncthing logs a failure and silently falls back to periodic rescans
rather than erroring.

## Replication standard (for producers: Paperless and later)

This is the contract another instance follows to have its data replicated by
this hub. The generator that consumes it is not wired yet -- it lands with the
first producer, so that nothing dead ships before there is something to
replicate. Until then, a producer's volume can be attached by hand.

1. **Store the data in a named Incus custom volume on the `persistent` pool.**
   Not a bind mount, not a path on the instance's root disk. The volume is what
   gets attached; a path inside the root disk cannot be.

2. **Live in the `default` Incus project.** Custom volumes are project-scoped
   and invisible across projects, so a volume in another project cannot be
   attached to this instance no matter what. (Forgejo currently lives in its own
   `forgejo` project, so its data is *not* replicable under this standard
   without moving it.)

3. **Add the volume name to `nixos/replicated-volumes.nix`** (to be created)
   once the generator exists. That single list is the source of truth: it should
   drive both the read-only disk device on this instance and the folder
   declaration below, so the two cannot drift.

4. **This instance mounts it read-only** at `/mnt/replicated/<volume-name>` (or
   wherever the generator puts it), and declares a folder over it with
   `type = "sendonly"`: the server is the source, never a writer. Read-only is
   the point -- the hub must not be able to modify the producer's data.

5. **The producer creates the folder marker.** Syncthing needs
   `<folder>/.stfolder` to exist, and it cannot create it on a read-only mount.
   So the producer writes an empty `.stfolder` directory at the root of the
   volume, in its own (read-write) container. If the marker is missing,
   Syncthing marks the folder stopped and never scans it.

6. **No versioning on these folders.** Trashcan and the other versioning
   handlers act on files the *local* device deletes or replaces; a sendonly
   server folder never does either, so versioning there would do nothing. This
   is also why they must be sendonly rather than sendreceive: the hub has no
   business deleting a producer's data.

## Backup posture

Syncthing data is not what restic is meant to protect; the peer is the off-box
copy and the snapshots are the rollback. Restic's pool-wide walk of
`/var/lib/incus/storage-pools/persistent` does capture these volumes, because
they are on `persistent` like everything else -- nothing excludes them. The old
k3s Syncthing replicated the restic repository itself off-box; the Incus one
deliberately does not mount `/var/lib/backups`, so that off-box replication is
gone. See `nixos/hosts/homelab/services/backup.nix`.
