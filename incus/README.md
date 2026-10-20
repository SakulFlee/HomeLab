# incus/

Tooling for building NixOS container images and turning them into running
Incus instances. Everything here is meant to be run on the homelab host, where
`/etc/nixos` is a clone of this repository.

> **Lifecycle is owned by OpenTofu now.** Images, instances, volumes, networks,
> profiles and projects live in `incus/infra/`, generated from the flake by
> `incus/gen-tf.sh`. The host runs `incus-secrets.service` for the one thing
> Tofu cannot do without putting plaintext in state: rendering sops secrets into
> the guests. `apply.sh` is kept only as a migration/rollback reference; the
> operational commands below all go through `gen-tf.sh` and Tofu.

## Layout

| path                          | what it is                                                      |
| ----------------------------- | --------------------------------------------------------------- |
| `incus/gen-tf.sh`             | build image artefacts and regenerate `infra/generated.tf.json`   |
| `incus/import.sh`             | one-time adoption of the live setup into Tofu state              |
| `incus/infra/main.tf`         | provider and static resources (server, pool, network, profile)   |
| `incus/apply.sh`              | legacy reconciler: build image, import, create/recreate          |
| `nixos/incus-tf.nix`          | Nix → Tofu JSON generator                                        |
| `nixos/incus-instances.nix`   | the registry — the only list of instance names                   |
| `nixos/hosts/<n>/default.nix` | the OS config, built into the image                              |
| `nixos/hosts/<n>/incus.nix`   | the container config: limits, volumes, devices                  |

**On the host**, this directory is `/etc/nixos/incus/`. The generated Tofu
configuration is `infra/generated.tf.json`; it is not committed because it
contains store paths that only exist after `gen-tf.sh` has built the artefacts.

An instance is defined in two files, deliberately split:

* **`default.nix`** is a NixOS module. Anything the guest can configure lives
  here, because it is what gets built into the image.
* **`incus.nix`** is plain data. Limits, storage volumes and devices are facts
  only Incus knows, so they cannot live in the image.

`nixos/incus-instances.nix` imports the `incus.nix` of every instance and is the
single source of the names. The flake exposes it as `incusInstances`, and both
the Tofu generator and `incus-secrets` read that output. There is no second list
to keep in sync.

## Image identity

Every instance's image is imported from a **rootfs** plus a **metadata tarball**,
and the two do very different amounts of work.

The fingerprint Incus gives the image comes from the **metadata tarball**, not the
rootfs. That is not obvious and it has bitten: nixpkgs' `lxc-image-metadata.nix`
generates ours per nixpkgs revision, so it is byte-identical for every instance
built from the same revision — `caddy's` and `wireguard's` metadata are the same
bytes. Two different rootfs, one fingerprint, and the second import is refused:

```
Error: Image with same fingerprint already exists
```

which is not a transient condition. Every rebuild of every instance collides, and
"already exists" stops meaning "this image is already here" and starts meaning
"something with this fingerprint is here". The recovery path in `import_image`
looked the image up by `user.build-source` and found nothing — correctly, because
the build genuinely was not in the pool — and reported a confusing error that
pointed at the property rather than at the fingerprint.

**The fix is in `mkTfArtifact`.** It repacks the metadata tarball with the
description rewritten to name the instance and its rootfs store path, and imports
that. The description is the only field in `metadata.yaml` that is ours to
choose, and it is in the fingerprint. Verified on the running instance by
rewriting only that one field and importing a rootfs that had just been refused:

```
Error: Image with same fingerprint already exists    <- stock metadata
Image imported with fingerprint: 560477927d41...      <- description names caddy
```

Two details that matter and are easy to get wrong:

* **Everything else is copied through untouched.** Rewriting the metadata
  tarball is not an opportunity to tidy it.
* **`tar` is given `--sort=name`, fixed owner/group and `--mtime`.** Without those
  the archive embeds the current time and member order, so the same instance would
  produce a different fingerprint on every build and no image would ever be
  recognised as unchanged.

`apply.sh` wrote `user.build-source` on the images it imported; the Tofu provider
has no equivalent property. That is why `incus-image-gc.sh` only deletes images
carrying that property: it can reclaim images from the old reconciler without
ever touching one an instance currently references.

## Secrets

**An instance is given rendered values, never a key.** `incus.nix` declares

