# Hytale (Incus container)

A Hytale dedicated server run from the official jar by a systemd unit,
replacing the k3s deployment in `apps/hytale/` (a Helm chart wrapping a locally
built container image). **That deployment has been removed** -- along with
`clusters/homelab/apps/hytale.yaml`, its dead `.sops.yaml` rule and its Traefik
entrypoint -- once an archive had been produced here *and* confirmed replicated
off the host. See "Verified" at the bottom for that evidence.

- Address: `10.0.0.116` on `incusbr0`, in the `default` Incus project.
- Game port: `5520/udp`, forwarded on `192.168.178.200`. **No Caddy vhost** --
  see "Why a forward and not a vhost" below.
- Volumes: `hytale-data` at `/var/lib/hytale` (assets, jar, universe, mods),
  `hytale-backups` at `/var/lib/hytale/Server/backups` (the archives, the only
  thing the Syncthing hub replicates) and `hytale-secrets` at
  `/var/lib/hytale-secrets` (the downloader's OAuth token, unsnapshotted).
- Backups: `hytale-backup.timer` at 04:20 daily sends `/backup` to the server's
  tmux console and then prunes by age, 7-day window.
- Console: `tmux attach -t hytale` -- stdin is the only admin channel Hytale
  has, and auth certificates expire about hourly.
- Snapshots: `@hourly`/`24H` on the two data volumes.

> **DHCP is live on `incusbr0`**, so every instance here pins a static address.
> `.116` was chosen after checking the live instances with
> `incus list homelab: --format csv -c n4`, which is not the same thing as
> reading this repository: `.110` is wireguard's second NIC and `.114` is
> `website`, a VM on a macvlan, so neither is an `incusbr0` instance in the
> registry but both hold an address inside the range.

## The four things that are not obvious

### Why a forward and not a vhost

Everything else in this homelab reaches the internet through Caddy, which
terminates TLS and routes by hostname. Hytale cannot be routed that way: it
speaks **QUIC over UDP** -- a TLS-derived transport with its own connection
migration and congestion control -- addressed by IP and port, with no hostname,
no path and no request line anywhere in it. Upstream says so outright: "forward
**UDP port 5520** ... TCP forwarding is not required."

So this instance gets an `incus network forward`, which Incus implements as an
nftables **DNAT rule rather than a socket bind**. That is what makes it safe to
add while the incumbent still holds the port: packets aimed at
`192.168.178.200` are rewritten in `PREROUTING`/`OUTPUT` before socket lookup,
while Traefik's listener on `0.0.0.0:5520/udp` keeps the port and simply stops
being reached. See `../caddy/incus.nix` and `incus/README.md` for the full
argument.

### The server backs itself up, and nobody has to stop it

This is the one that differs most from `minecraft`, and it is why this instance
does **not** have a `hytale-backup` unit that tars anything.

Minecraft has to stop the server around its backup, because Paper rewrites
region files in place and a tar that reads one mid-write captures a
half-updated chunk -- a failure that surfaces weeks later as "that area of the
map is gone". Hytale does not have that problem, and the reason is in its
bytecode rather than in its documentation. From the running 0.6.8 jar:

```
Universe.runLockedBackup()
  -> universeResources.flushAll()                 <- every resource forced to disk
  -> BackupTask(Universe::getDirectory, dir)      <- its own ZipOutputStream
```

and the scheduler that drives it:

```
SCHEDULED_EXECUTOR.scheduleWithFixedDelay(runner, _, frequency, MINUTES)
```

`flushAll()` before the zip is the whole point. So the archives are made by the
server itself, with **zero downtime**.

`BackupCommand` calls `Universe.runBackup()` -- the *same* method the built-in
scheduler calls -- so the flush and the zip are identical whether the archive is
triggered internally or by a command. That is what makes the next section
possible: we can drive the backup ourselves and change nothing about how it is
made.

### The server's own scheduler does not survive a restart

The scheduler above is created during startup:

```
SCHEDULED_EXECUTOR.scheduleWithFixedDelay(runner, initialDelay, delay, MINUTES)
```

Two consequences, both observed rather than inferred. A server started with
`--backup-frequency 1440` logged

```
[Universe|P] Scheduled backup to run every 1440 minute(s)
```

and then produced **no archive at all** over the following quarter of an hour --
so the initial delay is the period, not zero. And because the countdown is
rebuilt on every boot, a server restarted inside the window never backs up *at
all*, silently: an empty `backups/` is indistinguishable from "not due yet".

On this host that is not hypothetical. `incus-apply-<name>.path` fires on every
`git pull`, any image change recreates the instance, and the host auto-updates
hourly. A busy week could mean no backup whatsoever, and nothing would say so.

So `hytale-backup.timer` presses the button instead, by sending `/backup` to
the console described below.

### stdin is the only administration channel, so there is a console

Hytale has no RCON, no HTTP admin API and no query endpoint. `Options` was
checked in both 0.6.8 and 0.7.0; the only match for any of those is Hypixel's own
*"Session token for Session Service API"*. **stdin is the only way to administer
this server**, which is why the k3s deployment ran it with `stdin: true,
tty: true`, and why the `hytale-hytale-0:8081` service you see in k3s being
`pvceplorer.io/managed-by: pvc-explorer` rather than Hytale is worth noting.

So this instance runs the JVM inside a **tmux session**, which is what gives it
a console:

```bash
incus exec homelab:hytale -- sudo -u hytale tmux attach -t hytale
```

and sends it commands without stopping anything:

```bash
incus exec homelab:hytale -- sudo -u hytale tmux send-keys -t hytale '/backup' Enter
```

tmux rather than a plain pipe on stdin, and the reason is that tmux hands java a
**real pty**. A FIFO works and was the first version of this file, but it relies
on JLine falling back to a dumb terminal when stdin is not a TTY -- `ConsoleModule`
uses `org.jline`'s `TerminalBuilder` and `LineReaderBuilder`, and the fallback
exists, but that is an assumption about a library on the one path the whole
server depends on. tmux removes the assumption and gives an attachable console
as well.

That last part earns its keep more than the backup does. **Hytale's auth
certificates expire roughly hourly, and an outage longer than that loses the
server's authenticated identity outright.** Being able to run
`/auth login device` against a *running* server turns a player-visible outage
into a command.

### Hytale cannot express an age-based retention, so we do the deleting

`BackupConfig`'s codec has exactly five fields, and there is no sixth:

```
Enabled          boolean   "Determines whether automatic backups are enabled"
FrequencyMinutes integer   "Must be at least 1"
Directory        string    "The backup directory path"
MaxCount         int       "The maximum number of recent backups to retain"
ArchiveMaxCount  int       "The maximum number of archived backups to retain"
```

The CLI adds no age option either (`--backup`, `--backup-frequency`,
`--backup-dir`, `--backup-max-count`, `--backup-archive-max-count`), and there
is nothing in `config.json` beyond those five. Retention is **count-based,
full stop**.

A count is not the same as an age, and the difference bites: a count silently
changes meaning if the frequency is ever edited. 7 archives is a week at
`--backup-frequency 1440` and four hours at 60.

So `default.nix` sets the counts absurdly high -- they are Hytale's retention
and this instance does not use them -- and sets the *frequency* to a year, so
the built-in scheduler never fires while `/backup` still has the directory it
needs to be willing to run. `hytale-backup.timer` asks for the archive at
04:20 daily and then deletes by **age**:

```bash
find backups -maxdepth 1 -type f -name '*.zip' -mtime +7 -print -delete
```

Leaving Hytale's counts at their defaults would mean two prunes racing over one
directory, and Hytale's would win by *archiving* rather than deleting: moving
files into `backups/archive/` that nothing then prunes.

`maxdepth 1` is deliberate, for the same reason: this must not quietly empty
the `archive/` tier that the disabled retention would have used.

**Pruning locally does not delete on the peer.** `hytale-backups` is replicated
as a **sendonly** folder, and a sendonly folder never applies a remote deletion,
so an archive removed by the 7-day window stays on Dendra forever. That is the
right way round for a backup, and it is why the local window can be short
without being the whole history.

### Only the archives are replicated, and the credentials are not a renderedSecret

The Syncthing hub mounts `hytale-backups` read-only and mirrors it to the peers
listed in `../syncthing/default.nix` (currently Dendra) as a **sendonly**
folder. It does *not* see `hytale-data`, so it never replicates a live world --
the same reasoning as `minecraft-backups`, and for the same reasons:

- A world is 15 whole-file region blobs of 12-32 MB that get rewritten when
  anyone plays. Replicating that means re-shipping 178 MB and racing the
  server's writes for it.
- An archive is one immutable zip, written once, after `flushAll()`.

This is the third producer in the scheme `paperless` established; the contract
is `../syncthing/NOTES.md` ("Replication standard") and the list is
`nixos/replicated-volumes.nix`. This instance's obligations:

| obligation | where |
| --- | --- |
| data on `persistent`-pool custom volumes, `default` project | `incus.nix` |
| volume name in `replicated-volumes.nix` | `nixos/replicated-volumes.nix` |
| producer writes `.stfolder` itself (hub is read-only) | `hytale-dirs` + a tmpfiles rule |
| folder is `sendonly`, no versioning | derived in `../syncthing/default.nix` |

The downloader's OAuth credentials are on `hytale-secrets`, which has **no
`snapshots` block**, and that is the point -- a day of hourly snapshots would
each otherwise hold a copy of a refresh token for a game account.

They are deliberately **not** a `renderedSecrets` entry either, and this is the
one place this instance diverges from the caddy/forgejo pattern. `apply.sh`
diffs a rendered file against the host's sops value and **rewrites it on every
run**, and `incus-reconcile.timer` runs `--all` every fifteen minutes. The
downloader re-saves its own credentials whenever its tokens refresh, so sops
would overwrite a refreshed token with a stale one every quarter of an hour, and
the next download would fail with a 401 at exactly the moment a patch landed.
The file is unmanaged instead, pointed at explicitly with `-credentials-path`,
and survives a recreate because the volume does.

## k3s parity

| | k3s (`apps/hytale/`) | here |
| --- | --- | --- |
| server | custom image `forgejo.sakul-flee.de/containers/hytale:latest` | official jar, `openjdk25` |
| JVM opts | `-server -XX:+UseG1GC -XX:+UseStringDeduplication -Xmx4G -Xms512M` | same, minus the duplicated `-server` |
| launch | `java ... -jar HytaleServer.jar --assets ../Assets.zip --accept-early-plugins` | same, plus the four `--backup*` flags |
| payload | baked into the image by an entrypoint | `hytale-download.service`, via the official downloader |
| data | PVC `hytale-hytale-0` (32Gi) at `/opt/hytale` | `hytale-data` at `/var/lib/hytale` |
| uid | 0 (root) | 989 |
| memory | limit 8Gi, request 2Gi | 8Gi cgroup, `-Xmx4G` |
| cpu | limit 2000m, request 250m | 4 (see `incus.nix`) |
| port | Traefik `hytale` entrypoint, 5520/udp | `incus network forward` 5520/udp |
| backups | **none** | server-side, daily, replicated, 7-day window |
| secrets | `hytale-credentials` k8s Secret, `optional: true` and **absent** | `hytale-secrets` volume, written by the downloader |

The last row of that table is the migration's quiet win: the k3s deployment
passed no backup flags at all, so `Server/backups` did not exist and the world
had **no backup of any kind**. It does now.

The credentials Secret being `optional: true` and absent is worth noting too --
the k8s chart mounted `/opt/hytale-downloader-secret` from a Secret that did not
exist, and the working credential file was a manual `kubectl cp` into the PVC.
There is a leftover `.hytale-downloader-credentials.json.bad.1787957997` beside
it, from the downloader finding a session it could no longer load and renaming
it. That recovery path is why the old file is worth carrying across.

## Deploying

```bash
incus/apply.sh --check hytale    # build the image, report drift, change nothing
incus/apply.sh hytale            # reconcile
incus-status.service             # is it up
```

### The forward is applied last, on purpose

`apply.sh` applies the `networkForward` **after** the instance is up and its
consumers have restarted, precisely so a DNAT is never pointed at nothing that
is serving. But for this instance "up" does not mean "serving": the server
cannot start until the payload has been downloaded and authenticated for, which
is a human-gated step.

So the deploy is deliberately in two halves. With the `networkForward` stanza
absent from `hytale/incus.nix`, Traefik keeps answering `5520/udp` and the live
k3s server is untouched while the download happens. Once the server has been
seen to run, adding the stanza and reconciling is the cutover.

Nothing errors if you skip this and deploy with the forward in place -- Traefik
still holds the port, so the forward simply takes precedence and players find a
container with no server in it. That is the quietest possible failure and the
reason the two halves are worth doing separately.

### Getting the server files

There is no anonymous download. The payload comes from Hypixel's own downloader
through an OAuth device-code flow, once, by hand.

**Prefer the unit.** It does the whole thing unattended and is the only form
that ends with the layout verified:

```bash
incus exec homelab:hytale -- sudo systemctl start hytale-download
```

The credentials it needs are created by that same run, so it works on a volume
that has never seen the account. Subsequent runs are fully unattended, which is
the point: the device code is only ever needed once.

Running the binary by hand is the better shape for that *first* run, because the
device-code output is easier to follow in a terminal:

```bash
incus exec homelab:hytale -- sudo -u hytale \
  /var/lib/hytale/hytale-downloader-linux-amd64 \
  -credentials-path /var/lib/hytale-secrets/.hytale-downloader-credentials.json \
  -download-path /var/lib/hytale/game.zip
```

It prints a URL and a code; authorise in a browser and it pulls ~4 GB. After
that the credentials refresh themselves and every later run is unattended.

**`-download-path` is not optional when you run it by hand**, and that is a real
trap rather than a style point. Left off, the downloader writes
`<version>.zip` into the **current directory** -- and `incus exec` starts in `/`,
so the first attempt here died with

```
downloading latest ("release" patchline) to "0.7.0.zip"
error downloading: could not create file: open 0.7.0.zip: permission denied
```

after a successful authorisation, because `hytale` cannot write to the
container's root. Passing `-download-path` (or `systemd-run`/the unit, which set
`WorkingDirectory`) avoids it.

