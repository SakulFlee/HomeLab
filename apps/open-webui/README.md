# open-webui

Web frontend for Ollama. Replaces nothing directly — it is the UI for
`../ollama/`, and it is where models get imported.

## Registration is closed

`ENABLE_SIGNUP` is `"false"`. The first account became the admin
(`SakulFlee` / `open-webui@sakul-flee.de`), then signup was closed in the same
session. The frontend is VPN-only at the ingress, which limits registration to
people already on the tunnel — but that is a network gate, not an
authorization decision, so it does not justify leaving it open.

`ENABLE_SIGNUP` gates the signup endpoint only. Existing accounts keep working
and Open WebUI's own bootstrap user is unaffected, so this is not a lockout.

To add someone later, create the account directly rather than reopening
signup — reopening it means a window in which any VPN client that reaches the
host can register, and the first to arrive is an admin:

```sh
kubectl exec -n open-webui deploy/open-webui -- \
  python3 -c "from open_webui.models.auths import Auths; print(Auths().insert_new_auth(<email>, <name>, <password>))"
```

Check the current roster without writing anything:

```sh
kubectl exec -n open-webui deploy/open-webui -- python3 -c \
  "import sqlite3; c=sqlite3.connect('/app/backend/data/webui.db'); \
   print(*c.execute('select name,email,role from user').fetchall(), sep='\n')"
```

The `user` table has no `status` column in v0.11.4 — its columns are `id`,
`name`, `email`, `role`, `last_active_at`, … Do not add a `WHERE status = 1`
filter; it fails.

`WEBUI_SECRET_KEY` is a SOPS secret because losing it invalidates every session
cookie. It is generated once; do not regenerate it casually. Decrypt locally
with `sops -d apps/open-webui/secrets/secret.enc.yaml` if you need to inspect it.

## Storage

The data PVC is `local-path-backup`, not `local-path-persistent`. restic backs
up only the backup tier — see the comment at the top of
`../storage-class/restic-daemonset.yaml`, which states outright that it does
not snapshot `local-path-persistent`. This volume holds accounts, chats and the
RAG vector index, so it belongs in the tier that is actually backed up.

Note the consistency caveat that applies to every sqlite-backed app in the
backup tier, this one included: restic snapshots the live database file. The
tier exists because losing accounts and chat history is worse than a
occasionally torn read, not because the dump is transactional.

## No GPU, on purpose

This deployment requests **no `devic.es` resources**. It is a frontend and a
proxy; every token is generated in the ollama pod. Requesting the GPU here
would put a second process on the APU, which is the one thing this node must
never do — see `../ollama/README.md` for what that costs when it happens.

## Talking to Ollama

`OLLAMA_BASE_URL` is the in-cluster Service DNS name,
`http://ollama.ollama.svc:11434`. It is deliberately not the ingress hostname:
the split-DNS answer for `*.sakul-flee.de` only exists for VPN clients, so an
external URL would resolve from a laptop and fail from inside the pod.

## Importing models

Import through the UI (Admin Panel → Models). Nothing is seeded; the ollama
store starts empty. When importing a GGUF, **do not add a `TEMPLATE` line to
the Modelfile** — `ollama create` reads `tokenizer.chat_template` from the
file itself, and an explicit `TEMPLATE` overrides a working one with a
fallback that renders the model as garbage. `../ollama/README.md` has the
details.

## Sizing

`memory: 4Gi` / `cpu: "2"` limits are here to stop a runaway upload or RAG
index from taking the node down, not because the app needs it. Idle usage is
well under 1Gi. Raise the limit if you load large documents for RAG.
