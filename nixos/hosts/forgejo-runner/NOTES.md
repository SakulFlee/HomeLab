# Forgejo runner — operating notes

Everything here is about *how this instance is put together*, and
specifically the parts that are not obvious from the Nix. The Nix
explains what is configured; this explains why, and what was
verified to find out.

Read `default.nix` for the guest and `incus.nix` for the Incus half
(limits, the single root disk, the network device and the rendered
secrets). There is no data volume any more; the runner's state, cache
and workspaces live on the root disk.

---

## What this replaced

The k3s deployment (`apps/forgejo-runner/`, the eleboucher
forgejo-runner Helm chart) ran the runner as a pod whose jobs were
**k8s pods**: the chart's `plugin.k8s` section spawned one pod per
job from a podspec. That plugin is gone. This instance runs the
runner natively in a VM with the **Docker executor**: every job is a
container, created by a dockerd running inside the VM, from the image
the job's label names.

The two arrangements are equivalent from a workflow's point of view
— every label here names a job image, as every podspec did — but
the Docker executor needs no Kubernetes API, no service account,
no podspecs to maintain, and no cluster to exist. It is also the
executor the Forgejo runner is built around: the `docker://` label
scheme is a built-in, not a plugin.

## Why a VM

The repo's rule is LXC unless something needs `security.privileged`,
in which case VM. This needs it: the runner executes arbitrary code
from the Marketplace, and the Docker executor does that by running a
container runtime *inside* the instance. An LXC shares the host
kernel, so a dockerd inside it would have to run privileged — handing
the guest the host kernel, which is the thing the rule refuses. A VM
brings its own kernel, runs its own dockerd, and a job container is
then as isolated from the host as Docker makes it. The same argument
is spelled out for the WireGuard VM in `incus/README.md`.

## Registration: credentials, not a registration token

The runner identifies itself to Forgejo with a **uuid and a token**
in the config's `server.connections` section. These are the runner's
*persistent* credentials, issued once by Forgejo when the runner was
created (Site Admin → Runners → Create, which displays both exactly
once). They are not a registration token:

* nothing is consumed by presenting them — the daemon presents them
  on every poll, forever;
