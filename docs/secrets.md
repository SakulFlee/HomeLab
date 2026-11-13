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
| `wg_easy_password_hash` | wg-easy admin password | bcrypt hash, see below |
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

## Age key

The host's age identity is expected at `/etc/sops/age/keys.txt`. The current
NixOS host derives its key from `/etc/ssh/ssh_host_ed25519_key`; copy that key or
create a dedicated age key before wiping.

Keep the age key and both restic passwords offline. Without them, the encrypted
secrets and backups cannot be recovered.