Two more details:

- **It writes a zip and does not extract it**, despite `-download-path` and
  despite upstream's docs implying the CLI "sets up this layout automatically".
  `hytale-download.service` does the extraction and then *verifies* that
  `Server/HytaleServer.jar` and `Assets.zip` are where the server will look for
  them, so a partial extraction fails in the unit that caused it rather than as
  a classpath error in `hytale.service` an hour later.
- **There is no direct URL for the platform binary.**
  `https://downloader.hytale.com/hytale-downloader-linux-amd64` is a 404, so
  `hytale-downloader.service` fetches `hytale-downloader.zip` and extracts the
  one file it wants. It checks integrity by *running* the result (`-version`),
  not by hashing it: the archive is a moving target carrying the downloader's
  own self-update mechanism, so a recorded hash would mean shipping a stale
  downloader exactly when a new one is published.

## Loading the k3s data

~494 MB, and it must be done with the k3s deployment still in place so there is
something to roll back to.

```bash
# The host path is NOT guessable. local-path names the directory
# pvc-<uuid>_<namespace>_<claim>, and dropping the namespace segment is
# easy here precisely because the namespace and the claim share a prefix.
# A glob then matches nothing and tar is handed an empty SRC:
#
#   zsh: no matches found: .../backup/*hytale-hytale-0
#   tar: : Cannot open: No such file or directory
#
# Ask the PV instead, which is authoritative and cannot rot. Keep the echo:
# a wrong SRC here is a silent no-op at the far end of a pipe.
SRC=$(kubectl get pv pvc-2f4dc6ea-9ba0-457c-b12b-3a68d017d662 \
        -o jsonpath='{.spec.local.path}')
echo "$SRC"

# 1. stop the service, not the instance -- the volume stays attached.
#    Killing the tmux session makes the supervision loop fall out and systemd
#    restart the unit, so stop the unit rather than the session.
incus exec homelab:hytale -- sudo systemctl stop hytale

# 2. stream the world, the mods and the config onto the volume.
#    Assets.zip (3.4G) and the jar (110M) are deliberately NOT copied: they come
#    from the downloader in the step above, and copying the PVC's copy would
#    pin the server to whatever version that PVC happened to hold.
tar -C "$SRC" --exclude=./Assets.zip --exclude=./Server/HytaleServer.jar \
        --exclude=./Server/HytaleServer.aot.config --exclude=./Server/Licenses \
        --exclude=./Server/logs -cf - . \
  | incus exec homelab:hytale -- sudo tar -C /var/lib/hytale -xpf -

# 3. take ownership: the PVC's files belong to the old image's uid, and this
#    instance runs as 989. sudo, because extracting as root creates root-owned
#    files and the server then cannot write its own world.
incus exec homelab:hytale -- sudo chown -R 989:989 /var/lib/hytale

# 4. start again
incus exec homelab:hytale -- sudo systemctl start hytale
```

