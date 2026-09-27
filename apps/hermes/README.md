# Hermes + Ollama

Two Flux Kustomizations that ship together:

| URL | Backend | Port |
| --- | --- | --- |
| `https://hermes.sakul-flee.de/` | Hermes WebUI | 8787 |
| `https://hermes.sakul-flee.de/v1` | Gateway OpenAI API | 8642 |
| `https://hermes-dashboard.sakul-flee.de/` | Monitoring dashboard | 9119 |
| `https://hermes-dashboard.sakul-flee.de/health` | Gateway liveness probe | 8642 |
| `https://hermes-dashboard.sakul-flee.de/v1` | Gateway OpenAI API | 8642 |
| `http://ollama.ollama.svc:11434/v1` | **model backend** (ClusterIP, no ingress) | 11434 |
| `https://open-webui.sakul-flee.de/` | Open WebUI — import and chat with models directly | 8080 |

All hostnames are VPN-only (`wireguard-vpn-only@kubernetescrd`) and use
`letsencrypt-production`.

## The backend is Ollama

Hermes sends chat to `http://ollama.ollama.svc:11434/v1` with
`model.provider: custom` and no API key — Ollama's OpenAI-compatible endpoint is
unauthenticated. Both keys are pinned in managed scope —
`apps/hermes/configmap.yaml`, mounted read-only at
`/etc/hermes/config.yaml`, where it wins over `~/.hermes/config.yaml`.

- **`model.base_url`** — Ollama's ClusterIP, deliberately not the ingress
  hostname. The split-DNS answer for `*.sakul-flee.de` only exists for VPN
  clients, so an external URL resolves from a laptop and fails from in here.
- **`model.default`** — an Ollama **tag**, currently
  `"SparkLLM/Spark-X2.5-4B:latest"`. Plain `:latest` is correct: Hermes sends
  the context itself (see the `context_length` section below), so the model
  needs no special import. Retarget by editing `configmap.yaml`, bumping its
  name, and updating the volume reference in `deployment.yaml`. The list is
  `kubectl exec -n ollama deploy/ollama -- ollama list`.

**Managed scope wins, so the dashboard cannot change this.** *Change* in the
dashboard writes `model.default`, but the pinned key overrides it — use
`hermes config get model` to see what is actually in effect. To retarget the
agent, edit the ConfigMap **and bump its name**.

### Bump the ConfigMap name on every edit

Editing values in a ConfigMap does **not** restart the pod, so a changed
`base_url` or `default` would be silently ignored. Changing the ConfigMap's
*name* is what rolls the pod — the mount is read-only and the volume reference
in `deployment.yaml` has to change with it. This is why the file is
`hermes-managed-config-v7`; v6 was the Spark-X2.5-4B repoint, v5 the Ollama repoint,
v4 llama-swap,
before that Unsloth Studio.

### `context_length: 65536` is the load-bearing setting

Hermes refuses to run against a window below 64K:

> ... has a context window of 32,768 tokens, which is below the minimum
> 64,000 required by Hermes Agent

`/v1/models` omits `max_model_len`, so Hermes has to be told the window — hence
the pinned `context_length`. **It is not just a declaration of intent: it is the
number Hermes sends.** The mechanism, in Hermes' own code:

1. `model.ollama_num_ctx` is unset, so `query_ollama_num_ctx` probes the
   server's `/api/show`. That probe prefers `parameters.num_ctx` (the *runtime*
   window) and falls back to `model_info.*.context_length` (the GGUF *training*
   max) — `model_metadata.py:_ollama_show_context`, called with
   `gguf_first=False`. `Spark-X2.5-4B` advertises 1048576, so that is what comes
   back.
2. `_configure_ollama_num_ctx` then caps the detected value to
   `model.context_length`, logging `Ollama num_ctx capped: 1048576 -> 65536`.
