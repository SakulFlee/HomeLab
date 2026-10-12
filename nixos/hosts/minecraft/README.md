# Minecraft (Incus container)

A Paper server run from a jar by a systemd unit, replacing the k3s deployment in
`apps/minecraft/` (itzg's `minecraft-server` Helm chart, with `mc-router` in
front of it).

- Address: `10.0.0.115` on `incusbr0`, in the `default` Incus project.
- Game port: `25565/tcp`, forwarded on `192.168.178.200`. **No Caddy vhost** --
  see "Why a forward and not a vhost" below.
- Volumes: `minecraft-data` at `/var/lib/minecraft` (world, plugins, config) and
  `minecraft-backups` at `/var/lib/minecraft/backups` (daily archives, the only
  thing the Syncthing hub replicates). Both on `persistent`, `@daily`/`7d`
  snapshots.
- Backups: `minecraft-backup.timer`, 04:00 daily, archives the whole data
  directory.
- Minecraft version: pinned to **1.21.11** in `default.nix`. Not `LATEST` --
  see "The version pin".

> **DHCP is live on `incusbr0`.** There is no `ipv4.dhcp.ranges` in the bridge's
> config, but dnsmasq is serving addresses from inside the subnet anyway:
> `forgejo-runner` declares no `ipv4.address` and holds `10.0.0.102` because it
> was assigned one. So an instance that does not pin its address can be handed
> one that another instance already has, which shows up as ARP flapping between
> two guests rather than as an error. Every instance here pins a static address
> for that reason -- including this one (`.115`, chosen after checking the live
> instances with `incus list homelab: --format csv -c n4`, since `.100`-`.114`
> are all taken).

## The four things that are not obvious

### Why a forward and not a vhost

Everything else in this homelab reaches the internet through Caddy, which
terminates TLS and routes by hostname. Minecraft cannot be routed that way: the
Java protocol is a raw TCP stream whose handshake carries a server address and a
protocol version number and then nothing resembling a request line. There is no
hostname to match on, no path to route, and no TLS to terminate -- vanilla is
TCP 25565 in the clear.

So this instance gets an `incus network forward`, which Incus implements as an
nftables **DNAT rule rather than a socket bind**. That is what makes it safe to
add while the incumbent still holds the port: packets aimed at
`192.168.178.200` are rewritten in `PREROUTING`/`OUTPUT` before socket lookup,
while Traefik's listener on `0.0.0.0:25565` keeps the port and simply stops
being reached. See `../caddy/incus.nix` and `incus/README.md` for the full
argument.

`25565/udp` is deliberately absent -- nothing here speaks it. The three plugins
are server-side and open no client connection. (fluxer forwards `7882/udp`
because LiveKit genuinely needs it; there is no equivalent to copy.)

### The version pin

The chart set `version: LATEST`, and itzg's image resolved that at container
start -- so the old deployment tracked upstream by default. Copying that
faithfully would be wrong now: `LATEST` today is **Minecraft 26.3**, which

- requires **Java 25** (Paper's API reports `java.version.minimum: 25` for
  26.x), not the Java 21 this flake's nixpkgs ships as its default server JRE,
  and
- drags the world across a major version boundary on first boot. Paper upgrades
  a world forward and it usually works, but "usually" is not a property to apply
  to somebody's long-running build by an unattended timer.

**1.21.11** is the newest release in the 1.21 line: still Java 21, a routine
forward step for any 1.20/1.21 world, and the line the three plugin jars were
resolved against.

To change it: edit `minecraftVersion` in `default.nix`, then delete
`server.jar` and `.paper-build` from the volume and restart the service. The
fetch unit re-resolves the newest `STABLE` build for whatever version is
pinned, verifies the sha256 the API publishes for it, and records the result in
`.paper-build`.

> **Before loading the k3s data, check the world's version.** Paper will not
> downgrade. If the world turns out to be *newer* than 1.21.11, raise the pin
> first. The world announces its version in the server log on boot, and the
> `DataVersion` in `world/level.dat` is the authoritative record.