Notes:

- **Stop before copying.** The server writes `universe/` continuously.
- **Stream rather than stage.** A 3.4 GB payload staged in `/var/tmp` and then
  copied needs the space twice.
- **`.machine-id` and `auth.enc` travel together, but only one of them means
  anything.** `/opt/hytale/.machine-id` is a 32-character hex id at the *volume
  root*, not inside `Server/`, and there is no `auth.key` anywhere -- the
  credential store is `auth.enc` alone. Both are inside the tar above
  (`--exclude` does not touch either), which is why the excludes are worth
  reading as a list rather than skimmed.
- **The machine-id is the key, via `HardwareUtil` -- see "How this got
  backwards twice" below.** HytaleContainer's `entrypoint.sh` generates
  `/opt/hytale/.machine-id` on first boot and then does
  `cat /opt/hytale/.machine-id | tee /etc/machine-id` on every start, so the
  volume-root file is the source of truth and `/etc/machine-id` is derived from
  it. **That `tee` is not cosmetic and not only telemetry**: `/etc/machine-id` is
  what `EncryptedAuthCredentialStore` derives the `auth.enc` key from, by way of
  `HardwareUtil.getUUID()`. Copying `auth.enc` across without also pinning
  `/etc/machine-id` to the id it was encrypted under is why the migrated store
  never opened.
