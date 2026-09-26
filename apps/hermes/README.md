# Hermes + llama-swap

Two Flux Kustomizations that ship together:

| URL | Backend | Port |
| --- | --- | --- |
| `https://hermes.sakul-flee.de/` | Hermes WebUI | 8787 |
| `https://hermes.sakul-flee.de/v1` | Gateway OpenAI API | 8642 |
| `https://hermes-dashboard.sakul-flee.de/` | Monitoring dashboard | 9119 |
| `https://hermes-dashboard.sakul-flee.de/health` | Gateway liveness probe | 8642 |
| `https://hermes-dashboard.sakul-flee.de/v1` | Gateway OpenAI API | 8642 |
| `http://llama-swap.llama-swap.svc:8080/v1` | **model backend** (ClusterIP, no ingress) | 8080 |
| `https://unsloth.sakul-flee.de/` | Unsloth Studio — **scaled to 0** | 8000 |
| — | Unsloth JupyterLab (ClusterIP only) — scaled to 0 | 8888 |

All hostnames are VPN-only (`wireguard-vpn-only@kubernetescrd`) and use
`letsencrypt-production`.

## The backend is llama-swap, not Unsloth

Hermes sends chat to `http://llama-swap.llama-swap.svc:8080/v1` with
`model.provider: custom` and no API key (llama-swap checks none; it sits behind
the same VPN reachability). Both keys are pinned in managed scope —
`apps/hermes/configmap.yaml`, mounted read-only at
`/etc/hermes/config.yaml`, where it wins over `~/.hermes/config.yaml`.

- **`model.base_url`** — llama-swap's ClusterIP.
- **`model.default`** — `"Qwen3.5 9B @UD-Q4_K_XL [ngram]"`. It is pinned to a
  llama-swap id, not an HF path, because the stored default
  (`unsloth/North-Mini-Code-1.0-GGUF:UD-IQ4_NL`) would 404 against llama-swap's
  model list. The other nine ids are in `apps/llama-swap/README.md`.

**Managed scope wins, so the dashboard cannot change this.** *Change* in the
dashboard writes `model.default`, but the pinned key overrides it — use
`hermes config get model` to see what is actually in effect. To retarget the
agent, edit the ConfigMap.

**Expect a cold-start delay and one retry.** llama-swap runs one model at a
time and loads on demand (up to ~45s for the 14G models), unloading 300s after
the last request. Its first request after idle can also fail with a plain
`500 Invalid input batch` — a known MTP draft race, documented in
`apps/llama-swap/README.md`, cleared by retrying. None of this applies while
Unsloth is the backend.

## Putting Unsloth back

Unsloth Studio is scaled to 0 — its `:studio` image, ROCm bundle and API key
are all still in place, it just is not scheduled. To go back:

1. In `apps/hermes/configmap.yaml`, swap the `model:` block for:

   ```yaml
   model:
     provider: custom
     base_url: http://unsloth-studio.unsloth.svc:8000/v1
     api_mode: chat_completions
     api_key: "${UNSLOTH_API_KEY}"
   ```

2. **Bump the ConfigMap name** (`-v2` → `-v3`). A value edit alone does not
   restart the pod; a changed name does, and the mount is read-only.
3. Re-encrypt `apps/hermes/secrets` if `UNSLOTH_API_KEY` is gone — Studio only
   stores a hash of it, so it cannot be read back (see step 3 of *Bootstrap
   order*).
4. Scale the deployment back up:
   `kubectl scale deploy/unsloth-studio -n unsloth --replicas=1`.

Hermes's *own* memory limit was reduced 40Gi → 24Gi while doing this (the node
has 30.6Gi total, so 40Gi could never be reached). The `hermes-data` PVC is
untouched at 32Gi.

**Adding a hostname means editing three files, not two.** The ingress has to be
paired with a `match` label in `apps/wireguard/coredns-configmap.yaml` — the A,
AAAA *and* HTTPS templates. A name left out resolves through the proxied
`*.sakul-flee.de` wildcard, so Traefik sees a Cloudflare edge IP instead of the
client's `100.64.0.x` tunnel address and answers `403 Forbidden` even to a
connected VPN client.

JupyterLab is deliberately **not** in that list: it has no ingress. Reach it
with `kubectl port-forward -n unsloth svc/unsloth-jupyter 8888:8888`
(`JUPYTER_PASSWORD` from SOPS guards the login). Its `--notebook-dir` is
`/workspace`, which is re-cloned from GitHub on every pod boot — save work under
`/workspace/host` (the `unsloth-work` PVC) or it disappears on restart.

The agent's model provider is pinned in managed scope
(`apps/hermes/configmap.yaml`, mounted read-only at `/etc/hermes/config.yaml`),
which wins over `~/.hermes/config.yaml` — but only per key, so `model.default`
(the concrete model id) remains editable from the dashboard.

## Bootstrap order

Only required when **Unsloth** is the backend — steps 2–4 are meaningless
against llama-swap, which needs no API key. The current state is the llama-swap
backend with Unsloth scaled to 0.

1. **Push** this branch; Flux applies `unsloth`/`unsloth-secrets` and
   `hermes`/`hermes-secrets` in parallel. Each app Kustomization creates its
   namespace, so the sibling `-secrets` Kustomization retries every 2m until it
   exists — that is deliberate, a `dependsOn` between them would deadlock on a
   fresh cluster.