```nix
renderedSecrets = [
  { file = "caddy-env"; env = "CF_API_TOKEN"; source = "/run/secrets/cloudflare_api_token"; }
];
```

and `incus-secrets` reads `source` — which the *host* decrypts, with the host's own
SSH identity key — and writes `ENV_NAME=<value>` into `file` inside the
instance. The value is piped on stdin, never a command-line argument, and the
write is diffed so a settled redeploy touches nothing.

`format = "raw"` writes the secret's bytes through unchanged instead of
prefixing `ENV_NAME=`, for anything that is not a `KEY=value` line. The
incus.sakul-flee.de vhost needs it for a PEM certificate and key: as
EnvironmentFile lines they would collapse into one enormous malformed variable,
and Caddy would be handed that instead of a key file. Trailing newlines are
stripped by the command substitution; the internal ones a PEM is made of survive.

`mode` and `group` default to `0400` and no group change, which is right for
anything read by systemd — `EnvironmentFile` is opened as root *before* the
service drops privileges. It is **wrong** for a file the service itself opens,
and caddy.service runs as `User=caddy`. Its `tls_client_auth` certificate is
read by the Caddy process, so at `0400 root:root` it cannot read its own key,
exits, and takes every hostname down:

```
making TLS client config: loading client certificate key pair:
open /var/lib/incus-secrets/incus-client.crt: permission denied
```

So the two PEMs declare `mode = "0440"; group = "caddy";`. Two things follow from
that, both of which were learned the hard way:

* **Ownership is part of the diff, not just content.** A file whose bytes are
  correct but whose mode is not is still broken, and comparing content alone
  means incus-secrets declares it settled while the consumer cannot read it.
* **A restart is a request, not a result.** `secretConsumers` are restarted and
  then **checked with `systemctl is-active`**, and a failure dumps the unit's
  last journal lines into the error. Without that check this script reported
  `Result=success` and `ok -- Running` while Caddy was dead and all twenty
  hostnames were refusing connections — the single most expensive bug in this
  file, and the diagnosis was one line of a `journalctl` that nothing prompted.

`file`, `mode` and `group` are interpolated into a `sh -c`, so they are pattern-
checked rather than trusted.

The alternative, which is in the git history, imported sops-nix into the
instance and bind-mounted the host's `/etc/ssh/ssh_host_ed25519_key` so it could
decrypt for itself. It worked. It was also the wrong shape: it gave a root
process in the container the ability to decrypt **every** value in the host's
`secrets.yaml` — the restic password, the Forgejo JWT secret, the PIA VPN
credentials — and the only thing limiting that was remembering not to.

This way the instance has no decryption capability at all. It holds one token
and cannot reach anything else even if it wants to. Secrets at rest are
excluded from snapshots by omission: no `snapshots` block declares them, so
none are ever taken — which is the point, for a live API token.

One consequence worth knowing: `/run/secrets/*` does not exist until the host
has been rebuilt, so a new instance with `renderedSecrets` cannot come up
correctly before that. `incus-secrets.service` skips instances that are not
running, and the five-minute timer retries until the instance is up; the
`/run/secrets` path unit fires immediately when sops materialises a rotated
value.

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
a recreate lives on a storage volume**, declared in `incus.nix` — Caddy's ACME
certificates, Forgejo's repositories and PGDATA alike. How long each survives
is a per-volume snapshot policy in that same file, not a property of where it
sits: there is one pool, and retention is declared, not inherited.

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

## Containers and VMs

An instance is a container unless its `incus.nix` says otherwise:

```nix
{
  type = "vm";   # omitted means "container"
  ...
}
```

That one attribute changes four things, so it is worth knowing all four rather
than discovering them one at a time:

|                    | container                            | vm                                            |
| ------------------ | ------------------------------------ | --------------------------------------------- |
| image build        | `squashfs` + `metadata` (two files)  | `qemuImage`, a single qcow2 (one file)        |
| `incus image import` | metadata tarball **first**, rootfs second | the qcow alone — no second argument      |
| `incus create`     | no type flag                         | `-t vm`, explicit rather than inferred       |
| volumes            | `filesystem` type                    | `block` type                                  |
| disk devices       | `path=/somewhere` mounts it          | **no `path`** — a raw block device            |