### Only the archives are replicated

The Syncthing hub mounts `minecraft-backups` read-only and mirrors it to the
peers listed in `../syncthing/default.nix` (currently Dendra) as a **sendonly**
folder. It does *not* see `minecraft-data`, so it never replicates a live world.

That is a deliberate choice, not a limitation:

- A world is thousands of files that Paper rewrites in place. Replicating it
  means re-shipping megabytes of region files on every save, and racing the
  server's own writes for them.
- An archive is one immutable file per day. Small, append-only, and
  self-consistent by construction.

This instance is the second producer in the scheme `paperless` established; the
contract is `../syncthing/NOTES.md` ("Replication standard") and the list is
`nixos/replicated-volumes.nix`. The producer's obligations, all of which
`minecraft-config.service` and `minecraft-backup.service` meet:

| obligation | where |
| --- | --- |
| data on a `persistent`-pool custom volume, `default` project | `incus.nix` |
| volume name in `replicated-volumes.nix` | `nixos/replicated-volumes.nix` |
| producer writes `.stfolder` itself (hub is read-only) | `minecraft-config.service`, plus a tmpfiles rule |
| folder is `sendonly`, no versioning | derived in `../syncthing/default.nix` |

**Pruning locally does not delete on the peer.** A sendonly folder never applies
a remote deletion, so an archive removed by the 14-day retention stays on
Dendra forever. That is the right way round for a backup.

### The backup stops the server

`minecraft-backup.service` stops `minecraft.service`, tars, and starts it again
(details and the `trap` that guarantees the restart are in `default.nix`).

Tarring a running world is the usual shortcut and it is the one that produces
backups which are subtly wrong: Paper writes region files in place, so a tar
that reads one mid-write captures a half-updated chunk, and the failure surfaces
weeks later as "that area of the map is gone". The stop costs a few seconds
once a day at 04:00 on a server that sleeps anyway. `save-off`/`save-all` would
avoid the downtime but needs a channel into the server console and has its own
failure mode -- a crash between `save-off` and `save-on` leaves the world
unflushed. The stop has no such window.

If the server is already stopped -- deliberately, or because it crashed -- the
backup runs anyway and does **not** start it.

The archive covers the whole data directory (world, plugin configs, ops,
whitelist, server properties), excluding `./backups` itself. An archive of
`world/` alone would not be restorable.

## k3s parity

| | k3s (`apps/minecraft/helm-release.yaml`) | here |
| --- | --- | --- |
| server type | Paper, `version: LATEST` | Paper, pinned `1.21.11` |
| EULA | `eula: 'TRUE'` | `eula.txt`, written by `minecraft-config` |
| difficulty | `normal` | `server.properties`, **only if absent** |
| motd | `Conduit Network @ SakulFlee` | `server.properties`, **only if absent** |
| whitelist | 7 names | `whitelist.json`, **only if absent** |
| ops | 2 names | `ops.json`, **only if absent** |
| plugins | Portalis, WorldEdit, WorldEditSUI | same three URLs, same versions |
| memory | limit 2048Mi, request 512Mi | `-Xmx2G` inside a 3GiB limit |
| port | Traefik `minecraft` entrypoint | `incus network forward` 25565/tcp |
| autoscaling | mc-router, `replicaCount: 0` | none -- always running |
| backups | none | daily archive, replicated |

**"Only if absent" is the important column.** The k3s PVC is the authority for
this server's real configuration, not the values it was created with. Six weeks
of play will have drifted from the chart -- level seed, pvp, spawn-npcs, the
world border, the operator list, whatever somebody set in-game. So a migrated
volume keeps every one of those files untouched and `minecraft-config.service`
only fills in what a brand new volume is missing. On a migrated volume it
becomes a no-op, which is the intended end state.

### mc-router is not being ported

It existed to scale the StatefulSet to zero and wake it on the first connection.
Without it the server is simply always on, which for a world nobody is connected
to costs nothing. The side effect worth knowing: **the k3s server was asleep at
`replicaCount: 0` when this was written**, so there was no live world to lose at
cutover either.

