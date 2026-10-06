# Forgejo runner — operating notes

Everything here is about *how this instance is put together*, and
specifically the parts that are not obvious from the Nix. The Nix
explains what is configured; this explains why, and what was
verified to find out.

Read `default.nix` for the guest, `disk.nix` for the data volume,
and `incus.nix` for the Incus half (limits, volumes, devices,
rendered secrets).

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
and a re-create loses nothing because the volume they land on survives
one. The registration-token flow the nixpkgs `services.gitea-actions-runner`
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

The old k3s runner is still registered in Forgejo, still carrying
these same three labels. Its credentials are no longer in this
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
  to the file on the volume would not survive the next reconcile.
* The last daemon to declare wins. During the cutover (below), do not
  run the k3s runner and this VM against the same Forgejo: two
  daemons with one uuid each declare their own labels and steal each
  other's jobs.

## What lives where

| where | contents | survives a re-create? |
| --- | --- | --- |
| root disk | the NixOS system, dockerd's image store (`/var/lib/docker`) | **no** — disposable by design |
| `forgejo-runner-data` volume (`persistent` pool) | `config.yaml` (holds the token), `secrets/` (rendered), the actions cache, job workspaces | **yes** |

Docker's image store is deliberately on the root disk. Images are
re-pullable by definition, so losing them to a re-create costs one
re-pull per label, and keeping them off the volume keeps the volume's
contents to the things that are actually state. The daily
`forgejo-runner-prune.timer` (`docker image prune --all --force`)
bounds the root disk's growth for the same reason the host runs a
weekly `crictl` prune for k3s.

The root disk is 40 GiB, and Incus is what grants it — see
`rootDiskSize` in `incus.nix`. It is deliberately not baked into the
image, because the image is assembled inside a 128 MB VM (qemu's
default; `make-disk-image.nix` passes no `-m`) and a 45 GiB ext4's
metadata does not fit in that, so the guest kernel panics before the
build finishes. The guest grows its filesystem into whatever disk
Incus gives it at boot, so a small image and a large disk are not in
tension. Growing the disk renumbers the guest's virtio devices, which
is why `disk.nix` identifies its volume by label.

The volume is on `persistent`, which is **not** restic'd, for the
same reason the caddy secrets volume is: `config.yaml` holds the
runner token, and a backed-up copy of a live credential is a
liability. Nothing on this volume is irreplaceable — the secrets and
the config are both regenerable from the host's sops store.

The volume is a **block** device (a VM gets raw block, not a bind
mount) that the guest formats itself, exactly like the WireGuard VM's
data disk: `disk.nix` formats it once (only when the label is absent,
refusing to guess when more than one blank disk is attached) and
mounts it at `/var/lib/forgejo-runner`. If the disk is absent or the
mount fails, the generator unit cannot run (`requiresMountsFor`), the
daemon (`Requires` the generator) stays down, and nothing runs
against the root disk — the silent-failure mode the wireguard
arrangement was built to prevent.

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

Three labels, all naming the same image, so nothing that runs on
`default`, `ubuntu-latest` or `ubuntu-24.04` has to change:

```
default:docker://ghcr.io/catthehacker/ubuntu:act-24.04
ubuntu-latest:docker://ghcr.io/catthehacker/ubuntu:act-24.04
ubuntu-24.04:docker://ghcr.io/catthehacker/ubuntu:act-24.04
```

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

What a job can do: pull images, run containers, and reach the internet
through the VM's NAT. What it cannot do, by configuration:

* **mount host paths** — `container.valid_volumes: []` means no volume
  or bind mount a workflow declares is honoured; the job fails instead.
  The k3s podspec had the same posture (no volumes, no service-account
  token). Widen with care; `valid_volumes: [ "**" ]` allows any mount.
* **reach the Docker socket** — `container.docker_host: "-"`, so job
  containers get no `/var/run/docker.sock`. A workflow that needs
  Docker (a `docker build`, a compose stack) asks the runner, and the
  runner runs it as a *sibling* container; the socket stays inside the
  VM.
* **run privileged** — `container.privileged: false`. A workflow that
  genuinely needs Docker-in-Docker needs this set to `true`; that is
  the one knob that weakens the boundary, so it is off by default.