- **They did not actually work, and this is the part worth knowing.** The copy
  was byte-perfect -- `auth.enc` arrived at 1407 bytes with its mtime preserved
  -- and the server still logged:

  ```
  [ServerAuthManager] Auth credential store: Encrypted
  [HytaleServer] No server tokens configured. Use /auth login to authenticate.
  ```

  The decisive detail is that the run *before* the data load logged the same
  two lines, so the migrated store changed nothing observable: 0.6.8's
  `auth.enc` does not carry into 0.7.0. The fallback is `/auth login device`,
  which is why this instance has a console to type it into:

  ```bash
  incus exec homelab:hytale -- sudo -u hytale tmux attach -t hytale
  ```

  A successful run logs `Authentication successful! Mode: OAUTH_STORE` and
  `Token refresh scheduled in 3300 seconds`.
- `auth.enc` is mode `0600` in the PVC and `chown -R` does not change modes, so
  it arrives with the right one.
- The volume is `@hourly`/`24H`, so a bad load is recoverable by rolling the
  snapshot back rather than by re-copying.

## Updates: `/update apply` does nothing here

The payload contains upstream's own `start.sh`, and this instance **does not use
it**. Two reasons, both about control:

- `start.sh` hardcodes `--backup --backup-dir backups --backup-frequency 30` and
  appends `"$@"` after it. The CLI overrides `config.json`, so the backup
  cadence could not be set to daily from *anywhere* -- not from `config.json`,
  not from `default.nix` -- without hand-editing a downloaded, mutable script
  that nothing in this repository reviews. Thirty-minute archives of a 178 MB
  universe is ~8 GB/day replicated to Dendra, forever.
