# Forgejo — operating notes

Everything here is about *how this instance is put together*, and specifically the
parts that are not obvious from the Nix. The Nix explains what is configured;
this explains why, and what was measured to find out.

Read `default.nix` for the settings, `ssh.nix` for the git transport, and
`incus.nix` for volumes and the port forward. `../caddy/NOTES.md` covers the
proxy in front of this.

---

## The two accounts, and why there are two

The guest has `forgejo` and `git`. They are not interchangeable and conflating
them is the mistake this instance was rebuilt to avoid.

| | `forgejo` (uid 998) | `git` (uid 1000) |
| --- | --- | --- |
| runs | the web process, `serv`, the hooks | `serv`, the hooks — that is all |
| reads `SECRET_KEY` | yes | **no** |
| reads the database | yes, as role `forgejo` | **never** |
| reads `INTERNAL_TOKEN` | yes | yes — the one grant |
| is in group `git` | yes | — |
| home | `/var/lib/forgejo` | `/var/lib/forgejo` |

`git` is **not** in group `forgejo`. That membership used to be how it traversed
`/var/lib/forgejo`, and it was also the only thing keeping the rendered secrets
from it, since those are `0440` with group `forgejo`. Removing it is what makes
the boundary real; traversal is now granted a path at a time with `o+x` instead.

`forgejo` **is** in group `git`, which is load-bearing twice: it can read
`internal_token` at `root:git`, and it can write repositories that are
`git`-owned.

### What a push is allowed to reach

A push runs as `git`. It gets:

* its own config, `custom/conf/app-git.ini`
* `internal_token`, and nothing else
* `data/home/.gitconfig` and `data/home/hooks`, both group `git`
* every repository, via group write

It cannot read `SECRET_KEY`, `oauth2_jwt_secret`, `lfs_jwt_secret` or
`smtp_password`. It never touches postgres — there is no `git` database role, and
adding one would be a *larger* exposure than this one, because that role would be
able to read `user.passwd`, `user.salt` and the two-factor rows.

Every one of those modes is asserted by `forgejo-git-config` at the end of every
run, and again by `incus/apply-sshd-test.sh` against the built guest. If one of
them drifts, a unit fails rather than a push.

---

## Git over SSH

The host's own SSH is on **2222**. Port **22** is DNAT'd to this instance's
sshd, because `SSH_PORT=22` is what Forgejo puts in every clone URL and a git
transport that cannot move is the one thing that had to keep the port.

### The path a push takes

```
you  ->  192.168.178.200:22            (Incus DNAT, no socket listens on 22)
     ->  10.0.0.101:22   sshd         (in here; PasswordAuthentication=no)
     ->  AuthorizedKeysCommand         /run/forgejo-ssh-keys/keys, as root
     ->  forced command                forgejo serv key-<id> --config app-git.ini
     ->  the web process               /api/internal/serv/command/...
     ->  git-receive-pack
     ->  post-receive -> the web process again, to record the push
```

Two things about that are worth stating outright.

**sshd has to live in here.** `forgejo serv` refuses to run as anything except
`RUN_USER`, and `RUN_USER` is `git`, a guest account. The host's sshd has no such
account to authenticate. The check is in `LoadSettings`, so it fires for every
subcommand, and there is no override.

**The web process does the authorising.** `serv` does not talk to the database.
It asks the web process over `/api/internal`, which is mounted on the main
listener and gated by `INTERNAL_TOKEN` as a bearer token:

```
GET /api/internal/serv/none/13   no token -> 403  @ private/internal.go:23
GET /api/internal/serv/none/13   token    -> 200  @ private/serv.go:51
```

Key lookup, repository lookup and the permission check that decides whether the
key may *write* all happen in the web process, as `forgejo`. That is why `git`
needs no database role at all, and it is also why the one secret it does hold is
`tolerable`: `INTERNAL_TOKEN` cannot forge a session cookie, sign an LFS token,
or read the mailer password.

### `AuthorizedKeysCommand` cannot be a store path

