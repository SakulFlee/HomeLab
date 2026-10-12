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
- Minecraft version: pinned to **26.3** in `default.nix`, on `openjdk25`. Not a
  preference -- it is the floor the world requires. See "The version pin".

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

### The version pin is the floor the world requires

This is not a preference and it was originally wrong. The first version of this
file pinned **1.21.11**, reasoning that the roster and plugin jars were
"1.21-line" and that copying the chart's `version: LATEST` would be
unreasonable.

The k3s deployment had been resolving `LATEST` forward for six weeks and was
running **26.x**, and the world says so in a way that is not arguable:

```
world/level.dat                                   DataVersion 279649
world/region/                                     0 files
world/dimensions/minecraft/overworld/region/      2034 entries
```

The nested per-dimension layout is the 26.x world format, and the PVC's `cache/`
held `mojang_26.1.2.jar` and `mojang_26.2.jar`. So 1.21.11 could not have
loaded this world: Paper upgrades a world forward and refuses backward, and the
empty 1.21.11 world that booted instead was Paper declining, not succeeding.

Hence **26.3**, the newest 26.x, which accepts a 26.x world and converts it.

**Java 25 is part of this decision.** 26.x requires it -- Paper's API reports
`java.version.minimum: 25` for the line -- so the unit runs `pkgs.openjdk25`
rather than the nixpkgs default of 21. The JVM flags are also taken from that
same API response (`java.flags.recommended`) rather than carried over from
1.21-line advice.

To change the pin: edit `minecraftVersion`, then delete `server.jar` and
`.paper-build` from the volume and restart. The fetch unit re-resolves the
newest `STABLE` build for whatever is pinned, verifies the sha256 the API
publishes, and records the result in `.paper-build`.

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
| server type | Paper, `version: LATEST` (resolving to 26.x) | Paper, pinned `26.3` |
| plugins | Portalis, WorldEdit, WorldEditSUI | same three URLs, **1.21-line builds** |
| EULA | `eula: 'TRUE'` | `eula.txt`, written by `minecraft-config` |
| difficulty | `normal` | `server.properties`, **only if absent** |
| motd | `Conduit Network @ SakulFlee` | `server.properties`, **only if absent** |
| whitelist | 7 names | `whitelist.json` as name+**dashed** UUID, repaired if absent or empty |
| ops | 2 names | `ops.json` as name+UUID+level, repaired if absent or empty |
| plugins | Portalis 1.0, WorldEdit 7.3.17, WorldEditSUI 1.7.4 | Portalis 1.0, **WorldEdit 7.4.6-beta-02**, **WorldEditSUI 1.8.0** |
| memory | limit 2048Mi, request 512Mi | `-Xmx2G` inside a 3GiB limit |
| port | Traefik `minecraft` entrypoint | `incus network forward` 25565/tcp |
| autoscaling | mc-router, `replicaCount: 0` | none -- always running |
| backups | none | daily archive, replicated |

**The k3s PVC is the authority for this server's real configuration**, not the
values it was created with. Six weeks of play will have drifted from the chart --
level seed, pvp, spawn-npcs, the world border, the operator list, whatever
somebody set in-game. So a migrated volume keeps every one of those files
untouched and `minecraft-config.service` only fills in what is missing.

### The whitelist/ops UUID trap

Two separate traps in the same two files, both found by booting rather than
reading.

**1. UUIDs are mandatory.** The chart held these as arrays of bare name strings.
Paper parses that as an *empty* list and rewrites the file to `[]` on startup,
destroying it. So entries are `{name, uuid}` objects.

**2. The UUIDs must be DASHED.** Paper compares the `uuid` string in the file
against the one it holds in memory as a **raw string comparison**, not as parsed
UUIDs. Mojang's profile API returns them undashed, so a file built from the API
matches nothing. The server said so itself:

```
UUID of player SakulFlee is e1f94c32-e1a1-450a-8e06-5ab0d0209c29
Disconnecting SakulFlee: You are not whitelisted on this server!
```

Same player, same UUID, one character of difference between `e1f94c32-e1a1` and
`e1f94c32e1a1`. The values here are copied from the old server's own
`whitelist.json`, which is also where the eighth player comes from: `zero_MB` is
on the live whitelist but was never in the chart, and would have silently lost
access on migration.

The unit repairs these files when they are **missing or empty** and leaves a
populated one alone. "Missing" alone would not have been enough: Paper's rewrite
turns a malformed file into `[]`, which then counts as present and would never be
repaired. This way a fresh volume gets a working roster, a migrated volume keeps
the live server's own roster, and an operator added in-game is never clobbered.

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

## Plugins

`portalis` 1.0 is unchanged from the chart and loads on 26.3.

WorldEdit and WorldEditSUI had to move: the chart's 7.3.17 / 1.7.4 are 1.21-line
builds and refuse 26.3 with

```
** This Minecraft version (26.3-175 ...) is not supported by this version of WorldEdit.
```