- `start.sh` exists to apply staged updates: the server downloads a new payload
  into `updater/staging`, exits 8, and the script copies it into place and
  loops.

Under systemd the loop is redundant -- `Restart=on-failure` handles exit 8 --
but **the copy step is not**, so `/update apply --confirm` will exit 8, restart,
and come back on the same binaries.

This is inherited: the k3s deployment also ran the jar directly rather than
through `start.sh`, so this has always been the behaviour of this server. It is
called out here rather than left to be discovered during a patch.

It matters more than usual for Hytale than for most games, because the protocol
is hash-checked: upstream's own note is "the client and server must be on the
exact same protocol version" and players on a newer client "cannot connect" at
all. When a patch lands, the upgrade is therefore a deliberate two-step:

```bash
incus exec homelab:hytale -- /update setup      # writes start.sh/bat to the parent
# then switch hytale.service to ExecStart=/var/lib/hytale/start.sh and reconcile
```

`/update setup` extracts the wrapper scripts from the running server, so no
download is needed for it. `config.json`'s `Update.AutoApplyMode` is `Disabled`
by default, which is the right setting here: it means the server *notices* a
version and logs it, and nothing applies it behind your back.

## Adding a producer: restart the hub

The one non-obvious operational step, and it applies to this instance exactly
as it did to `minecraft-backups`. `replicated-volumes.nix` is enough for the
*declaration*, but **the hub must be restarted** for a newly added volume to
actually be mounted:

