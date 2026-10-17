# jupyterhub

Multi-user JupyterHub on `10.0.0.119`, reachable only at
`https://jupyter.sakul-flee.de` over the VPN, authenticated against the
homelab's own Forgejo via OAuth2. See `default.nix` for the guest OS and
`incus.nix` for the container.

## First deploy: the Forgejo OAuth application

This is a manual step and the deploy is broken until it is done: JupyterHub
will redirect to Forgejo, and the OAuth dance will fail against an application
that does not exist.

1. In Forgejo, create an OAuth2 application. As a user: **Settings →
   Applications → Create new OAuth2 Application**. As an admin you can also do
   it at **Site Administration → Applications**.
   - **Application Name**: `JupyterHub`
   - **Redirect URI**: `https://jupyter.sakul-flee.de/hub/oauth_callback`

2. Copy the **Client ID** into `forgejoClientId` in `default.nix` (it is not a
   secret; it appears in the browser's redirect URL).

3. Put the **Client Secret** into the host's sops store as
   `jupyterhub_forgejo_client_secret`:

   ```bash
   SOPS_AGE_KEY=$(ssh-to-age -private-key < ~/.ssh/id_ed25519) \
     sops set nixos/secrets.yaml '["jupyterhub_forgejo_client_secret"]' \
       '"<the client secret>"'
   # or, interactively:
   SOPS_AGE_KEY=$(ssh-to-age -private-key < ~/.ssh/id_ed25519) \
     sops edit nixos/secrets.yaml
   ```

   The key must also be declared in `nixos/modules/sops.nix` (it already is),
   or sops-nix never writes it to `/run/secrets`.

4. Rebuild the host (`sudo nixos-rebuild switch`), which materialises
   `/run/secrets/jupyterhub_forgejo_client_secret`, then start the apply unit.
   `incus/apply.sh` renders the secret into the instance and restarts
   `jupyterhub.service`.

## Allowed users

`forgejoLogin` in `default.nix` is the single Forgejo login permitted in, and
`c.Authenticator.allowed_users` is that same name. The Forgejo `login` must
match the Unix account exactly — a Forgejo login of `SakulFlee` will not map to
a Unix user of `sakulflee`. If they legitimately differ, normalise with
`c.Authenticator.username_map` in the config.

Adding a person is two edits:

- `users.users.<login>` (and `users.groups.<login>`) in `default.nix`, with a
  home under `/home` (the `jupyterhub-home` volume).
- Add `<login>` to `allowed_users` in the same file.

The account is declared, not created at runtime, because the root filesystem
is disposable: an account added with `useradd` would disappear on the next
image rebuild.

## Login fails, or the notebook never spawns

- **`KeyError: 'JUPYTERHUB_FORGEJO_CLIENT_SECRET'`** — the rendered secret is
  missing. Check the host wrote `/run/secrets/jupyterhub_forgejo_client_secret`
  (declared in `nixos/modules/sops.nix`?) and that the apply unit ran:
  `journalctl -u incus-apply-jupyterhub -n 50`.
- **`403` from Caddy before the login page** — the request came from the
  public internet, not the tunnel. `jupyter.sakul-flee.de` must be in
  `vpnOnlyNames` in `hosts/dns/default.nix` so split-horizon DNS answers it
  with the host's LAN address to connected clients.
- **OAuth callback error / token exchange times out** — the server-side calls
  (`token_url`, `userdata_url`) leave the container, resolve
  `forgejo.sakul-flee.de` at Cloudflare, and arrive back through the host's 443
  forward. If the router does not hairpin that, point those two URLs at the
  bridge instead — `http://10.0.0.101:3000/login/oauth/access_token` and
  `.../api/v1/user` — and leave `authorize_url` public. `default.nix` carries
  the same note at the config.
- **`Failed to spawn: systemdspawner`** — systemdspawner needs the system bus
  and creates transient units as root. Check `incus exec jupyterhub -- systemctl
  status jupyterhub` and `journalctl -u 'jupyter-*'` inside the instance; the
  transient unit for a user is named `jupyter-<username>.service`.

## GPU

The iGPU is passed through (`gpu` device in `incus.nix`) and Mesa's RADV stack
is staged (`hardware.graphics.enable` in `default.nix`), so the device is
openable and a vulkan driver is present. The **default kernel does not use it**:
the data-science kernel is CPU. Adding GPU compute means adding packages to the
`scienceEnv` (or a second kernel) — `torch`/ROCm is large and unfree and was
left out on purpose. Verify the device is visible with:

```bash
incus exec jupyterhub -- ls -l /dev/dri
```

## Volumes

| volume | mount | survives recreate | snapshot |
| --- | --- | --- | --- |
| `jupyterhub-data` | `/var/lib/jupyterhub` | yes | @hourly/7d |
| `jupyterhub-home` | `/home` | yes | @hourly/7d |
| `jupyterhub-secrets` | `/var/lib/incus-secrets` | yes | none (by design) |

`jupyterhub-home` is the irreplaceable one. `jupyterhub-data` losing its
snapshot window only costs a re-login.