WorldEditSUI's resulting `NullPointerException` is a **symptom, not a second
problem** -- it `depend`s on WorldEdit and dereferences a plugin instance that
never loaded. Fixing WorldEdit fixes both.

### Picking the version, since Hangar does not tell you

Hangar publishes no supported-Minecraft-versions field, and the plugin only
reports the mismatch at runtime. WorldEdit resolves a Bukkit adapter per MC
version from bundled packages, so **the adapter package list is the support
matrix**:

```
$ unzip -l worldedit-bukkit-<ver>.jar | grep adapter/impl | sort -V
v1_21_11  v26_1  v26_2  v26_3      <- 7.4.6-beta-02
v1_21_11  v26_1  v26_2             <- 7.4.5 (stable)
```

That is how the choice was made, and it has a cost worth stating plainly:
**WorldEdit on 26.3 requires a beta.** The alternative is pinning the server to
26.2 and using stable 7.4.5, but the world is already 26.3-converted and Paper
will not serve a downgrade, so the beta is the only route to both 26.3 and
WorldEdit. Revisit when 7.4.6 goes stable -- one URL in `pluginUrls` changes.

### Changing a plugin version

`pluginUrls` in `default.nix` is the source. The fetch unit **skips a jar whose
filename already exists**, so a version change also means removing the old jar,
or you end up with two copies of the same plugin and a duplicate-load error:

```bash
incus exec minecraft -- rm -f /var/lib/minecraft/plugins/worldedit-bukkit-7.3.17.jar \
                            /var/lib/minecraft/plugins/WorldEditSUI-1.7.4.jar
systemctl restart minecraft-fetch minecraft
```

Plugin *configuration* under `plugins/<name>/` is world data: it is not touched
by a jar swap, so plugin upgrades carry their own settings forward.

## Loading the k3s data

The world is 26.x (see "The version pin is the floor the world requires"), so
the instance must already be on 26.3 **before** any of this. Paper will not go
backwards, and a 1.21.11 server handed this world is a failed load, not a
warning.

Do it with the server stopped, so nothing writes while the copy runs:

```bash
# 1. stop the service, not the container -- the volume stays attached
incus exec minecraft -- systemctl stop minecraft minecraft-fetch minecraft-config

# 2. copy the world and its config over the data volume, excluding our backups
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
- `--delete` matters: the volume currently holds a **1.21.11 world that Paper
  generated on first boot**, and leaving it in place next to the 26.x world would
  be worse than either. The volume is snapshotted `@daily`/`7d`, so that
  generated world is recoverable if it turns out to matter (it does not).
- **`server.properties` comes across from the PVC**, including
  `max-world-size=29999984` and `level-seed=`. That is the intent -- the live
  server's settings are authoritative and `minecraft-config.service` leaves an
  existing file alone. The world border in `world/data/` travels with the world.
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

A verified archive is 3.0 GB and takes ~75s, of which the server is down for the
duration.

## Adding a producer: restart the hub

The one non-obvious operational step. `replicated-volumes.nix` is enough for the
*declaration*, but **the hub must be restarted** for a newly added volume to
actually be mounted:

```bash
incus restart syncthing
```

`apply.sh` only rewrites the device config; Incus applies disk devices at
instance start. A device added to a running hub stays declared and never appears
in `/proc/self/mounts`, so the path is an empty directory on the hub's own root
disk. Nothing errors, nothing is logged, and the folder does not even show as
"stopped" -- it is `sendonly` over an empty directory, replicating nothing.

That is what happened here: the hub started at 02:29:37, `minecraft-backups` was
created at 02:31:26, and the first archive sat unsynced until a restart. The
comment in `../syncthing/incus.nix` claimed the device "attaches on a later
reconcile", which is the belief this corrects.

## The first backup run failed, twice, for the same reason

Worth recording because the diagnosis was wrong both times.

```
/bin/sh: line 1: gzip: command not found
tar: Child returned status 127
tar: ... Wrote only 4096 of 10240 bytes
```

`tar -czf` does not compress internally -- it execs an external `gzip`. The
unit's `path` listed `gnutar` and not `gzip`, so the archive failed in under two
seconds and left a 0-byte `.tmp`.

The first occurrence was read as "the container recreate killed the tar
mid-flight", which is why the trap and the recreate got credit for the survival
and the gzip omission went unnoticed. It was not that: the tar had failed
instantly, and a recreate only explains why nobody noticed. The backup had never
once worked.

Two consequences now handled in the unit: `pkgs.gzip` is on the `path`, and a
run deletes stale `.tmp` files first. That second part matters because a failed
tar leaves its `.tmp` **root-owned** (the unit runs as root to stop and start
the server) inside a `minecraft`-owned directory, so the next run cannot
overwrite it and the corpse sits there permanently -- silently, since
`.stignore` keeps it off the peer. The finished archive is chowned to
`minecraft` for the same reason.

## Adding a plugin

`pluginUrls` in `default.nix` -- append the Hangar URL, reconcile, and the jar is
fetched on first boot. It is not overwritten if already present, so a version
bump means deleting the old jar from `plugins/` as well.