# open-webui

Web frontend for Ollama. Replaces nothing directly — it is the UI for
`../ollama/`, and it is where models get imported.

## After the first sign-up, close registration

`ENABLE_SIGNUP` is `"true"` in `deployment.yaml` **on purpose, and only until
you have an account.** The first account to register becomes the admin. While
signup is open, any other VPN client that reaches this host can register, and
the first one to arrive after you would be the admin.

So: sign in at `https://open-webui.sakul-flee.de` from a VPN client, create the
admin account, then set `ENABLE_SIGNUP: "false"` and commit. The frontend is
VPN-only at the ingress, which limits this to people already on the tunnel —
it does not make it safe to leave open indefinitely.

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
