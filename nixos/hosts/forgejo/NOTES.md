# Forgejo — operating notes

Everything here is about *how this instance is put together*, and specifically the
parts that are not obvious from the Nix. The Nix explains what is configured;
this explains why, and what was measured to find out.

Read `default.nix` for the settings, `ssh.nix` for the git transport, and
`incus.nix` for volumes and the port forward. `../caddy/NOTES.md` covers the
proxy in front of this.

---

## One account

The guest has `forgejo`, and only `forgejo`. There used to be a second account,
`git`, that pushes arrived as, with its own config and a permission boundary to
match — that design is in git history. What follows describes the current
single-user setup; the history is referenced where a present-tense statement
would otherwise look arbitrary.

| | `forgejo` |
| --- | --- |
| runs | the web process, `serv`, the hooks — everything |
| reads `SECRET_KEY` | yes |
| reads the database | yes, as role `forgejo` |
| reads `INTERNAL_TOKEN` | yes |
| home | `/var/lib/forgejo` |

The consequence, stated plainly rather than discovered later: every push runs
with an identity that reads all five secrets. Custom git hooks are disabled by
default (verified against the pinned Forgejo source), so a push cannot install
code that reads them; the remaining exposure is a serv-layer vulnerability
reached with a stolen key. That trade was accepted explicitly when the accounts
were collapsed — the alternative was the dual-user machinery back, in full.

What stays true: no *other* account on this box reads these files, and the
0440 root:forgejo on all five secrets is load-bearing, not decorative.

### What a push is allowed to reach

A push runs as `forgejo` and can read everything `forgejo` can, which is
everything on this box that matters: the five secrets, the database role, the
repositories. It never touches postgres *as a transport* — there is no `git`
database role and never was one; adding one would hand the push identity SELECT
on `user`, which holds passwd, salt and the two-factor rows. That reasoning
survives the collapse unchanged: the transport needs no database access because
the web process does all authorising over `/api/internal`.

The modes below are what they are because there is only one reader left to
reason about. If one of them drifts, nothing fails loudly anymore — there is no
unit asserting them, by design: with a single identity the failure they used to
catch (one transport locked out) cannot occur.

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
     ->  forced command                forgejo serv key-<id> --config app.ini
     ->  the web process               /api/internal/serv/command/...
     ->  git-receive-pack
     ->  post-receive -> the web process again, to record the push
```

Two things about that are worth stating outright.

**sshd has to live in here.** `forgejo serv` refuses to run as anything except
`RUN_USER`, and the check is in `LoadSettings`, so it fires for every
subcommand, and there is no override. The host has no `forgejo` account to
authenticate against, so the session must originate in this container.

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

## One config

| file | for | mode |
| --- | --- | --- |
| `custom/conf/app.ini` | the web process and `serv` | `0440 forgejo:forgejo` |

One `RUN_USER`, one account executing, one config. There used to be a second
file, `app-git.ini` -- the same settings with `RUN_USER=git` and every
`*_URI` except `INTERNAL_TOKEN_URI` dropped, derived at runtime by a unit that
no longer exists. It existed because pushes arrived as a different account
than the web process, and a single config cannot satisfy two `RUN_USER`
values. With one account the problem it solved does not occur.

The HTTPS failure below is kept because the symptom is otherwise
unrecognisable -- but note it cannot happen anymore. There is no second
transport identity for a message to misname:

```
remote rejected  ... (pre-receive hook declined)
...permission denied on "/var/lib/forgejo/custom/conf/app-git.ini"
```

That was a push over HTTPS running as `forgejo` against hooks naming a
`0600 git:git` config only `git` could open. Same file, same account now: a
permissions failure here would name a file this account genuinely cannot
read, which means the mode above drifted and not that the wrong account
arrived.

### The `*_URI` settings are all `file:` URIs

Verified on the live instance: every `*_URI` is a `file:` path, none is an
inline value, and there is no `file:relative` form. No suite asserts this
anymore -- the check lived in the git-config unit's assertions, which went
away with it -- so it is stated here instead of tested: if someone later
inlines `SECRET_KEY` into `app.ini`, nothing fails loudly, and the value sits
in a file every process in this container is allowed to read.
---

## The hooks, and the push that "succeeded" but recorded nothing

`core.hooksPath` in `data/home/.gitconfig` points git at **`data/home/hooks`**,
not at each repository's own `hooks/`. Both sets exist; only the former runs.

That directory was once `0750 forgejo:forgejo` while pushes arrived as a
different account, so every hook was skipped:

```
hint: The '<data>/home/hooks/post-receive' hook was ignored because
      it's not set as executable.
```

The push **reported success and the refs moved**. Nothing reached the database --
measured: the branch appeared in the `action` table **zero** times after a push
that git reported as fine. `post-receive` is what writes the activity feed, the
pull-request link and the size update. A hook that silently does nothing is
worse than a hook that is missing, and nothing in that output says so.

With one account the mode problem is gone -- Forgejo writes these files as
itself and runs them as itself. What remains is the binary path: the hooks
name `/nix/store/.../bin/forgejo` absolutely, so a nixpkgs bump breaks all of
them until something rewrites the paths. That something is stock: the module
runs `admin regenerate hooks` in `preStart`, on every service start. There
used to be a reconciler sweep doing the same job for a two-config dispatch
that no longer exists; stock covers the single-config case on its own.

### `HOME` is not what the passwd entry says

`commonBaseEnvs()` in v16.0.5 sets `HOME=<APP_DATA_PATH>/home` for the git
subprocess, overriding the account's home directory. So the global gitconfig a
push actually reads is `data/home/.gitconfig`, not `/var/lib/forgejo/.gitconfig`.

Getting this wrong looks like a git bug and is not:

```
fatal: detected dubious ownership in repository at '.../homelab.git'
```

That is git's ownership check, because it never saw `safe.directory = *` -- which
is in `data/home/.gitconfig`, in a directory it could not read. Repositories
are `forgejo:forgejo`, so the exception is about the directory being reachable
at all rather than about whose files these are.

---

## Rollback, and what it is not

Both data volumes carry a snapshot policy in `incus.nix`:

| volume | pool | schedule | expiry |
| --- | --- | --- | --- |
| `forgejo-data` | `persistent` | `@daily` | `7d` |
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
last network-reachable use of a bearer token on this box. (The old text
said "the one real cost in the boundary above" -- that boundary, the
dual-user split, is gone; the surface is not.) Not done: it changes how Caddy dials Forgejo,
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