3. Every request carries `options: {num_ctx: 65536}`, added by the `custom`
   provider's `build_api_kwargs_extras`. Ollama honours a per-request
   `num_ctx`, so the server allocates 65536.

Verified on the wire against the plain `:latest` tag: `CONTEXT 65536`,
`100% GPU`, `finish_reason: stop`.

Two things this implies, both of which were got wrong here at least once:

- **`OLLAMA_CONTEXT_LENGTH` on the ollama deployment does not make Hermes
  work.** Hermes overrides it per request. It is set for Open WebUI's benefit,
  which does not send `num_ctx`.
- **Do not import the model with `PARAMETER num_ctx 65536`, and do not create a
  derived `:64k` tag.** Both are redundant — the request already carries the
  value. A derived tag is worse than redundant: it exists only in the model
  store, which is `local-path-volatile` with `reclaimPolicy: Delete`, so a PVC
  delete would leave `model.default` pointing at a tag that can never resolve,
  with nothing in git recording how it was made.

`ollama ps` prints the context the model actually got; that is the check.
See `../ollama/README.md`.

### Expect a cold-start delay

Ollama keeps one model resident (`OLLAMA_MAX_LOADED_MODELS=1`) and unloads
`OLLAMA_KEEP_ALIVE` (5m default) after the last request, so the first request
after an idle period pays a model load. This is why
`HERMES_STREAM_STALE_TIMEOUT` is 600s rather than the 180s default: the
agent's prompt is ~14.5k tokens and a cold pre-fill has been measured at
~197s against llama-swap, which was long enough for Hermes to declare the
stream stale and kill a request that was working. Treat 600s as a safe upper
bound, not a tuned value.

## Bootstrap order

1. **Push.** Flux applies `ollama`, `open-webui`, `open-webui-secrets`,
   `hermes` and `hermes-secrets` in parallel. Each app Kustomization creates
   its own namespace, so the sibling `-secrets` Kustomization retries every 2m
   until it exists — deliberate, since a `dependsOn` between them would
   deadlock on a fresh cluster.
