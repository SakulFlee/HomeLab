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

## Secrets

**An instance is given rendered values, never a key.** `incus.nix` declares

```nix
renderedSecrets = [
  { file = "caddy-env"; env = "CF_API_TOKEN"; source = "/run/secrets/cloudflare_api_token"; }
];
```

and `apply.sh` reads `source` — which the *host* decrypts, with the host's own
SSH identity key — and writes `ENV_NAME=<value>` into `file` inside the
instance, on a `persistent` (not restic'd) volume. The value is piped on stdin,
never a command-line argument, and the write is diffed so a settled redeploy
touches nothing.

`format = "raw"` writes the secret's bytes through unchanged instead of
prefixing `ENV_NAME=`, for anything that is not a `KEY=value` line. The
incus.sakul-flee.de vhost needs it for a PEM certificate and key: as
EnvironmentFile lines they would collapse into one enormous malformed variable,
and Caddy would be handed that instead of a key file. Trailing newlines are
stripped by the command substitution; the internal ones a PEM is made of survive.

The alternative, which is in the git history, imported sops-nix into the
instance and bind-mounted the host's `/etc/ssh/ssh_host_ed25519_key` so it could
decrypt for itself. It worked. It was also the wrong shape: it gave a root
process in the container the ability to decrypt **every** value in the host's
`secrets.yaml` — the restic password, the Forgejo JWT secret, the PIA VPN
credentials — and the only thing limiting that was remembering not to.

This way the instance has no decryption capability at all. It holds one token
and cannot reach anything else even if it wants to. The price is that the token
is at rest in the instance's volume, which is why that volume is on the
not-restic'd pool.

One consequence worth knowing: `/run/secrets/*` does not exist until the host
has been rebuilt, so a new instance with `renderedSecrets` cannot come up before
that. `incus-secrets-<name>.path` exists for exactly this — `PathExists=` is the
one directive that fires on activation when its condition already holds, so the
instance reconciles itself the moment the host materialises the secret.

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
above, and a settled redeploy performs **zero** Incus writes: every set is
diffed first.

`incus/apply.sh` runs from the checkout rather than the store, which is what
makes the trigger work: **pulling the repo both updates the reconciler and
fires it.** The only case where you must start a service by hand is the first
deploy after installing the units, because per `systemd.path(5)` a `.path` unit
does not trigger on activation unless the directive is `PathExists=`.

A failed run is retried — `Restart=on-failure`, `RestartSec=60`, five attempts
over `StartLimitIntervalSec=2400` — because most failures here are transient
(incusd still coming up, a pool not mounted, a store lock held by the host
rebuild that triggered it). A genuinely broken config burns five builds and then
stays `failed`, and an `OnFailure=` unit sends a desktop notification, because a
redeploy that silently did not happen is the worst outcome available.

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
* **Only tracked files can affect the image.** A `git+file://` flake is built
  from the git tree, so an untracked file never reaches the image — Nix refuses
  to evaluate rather than guessing. The dirty-tree warning therefore uses
  `git status --untracked-files=no`; with the default it fired on every single
  run over a stray file that could not possibly have mattered.
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
  automatic, including a plain `git pull`.
* **The Incus client reads stdin when stdin is not a TTY, and sends it as the
  request body.** A loop fed by `while read … done < <(jq …)` therefore hands
  the *next* line of JSON to the server, which replies
  `field pool not found in type api.StorageVolumePut` — naming neither the
  command nor the cause. It only bites at two or more iterations, which is why
  one instance passed and another did not. Every loop is now `mapfile` + `for`,
  and every mutating call goes through `incus_run`, which redirects stdin from
  `/dev/null` and logs its own argv.

## The host's entry points

`networkForward` in an instance's `incus.nix` is how the host's own address
becomes reachable from outside. For `caddy` it is the whole cutover: until it
exists, Traefik inside k3s serves `:80`/`:443` on the host and Caddy is a
passenger; once it exists, all twenty hostnames terminate TLS at Caddy and are
handed back to Traefik over the bridge.

Incus implements a forward as an **nftables DNAT rule, not a socket bind**, and
that is the entire reason this is safe to do while the incumbent is still
running. Packets aimed at the forward's listen address are rewritten in
`PREROUTING`/`OUTPUT` before socket lookup; packets aimed anywhere else on the
same port are not matched and still reach the old listener. Two consequences
worth keeping:

* **Rollback is one command and takes effect immediately**, because the old
  listener never stopped holding the port:
  `incus network forward delete incusbr0 192.168.178.200`
* **The catch-all in the Caddyfile is loop-free because of the same asymmetry.**
  It dials `10.0.0.1:443`, which the rule does not match — it matches the
  host's LAN address only. If the forward ever listened on `10.0.0.0/24` this
  would become a loop immediately, and the failure would look like Caddy hanging
  rather than like a routing bug.

The reconciler applies it **last**, after the instance is up and its consumers
have been restarted. Pointing a DNAT at anything but a running, serving container
is the one way this script could take traffic down rather than hand it over.

### Things the network-forward API does that you would not guess

* **`port add` with a comma list stores ONE entry.**
  `port add … tcp 80,443 10.0.0.100 80,443` gives a single entry with
  `listen_port: "80,443"`, not two entries. So ports cannot be removed one at a
  time afterwards.
* **`port add` then refuses a listen port any existing entry already claims**,
  grouped or not:
  `Duplicate listen port 80 for protocol "tcp" in port specification 1`.
  A grouped entry aimed at an old target is therefore *unfixable by adding* — the
  reconcile could only skip it (leaving the DNAT wrong) or add alongside it (and
  die). It is removable by passing the exact stored string:
  `port remove … tcp "80,443"`.
  Hence remove-then-add against an exact tuple match, converging on one entry per
  port from any starting state.
* **`incus network forward show` prints YAML and has no `--format` flag**, and
  there is no usable `/1.0/network-forwards/<net>/<addr>` path. The only read
  that carries the ports is `incus network forward list <net> --format json`.
* **`incus network forward port remove` takes** `<net> <listen> <protocol>
  <listen_port>` — not the `show`-style shapes.
* **jq's `// empty` inside an array constructor removes the element.** `""` is
  falsey, so `"" // empty` is `empty`, and `[empty, "a", "b"]` is `["a", "b"]`.
  `forward_params` emits one scalar per line with `// ""` defaults for this
  reason: with a shorter array the listen address slides into the network slot,
  the `die` that should catch a NIC with no network never fires, and the
  reconcile goes on to `incus network forward create <an-ip> <an-ip>`.
* A changed NIC address does **not** take effect until the instance restarts.
  `incus config device` rewrites the config immediately and the runtime keeps the
  old address, so `apply.sh` can print `ok -- Running (10.0.0.150)` while the
  declared address is `10.0.0.101`. It only resolves on a recreate, and a
  redeploy that does not recreate will not notice.

## Incus client-certificate trust

`incusTrust` in an instance's `incus.nix` registers a certificate with Incus on
the instance's behalf. It exists for the `incus.sakul-flee.de` vhost, where Caddy
has to authenticate to the API on behalf of a browser that has no certificate of
its own.

Two things about the Incus side are not guessable:

- **A client is authorised by the fingerprint of the certificate it presents,
  not by who signed it.** So a *self-signed* client certificate is accepted once
  its fingerprint is in the trust store. That is what lets the instance
  authenticate without ever holding the server's CA key. Verified before
  building anything on top of it: a self-signed cert answered `200` on
  `/1.0/instances` where no cert got `403`.
- **`openssl` is not in the system PATH**, so `apply.sh` cannot compute a
  fingerprint — it gets `/run/current-system/sw/bin` and nothing else. The
  comparison is therefore made on certificate *content*:
  `incus config trust list` returns each entry's full PEM, so both sides are
  whitespace-stripped and compared. Matching against any entry's name rather than
  only the configured one is deliberate: a cert added by hand under a different
  name does not get a second, redundant entry.

### Incus CLI shapes that cost a round trip each

| command | shape |
| --- | --- |
| `incus config trust add-certificate` | `--name <name> <cert.crt>` — the name is a **flag**, and passing it positionally makes the CLI read it as a remote |
| `incus config trust remove` | takes the **fingerprint**, not the name; a name reports `Certificate not found` and removes nothing |
| `incus config trust list --format json` | each entry carries `certificate`, `fingerprint`, `name`, `type`, `projects`, `restricted` |
| `incus config get core.https_address --expanded` | `cannot be used with a server` |
| `incus query` | has no `--client-certificate`; to test mTLS, use `curl --cert/--key`, which is what Caddy will do anyway |

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