```bash
incus restart syncthing
```

`apply.sh` only rewrites the device config; Incus applies disk devices at
instance start. A device added to a running hub stays declared and never appears
in `/proc/self/mounts`, so the path is an ordinary empty directory on the hub's
own root disk. Nothing errors, nothing is logged, and the folder does not even
show as "stopped" -- it is `sendonly` over an empty directory, replicating
nothing.

## Snapshots

`@hourly`/`24H` on `hytale-data` and `hytale-backups`. Every other data-bearing
volume on the host is `@hourly`/`7d`, so the interval is the same everywhere and
the only thing particular to Hytale is the shorter window.

A btrfs snapshot copies nothing: it costs only the extents written **after** it
was taken, so **the retention window sets the cost, not the interval** --
`@hourly`/`7d` holds exactly as many bytes of deltas as `@daily`/`7d` and
resolves them seven times finer. This
volume is the good case, measured on the live deployment before migrating:

| | size | write behaviour |
| --- | --- | --- |
| `Assets.zip` + jar + `.aot.config` + `Licenses` | ~3.6 GB | **once**, at download, never again |
| `chunks/*.region.bin` | 178 MB | 15 whole-file blobs of 12-32 MB, last written Aug 26-30 |
| `resources/` + `players/` JSON | ~220 kB | rewritten constantly |

So the hot-write set is ~220 kB and the 178 MB of region blobs is cold, which
puts an hourly tier at a few MB a day rather than 178 MB a day.

`minecraft-data` is the volume everyone expects to be expensive here, because
Paper rewrites region files continuously while players are online. It moved to
`@hourly`/`7d` with everything else, and pays the same bytes it already did --
interval is not the thing that costs. An earlier version of this file exempted it
on the opposite reasoning, which was wrong for the same reason.