It is a real file at `/run/forgejo-ssh-keys/keys`, installed at boot by
`forgejo-ssh-keys-install.service` with `Before=`/`WantedBy= sshd.service`.

Two things that look correct and are not:

* **The store path directly.** `/nix/store` is `1775`.
* **Anything under `/etc`.** `/etc/ssh/forgejo-ssh-keys -> /etc/static/... ->
  /nix/store/...`, and `auth_secure_path` resolves the link *before* walking up.
  Reasoning that it walks the lexical path is what made that look safe.

OpenSSH refuses either with a bare `Permission denied (publickey)` at
`LogLevel INFO` — nothing names the cause. Both were found on the host, not in
testing.

The script runs as **root**, and queries the database with `runuser -u forgejo`.
Both halves are required: `psql -d forgejo` as root is `role "root" does not
exist`, and `psql -U forgejo -d forgejo` as root is `Peer authentication failed`.
Either way the key list comes back empty, sshd reads that as "no keys
registered", and every push fails as a bare publickey denial with nothing logged.

---

## Two configs, and the one that matters

| file | for | mode |
| --- | --- | --- |
| `custom/conf/app.ini` | the web process | `0444 forgejo:forgejo` |
| `custom/conf/app-git.ini` | `serv`, running as `git` | `0600 git:git` |

### Both transports share one hook, so the hook chooses

The account that runs the hooks is not a choice; it follows from how the push
arrived. Measured in the guest:

| push | runs as | why |
| --- | --- | --- |
| `ssh://` | `git` | sshd's forced command, `forgejo serv key-<id>` |
| `https://` | `forgejo` | the **repository owner**; Forgejo authenticates the HTTP request |

So the hooks `sync_forgejo_hooks` writes select their config by account:

```bash
cfg=/var/lib/forgejo/custom/conf/app-git.ini
[ "$(id -un)" = forgejo ] && cfg=/var/lib/forgejo/custom/conf/app.ini
HOME=/var/lib/forgejo .../bin/forgejo hook --config "$cfg" post-receive
```

`id -un`, not `id -u 1000`: the hook carries no uid that has to be kept in step
with the guest's passwd file. Any account other than `forgejo` gets
`app-git.ini`, which is the safe default — the other way round would hand a
`RUN_USER=forgejo` config to a transport that cannot satisfy it.

**A hook that names one config is wrong for whichever transport does not own
it.** That was the HTTPS bug, and it is worth remembering why the symptom was so
misleading:

```
remote rejected  ... (pre-receive hook declined)
...permission denied on "/var/lib/forgejo/custom/conf/app-git.ini"
```