The daemon itself runs as the `forgejo-runner` user (in the `docker`
group — it needs the socket, and the containers it creates run as root
inside their own namespaces regardless of the runner's uid), with
`NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=strict` and a single
`ReadWritePaths` — the data volume. The k3s deployment ran the runner
as root because the pod needed the socket; a VM can do better.

## Capacity and timeouts

Parity with the k3s values, so behaviour does not change with the
platform: `capacity: 4` concurrent jobs, `timeout: 4h`,
`shutdown_timeout: 3m` (the daemon drains running jobs within this on
TERM). The VM's own limits are 4 cpu and 8 GiB — the k3s deployment's
worst case was four concurrent pods limited to 1 cpu and 4 GiB each,
plus the runner; this is that ceiling with room for dockerd and the
images a build pulls in. It is a cap, not a reservation.

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
server over a shared secret. The cache directory lives on the volume,
so cached artefacts survive a re-create. The proxy's host address is
auto-detected; job containers reach it through their bridge's gateway,
which is the VM, and the VM accepts packets addressed to its own
address regardless of which interface they arrive on — the same
hairpin the WireGuard VM's routing relies on.

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

1. `NIX_SUDO=1 ./incus/image-eval-test.sh` — the image has to evaluate
   before anything is worth deploying. This is the check that catches
   the failure mode NixOS gives no other warning about: an option name
   that does not exist is accepted when the module is read and only
   fails when `system.build.toplevel` is forced, which is to say at
   build time. See the header of that file for the two real instances
   of it in this file's sibling, `default.nix`.
2. Deploy: `incus/apply.sh forgejo-runner` (or
   `systemctl start incus-apply-forgejo-runner.service`).
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
5. `/var/lib/forgejo-runner` is a **mountpoint**:
   `incus exec forgejo-runner -- findmnt /var/lib/forgejo-runner`.
   data disk was formatted with the label `forgejo-runner-data`,
   which is 19 characters; ext4 caps labels at 16, so `mkfs.ext4`
   truncated it to `forgejo-runner-d` with a warning and exited 0.
   The mount's `what` then named a label that did not exist, so
   systemd never created the mount unit at all — not inactive,
   *not-found* — and the daemon died on `result 'dependency'`.
   `apply.sh` had reported success throughout, because it reconciles
   the instance and the instance was fine; it has no view of the
   guest's systemd.
6. In the Forgejo UI (Site Admin → Actions → Runners), confirm the
   runner is online with the three labels. Its name is whatever was
   chosen at creation — nothing in this repository records it.
7. Submit a workflow that runs on `ubuntu-latest` and watch it execute
   here: `incus exec forgejo-runner -- journalctl -u forgejo-runner -f`
   shows the job being fetched, the image pulled and the container
   created.

If the runner does not come up, the two places to look first:
`journalctl -u forgejo-runner-config` (the generator — it fails by
design until the secrets are rendered, and again on any syntax error
in the template) and `incus exec forgejo-runner -- ls -la
/var/lib/forgejo-runner` (the volume mounted, the secrets rendered,
the config present at `0400 forgejo-runner`).

## Verification

```bash
incus/apply.sh --check forgejo-runner   # build, report drift, change nothing
incus-status.service                    # the one-line-per-instance table
incus exec forgejo-runner -- systemctl status forgejo-runner
incus exec forgejo-runner -- docker ps  # job containers, while a job runs
```

The runner declares itself at every start, so the fastest check that
the credentials still work is the daemon's own log: a line reading
`runner: <name>, with version: v13.2.0, with labels:
[default ubuntu-latest ubuntu-24.04], ephemeral: false, declared
successfully` followed by `[poller] launched`.

## Disk sizing

The root disk is **40 GiB**, set in `default.nix` by overriding
`system.build.qemuImage` and passing `additionalSpace = "40G"` to
`make-disk-image.nix`.

It is not `virtualisation.diskSize`, which looks like exactly the
right knob and does nothing here. That option is declared as
`either (enum ["auto"]) ints.positive` in
`virtualisation/disk-size-option.nix`, so an integer is valid — but
`qemu-vm.nix` only uses it for the disk of the VM it starts to *run
a build* in. The image itself comes from `incus-virtual-machine.nix`,
which calls `make-disk-image.nix` directly and passes neither
`diskSize` nor `additionalSpace`. So the image took that function's
defaults: `diskSize = "auto"` (computed as
`requiredFilesystemSpace + additionalSpace`) and
`additionalSpace ? "512M"`. That 512 MB, plus the closure, is where
the original 10 GiB came from.

10 GiB was not enough, and the arithmetic is worth keeping: `/` and
`/nix/store` are the same partition here, so the disk carries the
NixOS closure (~2.5 G) *and* the Docker image store. Measured on the
first real job, with one 5.06 GB CI image pulled:

| | used | free | |
|---|---|---|---|
| at rest | 7.3 G | 1.9 G | 80% |
| in a job | 8.8 G | **360 M** | **97%** |

The label image (`ghcr.io/catthehacker/ubuntu:act-24.04`) unpacks to
roughly 2.2 GB, so a workflow that does *not* pin its own image would
have failed to pull with ENOSPC as soon as a large CI image was also
present.

Incus cannot widen it afterwards: `incus config set <vm>
limits.disk.size` is rejected as an unknown key, so the size has to
be baked into the image. The qcow2 stays sparse, so 40 GiB costs
nothing on the host while unused.

## Known rough edges

* **The first job to run failed, and the reason was not visible in
  any unit's status.** `$HOME` was the volume's mount point, which is
  `root:root 0755` because that is what a filesystem root should be.
  The generator created `cache/` and `workspace/` as the runner, so
  those worked; act creates `$HOME/.cache/act/ff/<sha>` itself and
  could not. The lesson is the shape of it: the generator only creates
  the directories it knows about, so any write the daemon makes
  *implicitly* under `$HOME` is invisible to it. Fixed by moving the
  runner's home to a subdirectory the generator owns — see
  `default.nix`, "The runner's account".
* **A re-create re-pulls every job image.** The image store is on the
  root disk by design (see "What lives where"), so the first job after
  a re-create pays one pull per label. The cache on the volume makes
  that the only cold-start cost.
* **`docker image prune --all` removes unused images daily**, so a
  label that has not run for a day re-pulls on its next job. That is
  the trade for a bounded root disk. It was weekly until the first
  real job: with one 5.06 GB CI image the root disk sat at 97% and
  360 MB free, which is not enough to pull the 2.2 GB label image
  alongside it.