`hytale-backups` is snapshotted hourly for a different reason. The archives are
immutable, so the snapshots are nearly free; what they buy is a bound on the
blast radius of `hytale-backup.service`, which is the one unit here that
**deletes** anything. A snapshot taken before each run means a misfire costs an
hour of archives rather than the whole retention window.

## Verified and not verified

Verified before the port, against the live 0.6.8 jar and the running k3s
deployment:

- the backup scheduler, `flushAll()` and the `BackupTask(Universe::getDirectory, …)`
  call, so "no downtime" is read from bytecode and not assumed
- that `BackupConfig` has no age-based field and the CLI has no age flag
- that `--backup-dir` is relative to `Server/`, and that `backups` is therefore
  the same directory this instance mounts `hytale-backups` on
- that the region data is already compressed: `gzip -6` over the live chunks
  returned 98% of raw, so `zip` and `tar -czf` land within a percent of each
  other and compression is not a reason to prefer a hand-rolled tar
- that the server has no RCON/HTTP admin/query channel
- that `.machine-id` sits at the volume root and `auth.key` does not exist
- that `HardwareUtil.getUUID()` reads `/etc/machine-id` and serves two callers:
  `TelemetryDataCollector.generateMachineIdHash` for the telemetry packet, and
  `EncryptedAuthCredentialStore.resolvePassphrases` for the PBKDF2 key that
  protects `auth.enc`. The auth package contains no literal `machine-id`, so a
  grep for one alone will not find this

Verified on the deployed instance:

- the downloader produces exactly the layout this instance expects --
  `hytale-download.service` asserted `Server/HytaleServer.jar` and `Assets.zip`
  after extracting, and the server booted on the result
- `-credentials-path` really does keep the token off `hytale-data`: the file
  appeared at `/var/lib/hytale-secrets/.hytale-downloader-credentials.json`,
  mode `0600 hytale:hytale`, on its own unsnapshotted volume
- the server listens on `0.0.0.0:5520/udp` and the `networkForward` DNAT is in
  place alongside every other instance's forward on `192.168.178.200`
- the Syncthing hub mounts `hytale-backups` read-only **only after
  `incus restart syncthing`** -- before that the device was declared and
  `/proc/self/mounts` had two replicated mounts, not three
- the AOT flag is correctly omitted: the payload ships `HytaleServer.aot.config`
  and no `HytaleServer.aot`, so `-XX:AOTCache=HytaleServer.aot` names a path
  that does not exist

**Verified after the fact, on the deployed server:**

- `--backup-frequency 1440` logs `Scheduled backup to run every 1440 minute(s)`
  and produces **no archive** over the following quarter of an hour, which is
  what established that the initial delay is the period rather than zero
- `.machine-id` + `auth.enc` copied intact across instances and versions but did
  **not** authenticate 0.7.0. The volume-root `.machine-id` was never the
  relevant file; `/etc/machine-id` is, and it was not migrated. `/auth login
  device` was required, and the real diagnosis is below.
- **`auth.enc` is encrypted with a key derived from the machine id**, so it does
  not survive a recreate. This is the actual cause of the recurring
  re-authentication, and it was misdiagnosed twice before being pinned down:

  ```java
  EncryptedAuthCredentialStore.resolvePassphrases(Path)
    -> com/hypixel/hytale/common/util/HardwareUtil.getUUID()
    -> PBKDF2WithHmacSHA256 -> SecretKey
  ```

  On Linux `HardwareUtil.getUUID()` reads `/etc/machine-id`, so Incus handing
  out a fresh id per recreate makes every previously written `auth.enc`
  undecryptable:

  ```
  [EncryptedAuthCredentialStore] Failed to decrypt credentials from auth.enc
  ```

  It is **not** a token-expiry problem. `Token refresh scheduled in 3300
  seconds` is real but irrelevant; the store fails to open at all.

  Proven rather than inferred: `/etc/machine-id` was set back to the value in
  effect when `/auth login device` last ran, the server restarted, and the log
  said `Authentication successful! Mode: OAUTH_STORE` -- same `auth.enc`, same
  1407 bytes, no browser.

