# Website (Incus VM, OCI container)

Runs the personal site from the image the k3s deployment ran, unchanged:
`forgejo.sakul-flee.de/sakulflee/website:latest` — an Astro static build served
by nginx on port 80.

## Architecture

- **Type**: Incus VM (`type = "vm"`) — see "Why a VM" below.
- **IP**: `10.0.0.114/24` on `incusbr0`, configured in the guest, matched on the
  pinned NIC MAC `00:16:3e:00:00:13`.
- **Volumes**: none. The site is a build artefact in the image and podman's
  copy is re-pullable by definition, so a recreate loses nothing.
- **Network forwards**: none. Caddy terminates TLS for both names and proxies
  over the bridge to `10.0.0.114:80`.
- **Runtime**: `virtualisation.oci-containers` (podman), `pull = "always"`,
  published `80:80`.
- **Limits**: 1GiB / 2 CPU.
- **Secrets**: none. The package is public and pulls anonymously.

## Why a VM

The repo's rule is LXC unless something needs `security.privileged`, in which
case VM. This needs it: the site is served *from a container*, so the instance
needs a container runtime inside it. An LXC shares the host kernel, so a
runtime in there would have to run privileged — handing the guest the host
kernel, which is exactly what the rule refuses. A VM brings its own kernel and
its own podman.

Same fork as `forgejo-runner` (Docker executor) and `fluxer` (Compose). It is
deliberately *not* the media stack's shape: those are containers because a
userspace daemon needs no kernel of its own, which does not apply here.

It is worth being honest about the cost. A VM plus a NixOS closure to serve a
static build is a lot of machinery, and `nix build` of a static site plus
`services.nginx` would have been smaller and more idiomatic. The container is
kept anyway, because "the site is the image the upstream repo publishes, and
that is what runs" is worth more than the footprint — the upstream repository
stays the only place the site is built, and a rebuild there is a rebuild here.

## No registry credentials

`forgejo.sakul-flee.de` answers `/v2/token` for an anonymous request and then
serves the manifest, so `podman pull` needs no credential. Verified rather than
assumed: the registry *does* `401` a bare manifest request, which is the Docker
Registry auth challenge rather than a denial, and following that challenge
anonymously succeeds. No `login`, no sops secret, nothing to rotate.

## Deploy

```bash
NIX_SUDO=1 ./incus/image-eval-test.sh   # the image has to evaluate first
incus/apply.sh --check website          # build, report drift, change nothing
incus/apply.sh website                  # or: systemctl start incus-apply-website.service
```

Adding the instance to `incus-instances.nix` is itself a host rebuild — the
per-instance `.service`/`.path` units are generated at host build time — so run
`nixos-rebuild switch` on the homelab host before relying on the systemd path.

## Verification

```bash
incus-status.service
incus exec website -- systemctl is-active podman-website
incus exec website -- podman ps
curl -I http://10.0.0.114/            # from the host
curl -I https://sakul-flee.de/        # through Caddy
curl -I https://www.sakul-flee.de/
```

`podman-website.service` is the unit name NixOS generates (`<backend>-<name>`),
and the backend is podman. It pulls on every start, so a cold `is-active` check
is also a check that egress and DNS work in the guest.

## Rollback

1. Delete the site block for `sakul-flee.de, www.sakul-flee.de` from
   `../caddy/default.nix` and put both names back in `hostnames.nix`. They are
   back on `still-traefik` and therefore back to k3s immediately.
2. Restore `apps/website/` and `clusters/homelab/apps/website.yaml` and let Flux
   reconcile.
3. The instance can be left in place or stopped (`autostart = false`); the site
   has no state, so nothing is lost either way.

## Not carried over: matrix well-known

The k3s namespace also ran a second workload, `matrix-well-known`, which served
`sakul-flee.de/.well-known/matrix/{client,server}` as `application/json` for
Matrix server discovery. **That is not reproduced here.** The website image has
no `.well-known` directory at all — checked inside the image, not assumed — so
after this cutover those two paths 404.

This is a deliberate omission, not an oversight. It needs its own decision
rather than being smuggled in here, and the two shapes are:

- **Serve the two JSON files from the website VM** — bind-mount them into the
  container. Self-contained, so Caddy only proxies the domain and never has to
  know the paths exist. Needs an nginx `location` block with
  `default_type application/json`, because the stock `default.conf` has no
  extension on those names and would serve `application/octet-stream`.
- **Serve them from Caddy** — a `respond` block for the two paths, which is
  cleaner (it is an edge concern, and Caddy is the edge) but means the route
  lives in `../caddy/default.nix` rather than with the site.

Either way, `apps/website/matrix-well-known.yaml` is gone with the rest of the
namespace, so this is a real gap until one of them is built.