## Deploying

```bash
incus/apply.sh --check minecraft    # build the image, report drift, change nothing
incus/apply.sh minecraft            # reconcile
incus-status.service                # is it up
```

Landing the commit performs the **network cutover**: `apply.sh` applies the
forward last, after the instance is up, so the DNAT only exists once something is
listening behind it. Before that point Traefik still answers 25565.

To verify without exposing anything, reconcile with the forward temporarily
removed from `hosts/minecraft/incus.nix`, or drive the server from inside:

```bash
incus exec minecraft -- systemctl status minecraft
incus exec minecraft -- journalctl -u minecraft -f
incus exec minecraft -- ss -ltnp | grep 25565
```

**Rollback**, effective immediately, because Traefik never stopped holding the
port:

```bash
incus network forward port remove incusbr0 192.168.178.200 tcp 25565
```

The k3s manifests are deliberately still in place after this commit, so that
command is a real rollback and not just a pause.

## Loading the k3s data

The source is the PVC the StatefulSet used, on the host:

```
/var/lib/rancher/k3s/storage/backup/pvc-86e9f252-7983-4972-a93c-29ef9b6c3432_minecraft_datadir-minecraft-0
```

(the `local-path-backup` storage class, whose `nodePath` is
`/var/lib/rancher/k3s/storage/backup`).

Do this **after** the instance is verified, and with the server stopped, so
nothing writes while the copy runs:

```bash
# 1. stop the service, not the container -- the volume stays attached
incus exec minecraft -- systemctl stop minecraft minecraft-fetch minecraft-config

# 2. copy the PVC contents over the data volume, excluding our own backups
incus exec minecraft -- rsync -aHAX --delete \
  --exclude='/backups' \
  /var/lib/rancher/k3s/storage/backup/pvc-86e9f252-.../  /var/lib/minecraft/

# 3. take ownership: the PVC's files belong to the k3s image's uid, and this
#    instance's service runs as 988
incus exec minecraft -- chown -R 988:988 /var/lib/minecraft

# 4. start again
incus exec minecraft -- systemctl start minecraft
```

Notes:

- **Bind the data volume into a scratch container** rather than reaching into
  `/var/lib/rancher` from inside `minecraft`, or copy on the host. Paperless did
  this with a loader container for the same reason.
- Step 3 is why the uid is pinned in `default.nix` -- the target is a known
  number rather than whatever NixOS allocated.
- The plugin **jars** need not be copied: `minecraft-fetch.service` re-downloads
  them. The plugin **configs** under `plugins/*/` are part of the world and do
  come across.
- After the load, `minecraft-config.service` becomes a no-op and will keep
  whatever the live server had.
- Check the version pin *before* this step. Paper upgrades a world forward but
  never backwards.
- The first boot after the load is the real test: the log states the world it
  found and the version it is running.

Once this is done and verified, the k3s manifests (`apps/minecraft/`,
`clusters/homelab/apps/minecraft.yaml`) and the `minecraft` entrypoint in
`apps/traefik/helm-chart-config.yaml` can go in a separate commit, exactly as
the other migrations did.

## Backups and restic

Three independent copies, deliberately:

1. **btrfs snapshots** on both volumes, `@daily`/`7d` -- the local rollback.
2. **restic**, hourly, host-wide. `persistent` is the only pool left and it is
   what the host's restic backs up (`../homelab/services/backup.nix`), so both
   volumes are covered without excluding anything. This also covers the archives,
   which is redundant on purpose.
3. **Syncthing** to Dendra -- the off-box copy, archives only.

There is no `backup` storage pool. There used to be one, and it was merged into
`persistent`: same btrfs driver, same filesystem, no quota, and nothing had ever
enforced a difference. Retention is declared per volume, not inherited from a
pool name.

## Adding a plugin

`pluginUrls` in `default.nix` -- append the Hangar URL, reconcile, and the jar is
fetched on first boot. It is not overwritten if already present, so a version
bump means deleting the old jar from `plugins/` as well.