The generator derives the type from the spec rather than from the image, and the
artefact *count* is what distinguishes the two shapes at the call site: one file
for a VM, two for a container. `mkTfArtifact` names the rootfs file itself, so
there is no list of paths to pad or truncate.

Two things are easy to get wrong in the details:

* **The import argument order is metadata first.** It is still that way for
  containers, and the old LXD-era examples online have it backwards. A VM is
  unaffected, because it has no metadata tarball — passing an empty second
  argument is *not* the same as passing none, since Incus would try to read `""`
  as a rootfs.
* **The API path segment for a volume is Incus's name for the type, not ours**:
  a filesystem volume is `/volumes/custom/`, a block volume is `/volumes/block/`.
  Hardcoding `custom` 404s on every block volume.

### Why WireGuard is a VM and not a container

The rule in this repo is LXC unless something needs `security.privileged`, in
which case VM. WireGuard needs it: the kernel WireGuard module has to be
available *inside*, and an LXC shares the host kernel, so the host would have to
carry the module for a guest's benefit. A VM brings its own.

It also fixes a routing problem that cost real time. The VPN has to be reachable
at the **host's** LAN address, 192.168.178.200, because that is what the router
forwards and what every existing client already points at. A container on
`incusbr0` sits behind DNAT and NAT masquerade and cannot route there at all; a
macvlan container gets onto the LAN but cannot speak to the host. A **bridged VM
is a plain L2 peer** and can, which removes the entire DNAT-plus-forward-guard
class of bug — the one documented under "The host's entry points" — rather than
just relocating it.

The bridged VM also means its tunnel packets leave `eno1` un-NATted, so Caddy
still sees a real `100.64.0.0/10` client address and the Incus vhost gate keeps
working untouched.

## Running it

```bash
incus/gen-tf.sh                  # build every image + write generated.tf.json
cd incus/infra
tofu init
tofu plan
tofu apply                       # first run also replaces instances onto new images
systemctl start incus-secrets.service
journalctl -u incus-secrets -f   # secret rendering and consumer restarts
```

All of it needs root: Tofu talks to the Incus unix socket, and Nix store paths
are only writable by the daemon's group.

After a secret rotation (a rebuild that changes `/run/secrets`), the path unit
starts `incus-secrets.service` automatically; the five-minute timer is only a
safety net. There is no per-instance systemd unit any more, and no
`incus-status.service` — inspect Tofu state with `tofu state list` and Incus with
`incus list`.

## Migration (one time)

```bash
incus/gen-tf.sh
incus/import.sh
cd incus/infra && tofu plan -out=roll.tfplan && tofu apply roll.tfplan
systemctl start incus-secrets.service
```

`incus/import.sh` adopts the live instances, volumes, project, pool, network,
profile and forwards. Images and the server resource cannot be imported; the
first apply creates the images and adopts the server config. Every instance is
replaced once because its `image` becomes the new image resource's fingerprint.

## Redeploying after a config change

There is no per-instance systemd unit any more. Changing an instance's Nix
config, a shared module, or a secret does not touch Incus by itself: run
`incus/gen-tf.sh`, review `tofu plan`, and apply. `nixos-auto-update` still
updates the host closure and sops secrets, but it deliberately does not run
`tofu apply` — an unattended apply can replace running instances and must stay a
reviewed action.

The first apply after the switch to Tofu replaces every instance once, because
the image changes from a manually imported fingerprint to a resource-managed
one. If Incus reports `Image is in use by an instance` while deleting an old
image, the replacement was created before the old one could be removed; rerun
`tofu apply` and it converges.

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

One pool, `persistent` (btrfs), holding everything: instance root disks,
custom data volumes, and images. There used to be two more -- a `backup`
pool split by an intended retention nobody enforced, and an `ephemeral` dir
pool planned for VMs that was never created. Both ideas are recorded here so
nobody reintroduces them: retention is a per-volume `snapshots` policy in
each `incus.nix`, not a pool assignment, and VM storage gets decided when a
VM actually arrives.

`persistent` exists as one pool rather than none because Incus requires
volumes to live somewhere, not because the name enforces anything. What
must not be repeated is the converse mistake the old split invited: a
PGDATA copy is not a backup, and a pg_dump is. A torn PGDATA copy is worse
than no copy -- the authoritative artefact is always a `pg_dump`, and no
pool layout changes that.