2. **Unsloth password** — the container starts with a password from SOPS, so no
   interactive setup is needed. Read it with:

   ```sh
   sops -d apps/unsloth/secrets/secret.enc.yaml
   ```

   Open `https://unsloth.sakul-flee.de`, sign in, then load a model. Note the
   id `GET /v1/models` returns afterwards.
3. **Create the API key** in Studio → *Settings → API* (Studio only stores a
   hash, so it cannot be read back later).
4. **Hand it to Hermes** and re-encrypt:

   ```sh
   sops apps/hermes/secrets/secret.enc.yaml   # replace UNSLOTH_API_KEY, save
   ```

   `sops` re-encrypts on save; commit the result. Until this step the agent
   gets `401 Unauthorized` from Unsloth — that is the expected signal.
5. **Pick a model.** On the llama-swap backend `model.default` is **pinned** in
   managed scope, so the dashboard's *Change*, `hermes model`, and
   `hermes config set model.default <id>` all write a value the mounted config
   overrides — see *The backend is llama-swap* above. To actually change it,
   edit `apps/hermes/configmap.yaml` and bump the ConfigMap name (`-v2` →
   `-v3`); a value edit alone does not restart the pod. On the restored Unsloth
   backend the key is unpinned again and any of the three works — the old
   working default was `ornith-ai/Ornith-1.5-9B-GGUF` (`Q4_K_M`).
6. **Smoke test** from inside the VPN:

   ```sh
   curl -H "Authorization: Bearer $API_SERVER_KEY" \
        https://hermes.sakul-flee.de/v1/models
   ```

## Adding a cloud provider later

Replace the `model:` block in `apps/hermes/configmap.yaml` and add the new key
to `apps/hermes/secrets`. Bump the ConfigMap name (`-v1` → `-v2`) as well:
editing values in place does not restart the pod, a changed name does.

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

- **`403 Forbidden` while connected to the VPN** — the hostname is missing from
  the split-horizon allowlist in `apps/wireguard/coredns-configmap.yaml`. Check
  with `dig +short unsloth.sakul-flee.de @192.168.178.200`: `192.168.178.200` is
  correct, anything in `104.21.x`/`172.67.x` means it fell through to
  Cloudflare. If the answer is stale after an edit, CoreDNS has no `reload`
  plugin in that Corefile — `kubectl rollout restart deploy/wg-access-server -n
  wireguard`, which bounces every VPN tunnel for a few seconds.
- **Container exits immediately with status 0** — the tag matters. `:latest`
  is the base image and its CMD is `python`, which hits EOF and exits. Use
  `unsloth/unsloth-rocm:studio` (supervisord launches Studio on 8000 and
  JupyterLab on 8888).
- **`/dev/kfd` EPERM** — the container device cgroup denies it unless the pod
  requests `devic.es/rocm`; hostPath alone is not enough. The group is defined
  in `apps/gpu-device-plugin/daemonset.yaml`, so that DaemonSet must be rolled
  out before Unsloth can start.
- **ROCm missing from *Compute backend*, everything runs on CPU** — the node's
  card is an AMD Rembrandt iGPU (`1002:1681`, **gfx1035**), and Unsloth's
  published `rocm-gfx103X` bundle carries kernels only for
  `gfx1030/1031/1032/1034` (their #7624 deliberately omits the gfx1033/1035/1036
  iGPUs). The picker then reports `no_prebuilt` and hides ROCm, and
  `HSA_OVERRIDE_GFX_VERSION` alone does not bring it back — the installer never
  selects the asset in the first place. Two env vars fix it:
  `UNSLOTH_ROCM_GFX_ARCH: "gfx1030"` chooses the bundle and
  `HSA_OVERRIDE_GFX_VERSION: "10.3.0"` (the value Unsloth's own startup banner
  recommends) lets its code objects load on gfx1035. Confirm with
  `rocm-smi --showuse` *while generating* — `GPU use (%)` must leave 0.
  Do **not** set `UNSLOTH_LLAMA_CPP_BACKEND`: it pins the runtime and makes
  `POST /api/llama/backend` refuse to switch with `environment_override`.
- **Vulkan is not a fallback either** — the image ships the loader
  (`libvulkan1`) but no ICD: `mesa-vulkan-drivers` is absent, so
  `/usr/share/vulkan` does not exist and the probe logs *"the Vulkan probe
  reported no device"* before planning a CPU-only load. Switching to Vulkan
  installs cleanly and still runs on the CPU.
- **ROCm silently lost after a pod restart** — the managed dir
  `/opt/unsloth-studio/llama.cpp` is a link into `/opt/unsloth-studio-app`,
  which is container layer and dies with the pod, taking a freshly installed
  404 MB bundle with it. `unsloth-studio-home` re-links that path at every start
  (it even moves a user-made link aside), so the link cannot be retargeted.
  `UNSLOTH_LLAMA_CPP_PATH` names a directory on the `unsloth-studio` PVC
  instead, and the `seed-llamacpp` initContainer fills it — the resolver only
  accepts a candidate containing `llama-server`, so an empty directory would
  fall through to the overlay. The seed is one-off and guarded: its logs should
  read `reusing the ROCm install already on the PVC` on every boot after the
  first.
- **Silent CPU fallback** — `UNSLOTH_ALLOW_CPU=0` makes a missing GPU fail
  loudly instead of serving from CPU. Set it to `1` as a stop-gap only.
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