- **`/etc/machine-id` is therefore pinned** to `/var/lib/hytale/.machine-id`,
  which lives on `hytale-data`. One final `/auth login device` is needed to
  re-key the store to the pinned id; after that, deploys stop costing a browser.
- **Pinning costs nothing, provided the journal is redirected with it.**
  `journalctl` resolves its search path from `/etc/machine-id`, and journald has
  already written the boot under `/var/log/journal/<id-at-boot>/`, so a bare pin
  makes every query return `No journal files were found.` `hytale-dirs` points
  `/var/log/journal/<pinned-id>` at the boot-time directory as a symlink, before
  changing the id, and warns on stderr if that directory is missing rather than
  skipping silently.

### How this got backwards twice, since the wrong answers are the useful part

1. **"`.machine-id` and `auth.enc` travel together."** Right conclusion, wrong
   file: it pointed at `/opt/hytale/.machine-id`, the volume-root file that
   HytaleContainer's `entrypoint.sh` generates. That file is indeed copied to
   `/etc/machine-id` on every start -- it is a real Docker-era workaround, just
   for telemetry.
2. **"No, it is telemetry only."** Grepping the whole jar for the literal
   `machine-id` returns exactly one class, `HardwareUtil`, and its output feeds
   `TelemetryDataCollector.generateMachineIdHash`. Correct grep, wrong
   conclusion: the string never appears in the auth package, because it calls
   `HardwareUtil.getUUID()` and inherits the path from there. `HardwareUtil`
   serves both purposes.
3. **"So it is telemetry, and pinning it costs the journal."** The cost was
   real and measured. What was missing is that the cost is avoidable -- the
   journal directory just needs redirecting -- while the benefit, auth
   surviving deploys, was thrown away with it.

The lesson worth keeping: a literal grep is good evidence that a string is
absent and poor evidence that a behaviour is. And a measured cost is a reason to
look for a way around it, not automatically a reason to drop the benefit.

**Verified on the deployed server, the last unproven link:**

- `systemctl start hytale-backup` works. `tmux send-keys '/backup'` produced
  `2026-10-13_03-21-26.zip`, 178,282,405 bytes, in 12.2s, with the unit
  reporting `Result=success`. The server stayed up throughout, which is the
  whole point of `flushAll()` running before the zip.
- The archive reaches the hub: byte-identical on syncthing's read-only mount at
  `/mnt/replicated/hytale-backups`.
- And it reaches **off the box**, which is what the teardown was waiting on.
  `replicated-hytale-backups` reports `state: idle`, `localFiles: 1`,
  `globalFiles: 1`, `globalBytes: 178282405`, `needFiles: 0`, `needBytes: 0`
  -- synced to the peer with nothing outstanding.

**Verified about logging, after two wrong implementations:**

- The server writes its own per-session log to `Server/logs/`, and it is the
  complete unwrapped console output. The live session's file was 362 KB and
  contained `Universe ready!`, `Listening on /0.0.0.0:5520` and
  `Authentication successful! Mode: OAUTH_DEVICE`.
- `tmux pipe-pane | systemd-cat` does not work here, and both failures are worth
  remembering: the pane's render carries control sequences, so journald stored
  every line as `[140B blob data]`; and after stripping them, `systemd-cat` died
  silently mid-session while tmux still reported `pane_pipe=1`. Read the file,
  not the journal. See the comment above `tmux new-session` in `default.nix`.

**Not yet verified**: that `hytale-backup.timer` fires on its own at 04:20 and
that it survives a restart in the way the built-in scheduler did not. The unit
itself is proven; only the timer schedule is not.