The message names a config path, not the account that could not read it, so it
reads as a permissions problem on the *git* config rather than "this transport
runs as somebody else". `forgejo` cannot open `app-git.ini` (it is `0600
git:git`), and every HTTPS push was declined at `pre-receive`.

The tempting fix — `chmod 0440 git:git` — is wrong. `forgejo` **is** in group
`git`, so it would then be able to read it, and `mustCurrentRunUserMatch()`
would immediately fatal on a `RUN_USER=git` config read by uid `forgejo`. One
failure traded for another, and the second is louder.

**What this preserves, and what it never protected.** A push over SSH runs as
`git` and reads only `INTERNAL_TOKEN`. HTTPS was never inside that boundary and
cannot be: Forgejo serves HTTPS as itself, so an HTTPS push is a privileged
operation by the service account, exactly like an API write. It is treated as
one.

Note that `app.ini` is `0444`, so `git` *can* read it — but it names four
`file:` URIs whose targets are `0440 root:forgejo`, so `serv` would die in
`loadSecret` on the first one. That is why `app-git.ini` exists rather than the
hooks simply pointing at `app.ini` everywhere.

`app-git.ini` is **generated at runtime** by `forgejo-git-config` from
`app.ini`, with two changes: `RUN_USER` becomes `git`, and every `*_URI` except
`INTERNAL_TOKEN_URI` is dropped.

It is derived rather than hand-written because the settings live in
`services.forgejo.settings`; a second copy of them is a second thing to rot.

Three details, each of which was a live failure first:

* **The filter is a filter**, not four deletions by name. The keys are
  `SECRET_KEY_URI`, `JWT_SECRET_URI`, `LFS_JWT_SECRET_URI` and `PASSWD_URI` — a
  list written from the four *secret names* deletes three of four, and `serv`
  still dies in `loadSecret`. Anything matching `*_URI` that is not
  `INTERNAL_TOKEN_URI` is dropped, so a secret added to `app.ini` later is
  withheld by default rather than leaked by omission. The unit then asserts which
  keys survived.
* **`git` owns it, `0600`.** `serv` *writes* this file — it saves its own oauth2
  JWT signing key into it on first use — so a read-only config is a fatal
  `loadOAuth2From`. This bit me during development: the config was `0444` root
  and the push died with `permission denied` on save.
* **`app.ini` is `0440`, not `0444`.** The older comment here claimed `0444` so
  `git` could read it. That is no longer needed and was not actually held — a
  Forgejo restart rewrites the file at `0440`, which is how the discrepancy
  surfaced.

### The `*_URI` settings are all `file:` URIs

Verified on the live instance, and asserted by `apply-sshd-test.sh`: every
`*_URI` is a `file:` path, none is an inline value, and there is no
`file:relative` form. That is what makes it safe for `app-git.ini` to exist at
all — the transport identity learns *paths*, and knowing a path is not being able
to open it. If someone later inlines `SECRET_KEY` into `app.ini`, that test fails
rather than handing the value to every account that can read a config.

---

## The hooks, and the push that "succeeded" but recorded nothing

`core.hooksPath` in `data/home/.gitconfig` points git at **`data/home/hooks`**,
not at each repository's own `hooks/`. Both sets exist; only the former runs.

That directory was `0750 forgejo:forgejo`, so as `git` every hook was skipped:

```
hint: The '<data>/home/hooks/post-receive' hook was ignored because
      it's not set as executable.