* nothing re-registers, so nothing can fail to re-register;
* the `forgejo-runner register` subcommand still exists but is
  deprecated upstream (`register` logs "has been deprecated; declare
  connections in the runner configuration instead"), and the daemon
  in v13 requires `server.connections` — it exits with
  `runner: 0 server connections configured, terminating` without them.

That shape is what makes this work on an immutable image. The
credentials are rendered into the instance by `apply.sh` (from the
host's sops store) and embedded into a generated `config.yaml` by
`forgejo-runner-config.service`; they are never baked into the image,
and a re-create loses nothing because the host re-renders them from
sops. The cache and workspaces are lost on a re-create, but they are
regenerable. The registration-token flow the nixpkgs `services.gitea-actions-runner`
module uses would be the wrong shape here: its token is single-use,
its registration state lives in the guest's StateDirectory (the root
disk, which a re-create replaces), and re-registering after a re-create
would fail with the consumed token.

**The identity is this VM's own.** The runner was created
fresh in the Forgejo UI for the Incus VM, and `nixos/secrets.yaml`
holds its uuid and token. Verified on the first real job: the daemon
answered `Declare` and launched its poller.

It was originally the *k3s* runner's identity, carried over on the
argument that reusing it was free — nothing re-registers, so a
re-create loses nothing. That was true and it was the wrong call.
The k3s runner's registered name describes a platform this runner no
longer uses, so every job log line read as though Kubernetes were
still involved, and one runner entity ended up with a history
spanning two execution models: the k3s plugin's pods, and now Docker
containers. Those are different things, and a runner's history is
exactly the record you would want to be able to distinguish when
debugging which one ran a job.

The *shape* of the credentials did not change and is the part worth
keeping: a persistent uuid and token, presented on every poll, never
consumed, nothing to re-register. See "Registration" above for why
that matters on an immutable image.

The name is whatever was chosen when the runner was created, because
the config sends only `uuid` and `token` — nothing in this repository
carries it. Read it from the daemon's log if you need it:

```
incus exec forgejo-runner -- journalctl -u forgejo-runner -o cat | grep -m1 'runner:'
```

The old k3s runner is still registered in Forgejo, still carrying the
three Docker labels it used. Its credentials are no longer in this
repository, so it cannot start — but it is offline and harmless, and
deleting it in the UI would lose the k3s-era job history.

### The Declare RPC updates the runner's labels

The daemon declares its labels to Forgejo at every start (the
`Declare` RPC, `createRunner` in the runner's `daemon.go`), and
Forgejo matches pending jobs against the **declared** labels, not
against anything stored at registration time. Two consequences:

* Changing the labels in `default.nix` takes effect on the next
  daemon start — which, because the labels live in the guest's
  generated config, means an image change and a re-create. They are
  declarative, not hand-editable: `apply.sh` rewrites `config.yaml`
  from the template whenever the rendered secrets change, so an edit
  to the file on the root disk would not survive the next reconcile.
* The last daemon to declare wins. During the cutover (below), do not
  run the k3s runner and this VM against the same Forgejo: two
  daemons with one uuid each declare their own labels and steal each
  other's jobs.

## What lives where

| where | contents | survives a re-create? |
| --- | --- | --- |
| root disk | the NixOS system, `/nix/store`, dockerd's image store (`/var/lib/docker`), the runner's `config.yaml` and rendered secrets, the actions cache and job workspaces | **no** — all of it is regenerable |

The root disk is **100 GiB**, declared as `rootDiskSize` in `incus.nix`
and applied as the `root` disk device's size. It is deliberately not baked
into the image: the image is assembled inside a 128 MB VM (qemu's default;
`make-disk-image.nix` passes no `-m`) and a 45 GiB ext4's metadata does
not fit, so the guest panics before the build finishes. The guest grows its
partition and filesystem into whatever disk Incus gives it
(`autoResize`/`growPartition`), so the image stays small and the capacity
comes from Incus.

The artifact cache is the dominant consumer. The Orbital workflows save
multi-gigabyte sccache/cargo entries under keys that change with
`Cargo.lock`; at the observed 12-15 GiB/day, 100 GiB is roughly the
seven-day retention window. The cache guard in `default.nix` wipes the
cache when free space drops below 10 GiB.

A re-create replaces the root disk, so the cache, workspaces, Docker images
and the rendered secrets are all lost. That is acceptable: the host
re-renders the secrets from sops, the runner reconnects with its persistent
uuid/token, and the first jobs rebuild their caches. There is no data volume
to preserve.

Docker's image store is on the same disk. Images are re-pullable by
definition; the daily `forgejo-runner-prune.timer` now prunes unused
images, stopped containers, unused volumes and build cache to keep that
side bounded.

## The generated config

`forgejo-runner-config.service` (a oneshot, `RemainAfterExit`) reads
the two rendered secret files and writes `/var/lib/forgejo-runner/config.yaml`
— atomically (`config.yaml.new` + `mv`), and only when the content
actually changed, so a settled redeploy touches nothing. The config is
`0400 forgejo-runner`: the daemon reads it, and the daemon runs as
the `forgejo-runner` user, not root. The raw secret files themselves
stay `0400 root:root` — the only reader is the generator, which runs
as root and embeds both values into the config.

The generator **fails** when the secrets are absent. That is the
caddy pattern and it is deliberate: on the first deploy the instance
comes up before `apply.sh` has rendered anything, the generator fails,
the daemon stays down, and `apply.sh` then renders the secrets and
restarts both units (they are the instance's `secretConsumers`, in
order: generator first, daemon second). A runner that started
without credentials would poll Forgejo, fail authentication forever,
and look like a network problem.

## Networking

* `eth0` on `incusbr0`, static `10.0.0.102/24`, configured **in the
  guest** (Incus can hand a container a static address; it cannot
  configure a guest's network). The guest matches on the NIC's MAC,
  which `incus.nix` pins (`00:16:3e:00:00:12`) so the address
  survives a re-create — an Incus-assigned MAC would not.
* Egress (image pulls, the actions cache upstream) is NAT'd by
  `incusbr0`'s `ipv4.nat`, via the default route `10.0.0.1` (the
  host).
* DNS is the router (`192.168.178.1`), which is what the host itself
  resolves through. Not the host's CoreDNS (`192.168.178.200`): that
  is a k3s pod today and dies with the cluster, while the router does
  not. The runner only needs public names (docker registries);
  split-horizon names resolve through the Cloudflare wildcard either
  way.
* Forgejo is reached at `http://10.0.0.101:3000` — the Incus
  instance's address on the same bridge, one hop, with nothing
  between here and Forgejo (Caddy, DNS, Cloudflare) on the critical
  path. If the runner ever moves off `incusbr0`, this is the value to
  change (`forgejoUrl` in `default.nix`).
* **No Incus forward points at this VM**, and none should: the runner
  polls Forgejo outbound and listens for nothing. The LAN cannot reach
  it, which is part of the posture, not an omission.

### No guest firewall

`networking.firewall.enable = false` in the guest, and that is a
conclusion rather than an oversight. The instance has nothing to
protect *from* on the networks it sits on: nothing from the LAN (no
forward, no route in from `192.168.178.0/24`), and the only inbound
traffic is from the VM's own Docker bridges — job containers reaching
the actions cache proxy, which listens on a random port
(`cache.proxy_port = 0`) precisely so that it cannot be predicted, and
which is meant to be reachable by exactly those containers. A firewall
would do one thing only: drop that random port, which cannot be
allow-listed. `trustedInterfaces = [ "docker0" ]` would cover the
default bridge but not the per-job network the runner creates, whose
name is not knowable at build time. The VM boundary is the isolation;
the guest firewall would add noise, not safety.

## Labels and job images

Four labels. Three are Docker labels naming the same image, so nothing that
runs on `default`, `ubuntu-latest` or `ubuntu-24.04` has to change:

```
default:docker://ghcr.io/catthehacker/ubuntu:act-24.04
ubuntu-latest:docker://ghcr.io/catthehacker/ubuntu:act-24.04
ubuntu-24.04:docker://ghcr.io/catthehacker/ubuntu:act-24.04
docker:host
```

`docker:host` is the host executor: the job runs in a shell forked from the
daemon on the VM, not in a container. It is for image builds, which need the
VM's Docker daemon because buildah cannot run in an unprivileged job
container (it needs `CAP_SYS_ADMIN` or a user namespace, and the Docker
executor grants neither).

The `nix` label deliberately does not exist here. The NixOS-Config
flake-lock gate builds the host configuration on a dedicated host runner
on the HomeLab host (`nixos/hosts/homelab/services/forgejo-nix-runner.nix`)
with the host's own Nix store; keeping it out of this VM is what allows the
VM to be a single 100 GiB disk instead of carrying the ROCm/llama.cpp
closure.

**Why this image and not `node:22-bookworm`.** The k3s podspec ran
`node:22-bookworm`, and that was the first choice here too: it carries
node, npm, bash, git, curl and wget, which covers what most
Marketplace actions need inside the job container (the actions
themselves are Node scripts executed there).

It is not enough for the ones that shell out to a real distro. A step
that runs `python3`, `jq`, or `docker build` finds none of them, and
the failure is a job that dies on a missing binary rather than anything
that names the image. `catthehacker/ubuntu:act-24.04` is a full Ubuntu
with the tooling act-based runners are expected to have, including
the Docker CLI — and a `docker build` step is common enough in this
repos' workflows to be worth it.

It is a **third-party image**. It is not a Forgejo or GitHub base; it
is the image the local `act` ecosystem converges on, and it is
maintained by one person rather than a distribution. That is a
conscious choice for closer parity with hosted runners, not a
default, and it is the kind of thing worth revisiting if a job ever
misbehaves in a way that does not reproduce on `node:22-bookworm`.

**Size.** Measured from the registries, linux/amd64, compressed:
`act-24.04` is 0.54 GiB over 6 layers against `node:22-bookworm`'s
0.38 GiB over 8. Docker stores layers uncompressed, so on disk it is
roughly 2.2 GiB against 1.4 GiB. That is paid once per VM, not per
job, and `forgejo-runner-prune.timer` bounds the accumulation.

A workflow can still override the image per job with
`jobs.<job_id>.container`. Labels are per-connection in the config,
so a second connection with its own labels is also possible
(`server.connections.<name>.labels`) — which is the cheap way to offer
both images: keep `default` on the full Ubuntu and put a
`node:22-bookworm` label on a second connection for jobs that want it.

## The security boundary

What a *container* job can do: pull images, run containers, and reach the
internet through the VM's NAT. What it cannot do, by configuration:

* **mount host paths** — `container.valid_volumes: []` means no volume
  or bind mount a workflow declares is honoured; the job fails instead.
  The k3s podspec had the same posture (no volumes, no service-account
  token). Widen with care; `valid_volumes: [ "**" ]` allows any mount.
* **reach the Docker socket** — `container.docker_host: "-"`, so job
  containers get no `/var/run/docker.sock`. An image build uses the
  `docker:host` label instead; it runs on the VM, where the daemon is
  already reachable.
* **run privileged** — `container.privileged: false`. Buildah needs
  `CAP_SYS_ADMIN` (or a user namespace) and therefore cannot run in one of
  these containers; that is why builds moved to `docker:host` rather than
  weakening this default.

The daemon itself runs as the `forgejo-runner` user (in the `docker`
group — it needs the socket, and the containers it creates run as root
inside their own namespaces regardless of the runner's uid), with
`NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=strict` and a single
`ReadWritePaths` — the root disk. The k3s deployment ran the runner
as root because the pod needed the socket; a VM can do better.

Host-executor jobs (`docker`) are the deliberate exception. They run
as `forgejo-runner` directly on the VM, so they can use the Docker socket,
read the root disk (including the generated `config.yaml`, which holds
the runner token), and are not subject to `valid_volumes` or
`docker_host: "-"`. That label is for trusted repositories only; ordinary
jobs stay on the `docker://` labels.

## Capacity and timeouts

The config declares `capacity: 2` concurrent jobs, `timeout: 4h`, and
`shutdown_timeout: 3m` (the daemon drains running jobs within this on
TERM). The VM's limits are 12 CPU and 12 GiB (`incus.nix`); the Nix
host-build closure moved to the host runner, so that memory is for Docker
jobs, dockerd and the artifact cache. It is a cap, not a reservation.

The host has **16 cores and 30 GiB**, of which roughly 16 GiB is
available with everything else running. That leaves real room to raise
`capacity` if the queue ever backs up, and the reason to keep 4 for
now is parity with what k3s did rather than a resource limit — a
regression in job behaviour would be easier to read as "we changed the
platform" if capacity had moved at the same time.

The actions cache is enabled (`cache.enabled: true`, the k3s
deployment had it too): workflows that use the
`actions/cache` action are given a one-time `ACTIONS_CACHE_URL`
pointing at a proxy the runner spawns, which talks to the cache
server over a shared secret. The cache directory lives on the root disk,
which is re-created, so cached artefacts do not survive that. The proxy's
host address is
auto-detected; job containers reach it through their bridge's gateway,
which is the VM, and the VM accepts packets addressed to its own
address regardless of which interface they arrive on — the same
hairpin the WireGuard VM's routing relies on.

## Cache growth and the guard

There are two caches, and they are not the same thing:

* `$HOME/.cache/act` is the per-job checkout cache: bare repositories for
  actions fetched from `data.forgejo.org`, with a worktree created per job.
  It has no automatic GC, but it is small.
* `/var/lib/forgejo-runner/home/cache` is the artifact cache served by the
  runner's embedded cache server for `actions/cache`. Its contents are the
  multi-gigabyte archives the workflows save (sccache, cargo registry).
  `bolt.db` is only the index; the `cache/` subdirectory holds the blobs.

The runner's GC (`act/artifactcache/caches.go` in v13.2.0) is age-based, not
size-based. It removes incomplete uploads unused for 5 minutes, entries
unused for 7 days, entries created more than 30 days ago, and older
duplicates of the same key+version (keeping the newest). It runs at most
once per hour. There is no total cap or LRU, so a workflow that creates a
new key per `Cargo.lock` can outrun the 7-day retention.

That is what happened on 2026-10-24: the then-separate data volume was 100%
full, the journal showed `no space left on device` on cache writes, and the
next job failed in "Set up job" because `git worktree add` could not write
its checkout. The cache held 28 GiB of 30 GiB. Wiping only the artifact cache
(`home/cache/cache` and `home/cache/bolt.db`) while the runner is stopped is
safe: it is regenerable, and no secret, config or workspace is touched.

`forgejo-runner-cache-guard` (`default.nix`) is the safety valve. Every 15
minutes it checks free space on the root disk; below 10 GiB it stops the
runner, refuses to proceed if the stop did not take, removes the artifact
cache blobs and index, and starts the runner again. It is a last resort, not
a substitute for sizing: at 100 GiB it will likely fire roughly every five
to seven days at the current churn. Raising the disk later is one-way.
Lowering `SCCACHE_CACHE_SIZE` is not the lever here -- it shifts the cost
into `target/` and slows builds; fewer unique cache keys would help, but the
guard is what keeps the disk from filling in the meantime.

## Host Nix runner

The NixOS-Config flake-lock gate no longer runs in this VM. It runs on a
separate Forgejo runner on the HomeLab host, defined in
`nixos/hosts/homelab/services/forgejo-nix-runner.nix`. It declares only
`nix-rebuild:host`, has capacity 1, has the artifact cache disabled, and
uses the host's own Nix store. The workflow in NixOS-Config uses
`runs-on: nix-rebuild`.

The runner's uuid and token are in HomeLab's `nixos/secrets.yaml` as
`forgejo_nix_runner_uuid` and `forgejo_nix_runner_token`. The
`forgejo-nix-runner-config` oneshot reads those sops secrets and writes
`/var/lib/forgejo-nix-runner/config.yaml` (`0400 forgejo-nix-runner`) with
`server.connections`; it also removes any manual `.runner` file, because
`FromRegistration()` refuses to combine a `.runner` file with
`server.connections`. The daemon starts after the generator.

The token is not shown in the Forgejo UI after runner creation. The initial
values came from the one-time `.runner` file written by
`forgejo-runner register`; they are now the sops secrets. If the runner is
deleted and recreated, update both sops values and let the host rebuild.
There is no one-time manual registration command any more.

The sops secrets are owned by `forgejo-nix-runner`, mode `0400`; the config
generator (root) reads `/run/secrets` and writes the config the daemon
reads. Their `restartUnits` restart the generator and the daemon on
rotation. The host's daily `nix.gc` (`nixos/modules/gc.nix`) collects the
unrooted Dendra build outputs.

**Security.** A host-executor job runs its shell steps as
`forgejo-nix-runner` on the host. The label limits which jobs this runner
picks up, but Forgejo labels are not repository-scoped: any workflow that
can request `nix-rebuild` can run here. Keep it to trusted repositories and
protect workflow files; the VM remains the isolation boundary for Orbital
PRs.

## Cutover from k3s

The two deployments poll **different Forgejos**, so they cannot
steal each other's jobs: the k3s runner polls a Service in the k3s
cluster that no longer has a Forgejo behind it, and this VM polls the
Incus one (`10.0.0.101`). The k3s runner is gone from the repository
— `apps/forgejo-runner/`, `clusters/homelab/apps/forgejo-runner.yaml`
and `forgejo-runner-secrets.yaml` are all removed — so the hazard the
cutover section used to guard against is closed by construction rather
than by remembering not to point two runners at one instance.

Deploy and verify:

1. From `nixos/`, run
   `nix build .#nixosConfigurations.forgejo-runner.config.system.build.toplevel`
   — the image has to evaluate before anything is worth deploying. This is the
   check that catches the failure mode NixOS gives no other warning about: an
   option name that does not exist is accepted when the module is read and only
   fails when `system.build.toplevel` is forced, which is to say at build time.
   See the notes in this file's sibling, `default.nix`, for the two real
   instances of it.
2. Deploy with Tofu: `incus/gen-tf.sh`, then
   `tofu -chdir=incus/infra plan -out=deploy.tfplan` and
   `tofu -chdir=incus/infra apply deploy.tfplan`. The image change replaces
   the instance with the 100 GiB root disk; the data volume is gone, so the
   cache and workspaces start cold. The host auto-updater blocks volume
   deletion, so this plan must be reviewed and applied manually.
3. `docker.service` exists in the guest. `forgejo-runner.service`
   *Requires* it and the daemon exits if the socket is not reachable,
   so a missing dockerd shows up as a runner that never declares
   rather than as a broken container. Check it before anything else:
   `incus exec forgejo-runner -- systemctl is-active docker`.
4. The daemon's own account can write its own home. This is the
   check that would have caught the first job failing, and nothing
   above it notices: the units all report success while the runner is
   silently unable to create a directory.
   ```
   incus exec forgejo-runner -- runuser -u forgejo-runner -- \
     mkdir -p /var/lib/forgejo-runner/home/.cache/probe && rmdir /var/lib/forgejo-runner/home/.cache/probe
   ```
   A bare `systemctl is-active forgejo-runner` proves the daemon
   started, not that it can work.
5. The root disk is the only disk and has grown to 100 GiB:
   `incus exec forgejo-runner -- df -h /` and
   `incus exec forgejo-runner -- lsblk`. There is no
   `/var/lib/forgejo-runner` mount to check; the runner's state is a normal
   directory on `/`.
6. In the Forgejo UI (Site Admin → Actions → Runners), confirm the VM
   runner is online with the four labels (`default`, `ubuntu-latest`,
   `ubuntu-24.04`, `docker`). The host Nix runner is a separate entry with
   only `nix-rebuild`.
7. Submit a workflow that runs on `ubuntu-latest` and watch it execute
   here: `incus exec forgejo-runner -- journalctl -u forgejo-runner -f`
   shows the job being fetched, the image pulled and the container
   created.

If the runner does not come up, the two places to look first:
`journalctl -u forgejo-runner-config` (the generator — it fails by
design until the secrets are rendered, and again on any syntax error
in the template) and `incus exec forgejo-runner -- ls -la
/var/lib/forgejo-runner` (the root disk, the secrets rendered, the config
present at `0400 forgejo-runner`).

## Verification

```bash
incus exec forgejo-runner -- systemctl status forgejo-runner
incus exec forgejo-runner -- docker ps  # job containers, while a job runs
incus exec forgejo-runner -- df -h /
tofu -chdir=incus/infra plan            # must be clean
```

The runner declares itself at every start, so the fastest check that
the credentials still work is the daemon's own log: a line reading
`runner: <name>, with version: v13.2.0, with labels:
[default ubuntu-latest ubuntu-24.04 docker], ephemeral: false, declared
successfully` followed by `[poller] launched`.

## Disk sizing

The VM has a single **100 GiB** root disk, declared as `rootDiskSize` in
`incus.nix` and applied as the `root` disk device's size. It holds the NixOS
closure, `/nix/store`, the Docker image store, the runner's state, the
artifact cache and the job workspaces.

The size is driven by the artifact cache, not the OS. The Orbital workflows
save multi-gigabyte sccache/cargo entries under keys that change with
`Cargo.lock`; at the observed 12-15 GiB/day, 100 GiB is roughly the
seven-day retention window. The cache guard in `default.nix` wipes the
artifact cache when free space drops below 10 GiB, so a burst cannot fill
the disk and break job setup.

The host-side Nix builds (the NixOS-Config flake-lock gate) no longer run
here. They run on a dedicated host runner on the HomeLab host
(`nixos/hosts/homelab/services/forgejo-nix-runner.nix`) with the host's own
Nix store. That is why this disk does not need to carry the ROCm/llama.cpp
closure; the VM only builds its own system and runs the Docker jobs.

The image itself stays small: it is assembled inside a 128 MB VM
(`make-disk-image.nix` passes qemu no `-m`), and a 45 GiB ext4's metadata
does not fit, so the build panics before `cptofs` finishes. The guest grows
its partition and filesystem into whatever disk Incus gives it
(`autoResize` / `growPartition`). The qcow2 stays sparse, so the size costs
nothing on the host while unused.

`incus config set <vm> limits.disk.size` is not the knob: Incus sizes a VM's
root disk through the `root` disk device's `size` key, and `apply.sh`
overrides `root` onto this instance alone (the shared `default` profile
cannot carry a runner-sized disk). Growing a VM disk is one-way; the guest
needs a restart to claim it. There is no second disk and no data volume to
resize.

The original image was 10 GiB and the first real job filled it: `/` and
`/nix/store` share the partition, and the Docker image store is on the root
disk. With one 5.06 GB CI image pulled, the disk sat at 97% and 360 MB free.
That history is why the root disk is sized explicitly and the Docker prune
runs daily.

## Known rough edges

* **The first job to run failed, and the reason was not visible in
  any unit's status.** `$HOME` was the data volume's mount point (then a
  separate disk), which is `root:root 0755` because that is what a
  filesystem root should be. The generator created `cache/` and
  `workspace/` as the runner, so those worked; act creates
  `$HOME/.cache/act/ff/<sha>` itself and could not. The lesson is the shape
  of it: the generator only creates the directories it knows about, so any
  write the daemon makes *implicitly* under `$HOME` is invisible to it.
  Fixed by moving the runner's home to a subdirectory the generator owns —
  see `default.nix`, "The runner's account".
* **A re-create re-pulls every job image and loses the artifact cache.**
  The image store and the cache are on the same disposable root disk, so the
  first job after a re-create pays one pull per label and starts with a cold
  cache. The secrets and config are re-rendered, so there is no
  re-registration.
* **The daily Docker prune removes unused images, containers, volumes and
  build cache**, so a label that has not run for a day re-pulls on its next
  job. That is the trade for a bounded single disk. The artifact cache has
  its own guard and a 10 GiB-free threshold.
* **The Nix rebuild job is on the host, not this VM.** The VM declares no
  `nix` label; the host runner on the HomeLab host has only `nix-rebuild`.
  Keep that label out of untrusted repositories, because a host-executor job
  runs its shell steps on the host.
