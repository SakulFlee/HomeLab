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
| `custom/conf/app.ini` | the web process | `0440 forgejo:forgejo` |
| `custom/conf/app-git.ini` | `serv`, running as `git` | `0600 git:git` |

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

## What still needs your attention

**k3s is still deployed** and still serving git on `:30022`. Nothing should depend
on it now that `:22` works, but it has not been retired.

**`incus-reconcile.service` fails every 15 minutes** on caddy:

```
caddy ERROR: this build is already in the pool under no alias and carries no
user.build-source, so it cannot be identified
```

`--all` dies before it reaches forgejo, which is why two broken deploys looked
healthy for a while: the safety net that was supposed to catch them was the thing
that was broken.

**`internal_token` reaches `/api/internal`**, which is on the same listener as
the web UI and is reachable from the host at `10.0.0.101:3000`. `PROTOCOL=http`
with `HTTP_ADDR=0.0.0.0`. Moving that surface off TCP — `PROTOCOL=http+unix`,
or a loopback-only bind with Caddy reaching it another way — would remove the
one real cost in the boundary above. Not done: it changes how Caddy dials Forgejo,
and that needs deciding first.