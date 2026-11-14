# Secrets

Secrets live in `secrets/secrets.yaml`, encrypted with sops/age. The host
renders file-based secrets into `/run/homelab/secrets`; nothing plaintext is
committed.

## New keys for v2

The existing Forgejo, Fluxer, OpenCode, Renovate and runner values carry over.
These keys are new and must be added before `render-secrets.sh` will run:

| key | purpose | suggested value |
| --- | --- | --- |
| `forgejo_db_password` | Forgejo's PostgreSQL role password | `openssl rand -base64 32` |
| `wg_easy_password` | retrievable plaintext wg-easy admin password | generated |
| `wg_easy_password_hash` | what wg-easy actually consumes | bcrypt hash of `wg_easy_password`, see below |
| `restic_password` | local restic repository | `openssl rand -base64 32` |
| `restic_dendra_password` | Dendra restic repository | a different `openssl rand -base64 32` |

## Add a key

```bash
sops set secrets/secrets.yaml '["forgejo_db_password"]' '"VALUE"'
```

or edit the file:

```bash
sops edit secrets/secrets.yaml
```

## wg-easy password hash

wg-easy expects a bcrypt hash:

```bash
htpasswd -bnBC 10 "" 'your-password' | tr -d ':\n'
```

Put the resulting `$2y$...` value in `wg_easy_password_hash`.

## Local Compose `.env` files

`render-secrets.sh` also writes gitignored `.env` files into the stack
directories. They contain the host-specific ports plus, for Fluxer, the full
upstream interpolation set. They exist so Dockge and manual `docker compose`
commands work without a giant `env VAR=...` command. They are local-only and
must never be committed.

## Retrieving the wg-easy password

The plaintext is stored in sops so it can be recovered later:

```bash
/opt/homelab/scripts/sops.sh \
  -d --extract '["wg_easy_password"]' /opt/homelab/secrets/secrets.yaml
```

The wrapper exists because plain `sudo sops` looks in
`/root/.config/sops/age/keys.txt`, while this host keeps the identity at
`/etc/sops/age/keys.txt`. `render-secrets.sh` already knows that path; the
wrapper makes manual commands behave the same way.

Use it to log in to `vpn.sakul-flee.de`; wg-easy consumes the bcrypt hash, not
the plaintext.

## Age key

The host's age identity is expected at `/etc/sops/age/keys.txt`. The current
NixOS host derives its key from `/etc/ssh/ssh_host_ed25519_key`; copy that key or
create a dedicated age key before wiping.

If you only have an SSH key and no age key file, derive the age identity with
`ssh-to-age`:

```bash
SOPS_AGE_KEY="$(ssh-to-age -private-key -i ~/.ssh/id_ed25519)" sops -d secrets/secrets.yaml
```

Keep the age key and both restic passwords offline. Without them, the encrypted
secrets and backups cannot be recovered.