2. **Create the Open WebUI admin.** Sign in at
   `https://open-webui.sakul-flee.de` from a VPN client. The **first account to
   register becomes the admin** — that is why `ENABLE_SIGNUP` ships as `true`
   and why it must be flipped to `false` immediately afterwards
   (`apps/open-webui/deployment.yaml`, and see that app's README).
3. **Import a model** via Open WebUI (Admin Panel → Models). Add nothing to
   the Modelfile — Hermes sends the context itself. Nothing is pre-seeded; the
   store starts empty.
4. **Point Hermes at it.** Set `model.default` in
   `apps/hermes/configmap.yaml` to the tag you created, bump the ConfigMap to
   `-v7`, and update the reference in `apps/hermes/deployment.yaml`.
5. **Smoke test** from inside the VPN:

   ```sh
   curl -H "Authorization: Bearer $API_SERVER_KEY" \
        https://hermes.sakul-flee.de/v1/models
   ```

   `API_SERVER_KEY` is in `apps/hermes/secrets` (SOPS).

## Adding a hostname means editing three files, not two

The ingress has to be paired with a `match` regex in
`apps/wireguard/coredns-configmap.yaml` — the A, AAAA *and* HTTPS templates,
in lockstep. A name left out resolves through the proxied
`*.sakul-flee.de` wildcard, so Traefik sees a Cloudflare edge IP instead of the
client's `100.64.0.x` tunnel address and answers `403 Forbidden` even to a
connected VPN client.

## Adding a cloud provider later

Replace the `model:` block in `apps/hermes/configmap.yaml` and add the new key
to `apps/hermes/secrets`. Bump the ConfigMap name as well: editing values in
place does not restart the pod, a changed name does.

## Hermes Desktop (Remote Gateway)

Desktop's Remote Gateway points at `https://hermes-dashboard.sakul-flee.de`.
That one hostname is served by **two** backends, because Desktop asks for more
than a browser does:

| Desktop asks for | Where it lands | Why |
| --- | --- | --- |
| `GET /api/status` | dashboard `:9119` | detection — reads `auth_flows` to pick its login flow |
| SPA, `POST /auth/password-login`, `/api/ws` | dashboard `:9119` | the actual UI and its WebSocket |
| `GET /health` | gateway `:8642` | **readiness** probe, used when OAuth mode is not committed |
| `/v1/chat/completions`, `/v1/models` | gateway `:8642` | chat client's OpenAI-compatible contract |

**Detection passing is not readiness passing.** `/api/status` is on the public
allowlist and answers 200 long before Desktop considers the backend ready; the
readiness fallback target is `${remote}/health`. The dashboard backend serves
neither `/health` nor `/v1` — it 302s every unknown path into the SPA, so
Desktop's probe would follow a redirect to HTML and never see `{"status":"ok"}`.
Both paths are therefore routed to `hermes-gateway` in `ingress.yaml`, where
Traefik's longest-rule-wins resolution keeps `/` on `:9119`.

Diagnose Desktop itself with its own log, not the cluster's:

```sh
journalctl --user -f | grep hermes-one
```

Useful lines: `Remote Hermes backend is ready`, `validateChatReadiness`, and
`remote-oauth-login: Remote gateway sign-in was cancelled` — the last one fires
*before* the readiness probe, because Desktop opens a bare `/login` in its
`persist:hermes-remote-oauth` webview rather than `/auth/native/authorize`. No
PKCE broker cookie means `password-login` answers `next: "/"` instead of the
loopback callback, and Desktop treats the flow as cancelled.

Session cookies from that webview live in
`~/.config/hermes-desktop/Partitions/hermes-remote-oauth/Cookies`.

## Troubleshooting

- **Everything works but generation is slow** — the model is probably on CPU.
  Ollama does not warn when it falls back: check its startup log for
  `inference compute ... library=ROCm` (good) versus `id=cpu library=cpu`
  (silent CPU fallback), and `ollama ps` for the `PROCESSOR` column. The two
  variables that decide this are documented in `../ollama/README.md`.
- **Model rejected as "below the minimum 64,000 required by Hermes Agent"** —
  `context_length` is missing or wrong in `configmap.yaml`, or the ConfigMap
  name was not bumped so the pod never picked the change up. See above.
- **`403 Forbidden` while connected to the VPN** — the hostname is missing from
  the split-horizon allowlist in `apps/wireguard/coredns-configmap.yaml`. Check
  with `dig +short hermes.sakul-flee.de @192.168.178.200`: `192.168.178.200` is
  correct, anything in `104.21.x`/`172.67.x` means it fell through to
  Cloudflare. That Corefile has the `reload` plugin, so an edit lands on its
  own within ~30s, plus up to ~60s while the `cache` plugin holds a stale
  answer. If it is *still* wrong after that, the running CoreDNS predates the
  plugin: `kubectl rollout restart deploy/wg-access-server -n wireguard`, which
  bounces every VPN tunnel for a few seconds.
- **Edits to `configmap.yaml` have no effect** — bump the ConfigMap name. See
  above; this is the single most common confusion here.
- **Config keys** — confirm what the running build actually accepts with
  `hermes config get model` before adding to managed scope.
- **WebUI streams look buffered** — if chat output arrives in bursts, the fix is
  a `ServersTransport` with a `flushInterval` on the Traefik side.
- **`GET /api/model/library` → 404 in Desktop** — Desktop 0.7.7 calls an endpoint
  backend `0.21.5` does not ship: the route is absent from `hermes_cli/` and
  from the WebUI alike, so the SPA and every other surface also lack it. Desktop
  retries it ~20× and then carries on. Version skew, documented rather than
  fixed — ignore it unless chat itself stops loading.
- **Empty `hermes-data`** — this deployment is intentionally fresh; the PVC
  never existed before, so there is nothing to migrate.
