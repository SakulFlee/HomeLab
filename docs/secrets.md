# Secrets

Secrets live in `secrets/secrets.yaml`, encrypted with sops/age. The host
renders file-based secrets into `/run/homelab/secrets`; nothing plaintext is
committed.

## Keys the renderer requires

The Forgejo, Fluxer, OpenCode, Renovate and runner values were carried over from
the previous host; the Paperless values were added with that stack. These keys
must exist before `render-secrets.sh` will run:

| key | purpose | suggested value |
| --- | --- | --- |
| `forgejo_db_password` | Forgejo's PostgreSQL role password | `openssl rand -base64 32` |
| `forgejo_pat` | Forgejo PAT for git push, shared by OpenCode and Hermes | PAT with `write:repository` (and `read:user`) |
| `paperless_secret_key` | Paperless session/token signing key | `python3 -c 'import secrets; print(secrets.token_urlsafe(64))'` |
| `paperless_db_password` | Paperless's PostgreSQL role password | `openssl rand -base64 32` |
| `paperless_admin_password` | first-boot Paperless superuser password | chosen once |
| `wg_easy_password` | retrievable plaintext wg-easy admin password | generated |
| `wg_easy_password_hash` | what wg-easy actually consumes | bcrypt hash of `wg_easy_password`, see below |
| `restic_password` | local restic repository | `openssl rand -base64 32` |
| `restic_dendra_password` | Dendra restic repository | a different `openssl rand -base64 32` |
| `iot_wifi_passphrase` | WPA2 passphrase for the IoT SSID | 8–63 alphanumerics, see [iot-wifi.md](iot-wifi.md) |

Optional, and skipped when absent:

| key | purpose |
| --- | --- |
| `ntfy_url` | ntfy topic for failure alerts |
| `fluxer_webhook_url` | Fluxer channel webhook, Discord-style payload |
| `healthchecks_pull_url` | dead-man's switch for the daily backup chain |
| `healthchecks_check_url` | dead-man's switch for the weekly restic check |

`render-secrets.sh` writes these into `/etc/homelab/notify.env` (0600 root),
which every notifying unit loads through `EnvironmentFile=`.

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

The host's age identity is a dedicated key at `/etc/sops/age/keys.txt`, created
with `age-keygen`; its public half is enrolled in `.sops.yaml`. It is not derived
from the SSH host key, so it survives an SSH rekey.

Dendra can decrypt the same file with the identity in
`~/.config/sops/age/keys.txt`. That key is the root of trust for everything else:
the restic passwords, the wg-easy password, the notification endpoints and every
service secret.

Keep the age key, both restic repository passwords and the LUKS recovery
passphrase offline (KeePass or paper). Without them the encrypted secrets and
the backups cannot be recovered.

## Forgejo SECRET_KEY

`forgejo_secret_key` decrypts 2FA secrets and other encrypted columns in the
Forgejo database. Never regenerate it on an existing database: a new key is
accepted silently, then every 2FA-enabled account is refused with "this instance
requires two-factor authentication", including API tokens. Action secrets
encrypted with it also break: Forgejo panics on `FetchTask` with
`assignment to entry in nil map`, so every Actions job stays queued while the
runner looks online and idle.

The old host stored it as `SECRET_KEY_URI=file:/var/lib/forgejo/custom/conf/secret_key`,
so the key is the content of `forgejo-custom/conf/secret_key` in the migration
export, not the URI string and not the `app.ini` value.

## Paperless

The three Paperless values are rendered as files under
`/run/homelab/secrets/paperless` and mounted as Docker secrets. Paperless reads
them through `PAPERLESS_SECRET_KEY_FILE`, `PAPERLESS_DBPASS_FILE` and
`PAPERLESS_ADMIN_PASSWORD_FILE`; the files must not end in a newline (the
renderer uses `jq -j`).

`paperless_secret_key` signs sessions and tokens. Do not regenerate it on an
existing installation: every session and token becomes invalid. Unlike
Forgejo's key it does not encrypt document data, so a rotation is recoverable —
users simply log in again.

`paperless_admin_password` is only used when the superuser is first created.
Changing the sops value later does not change the existing account's password;
use `docker compose exec webserver python3 manage.py changepassword paperless`.
The username is `paperless`, set in the stack; changing `PAPERLESS_ADMIN_USER`
after the first boot creates an additional superuser rather than renaming the
existing one.