```

The push **reported success and the refs moved**. Nothing reached the database —
measured: the branch appeared in the `action` table **zero** times after a push
that git reported as fine. `post-receive` is what writes the activity feed, the
pull-request link and the size update. This is the same failure the reconciler's
`sync_forgejo_hooks` exists to prevent, one level up: a hook that silently does
nothing is worse than a hook that is missing.

It is now `group git` with `g+rX`, and the unit re-asserts it every run.

### `HOME` is not what the passwd entry says

`commonBaseEnvs()` in v16.0.5 sets `HOME=<APP_DATA_PATH>/home` for the git
subprocess, overriding the account's home directory. So the global gitconfig a
push actually reads is `data/home/.gitconfig`, not `/var/lib/forgejo/.gitconfig`.

Getting this wrong looks like a git bug and is not:

```
fatal: detected dubious ownership in repository at '.../homelab.git'
```

That is git's ownership check, because it never saw `safe.directory = *` — which
is in `data/home/.gitconfig`, in a directory it could not read. Repositories are
`forgejo:git`, so the push needs that exception to touch them at all. Verified by
running `update-server-info` as `git` with and without read access.

---

## Rollback, and what it is not

Both data volumes carry a snapshot policy in `incus.nix`:

| volume | pool | schedule | expiry |
| --- | --- | --- | --- |
| `forgejo-data` | `backup` | `@daily` | `7d` |
| `forgejo-postgres` | `persistent` | `@daily` | `7d` |

It lives on the volume's own entry rather than in a list with the other backup
settings, because that is what makes it travel: when Minecraft finishes moving
out of k3s, its volume entry declares its own policy and there is no global list
to remember to update. Omit `snapshots` and the volume is simply never scheduled.

`incus/apply.sh`'s `ensure_volumes` reconciles both keys in **both**
directions — including clearing them, so removing `snapshots` from the entry is
how a volume stops being snapshotted. That direction was the one that had a bug
in it: the API read was originally skipped when the spec declared nothing to
set, which is exactly backwards, because a spec that says nothing is the case
where the volume may carry a schedule that has to be cleared. `forgejo-secrets`
and `forgejo-runner-data` have no `snapshots` block and must stay unscheduled —
a snapshot of a live API token or a runner cache is a liability, and both are
rewritten from the host's own secrets on every reconcile anyway.

### What a snapshot actually is

An Incus snapshot on a btrfs pool is a subvolume that shares every extent with
the live volume and differs only in the blocks written since. Nothing is walked,
nothing is read while Forgejo is running, and the copy is instantaneous.

That is what makes `forgejo-postgres` snapshottable at all, and it corrects an
earlier comment in `incus.nix` that said the opposite. The old argument was that
a live PGDATA copied mid-write is a corrupt PGDATA directory — true of a file
copy, irrelevant to a snapshot. So the old conclusion was right for the wrong
reason: **this is a rollback layer, not a substitute for `pg_dump`.**

Crash-consistent is not clean. A restored `forgejo-postgres` runs WAL recovery
on first start, which is what you want and is not free of risk. There is still
no `pg_dump` in this repository, and that is a separate decision rather than an
oversight: a dump cannot restore the instance if the host is lost, and a snapshot
cannot be restored onto a different PostgreSQL major or read without booting it.
If a dump is wanted it belongs *beside* the snapshot.

### Verifying it, and the limit of that verification

`./incus/apply-snapshots-test.sh` covers the reconciler against a stubbed `incus`
— that the schedule is written, that a hand-edited value is put back, that an
already-correct volume produces no write at all (the fifteen-minute timer makes
that worth testing), that omitting the spec clears, and that `expiry` is
validated.

It cannot prove a snapshot is restorable, because a stub has no snapshots. Two
things are needed for that, and only one is automatable:

1. **A real restore, against `caddy-data`.** It is 360K, so
   `incus storage volume snapshot restore` on it costs seconds and destroys
   nothing. Do this once after deploying.
2. **Presence and size on `forgejo-data`.** Its snapshot cannot be restored over
   the running instance, so the check is a file count and total bytes against the
   source subvolume. That is weaker than a restore, and it is the same weakness
   that let 57 broken restic snapshots report as intact — `restic ls` walks trees
   and cannot see a missing blob.

One `7d` window, on one disk. The pool is on `/dev/sda1` and these snapshots
share it, so an SSD failure takes the rollback points with the data. Replication
is the answer and it does not exist yet; until it does, `forgejo-data` has a
rollback point and no off-box copy.

## What still needs your attention

**The snapshot policy has not been exercised on a live Incus.** The reconciler is
tested against a stub and the Nix evaluates, but no snapshot has been taken on
this host under the new schedule. `incus storage volume list` will show the
schedule set and nothing more.

**`forgejo-data` has no off-box copy.** See above.

**k3s is still deployed** and still serving git on `:30022`. Nothing should depend
on it now that `:22` works, but it has not been retired.

**`internal_token` reaches `/api/internal`**, which is on the same listener as
the web UI and is reachable from the host at `10.0.0.101:3000`. `PROTOCOL=http`
with `HTTP_ADDR=0.0.0.0`. Moving that surface off TCP — `PROTOCOL=http+unix`,
or a loopback-only bind with Caddy reaching it another way — would remove the
one real cost in the boundary above. Not done: it changes how Caddy dials Forgejo,
and that needs deciding first.

### Fixed since these notes were written

`incus-reconcile.service` used to fail every 15 minutes on caddy:

```
caddy ERROR: this build is already in the pool under no alias and carries no
user.build-source, so it cannot be identified
```

`--all` died before it reached forgejo, so the safety net was the thing that was
broken. `per_instance_metadata` in `incus/apply.sh` now repacks the metadata
tarball per instance, which is what stops two images sharing a fingerprint.

A second defect in the same function, found later: it wrote the repacked tarball
**into the directory it was tarring**, so the archive sometimes listed itself and
the resulting fingerprint was not reproducible. That is the likely source of the
duplicated images the weekly `incus-image-gc` cleans up.