# llama-swap

An OpenAI-compatible router that owns the iGPU and runs **one model at a time**,
loading it on demand and unloading it `unloadTimeout: 10`s after the last
request. llama-swap has no notion of a default model — a client names the model
it wants, so "selecting models" here means editing the `models:` map.

| URL | What |
| --- | --- |
| `https://llama-swap.sakul-flee.de/` | Web UI |
| `https://llama-swap.sakul-flee.de/v1` | OpenAI API (`/v1/models`, `/v1/chat/completions`, …) |
| `llama-swap.llama-swap.svc:8080` | ClusterIP, for in-cluster callers |

VPN-only (`wireguard-vpn-only@kubernetescrd`), `letsencrypt-production`, and
**no API key** — anything on the tunnel can use the GPU.

## Files

| File | Holds |
| --- | --- |
| `configmap.yaml` | **The model list.** This is the only file you edit to add/remove/retarget models. |
| `deployment.yaml` | Image tag, `--watch-config`, GPU device limit, the ConfigMap + PVC mounts |
| `models-pvc.yaml` | 32Gi `local-path-volatile` HF cache, mounted at `/root/.cache` |
| `service.yaml`, `ingress.yaml` | `:8080` ClusterIP, the hostname + TLS |
| `../../clusters/homelab/apps/llama-swap.yaml` | Flux Kustomization (`interval: 30m`, `wait: true`, `prune: true`) |

## Changing the model list

1. **Edit `models:` in `apps/llama-swap/configmap.yaml`.** The map key is the
   exact id clients pass to `model:`, e.g.
   `"[unsloth] Gemma4 E4B @UD-Q4_K_XL [QAT] [MTP]"`. Each entry expands the
   `macros:` above it and needs:

   - `${PORT}` **somewhere in `cmd`** — llama-swap rejects the whole reload with
     `proxy uses ${PORT} but cmd does not` if it is missing.
   - `-hf <repo>:<quant>` to fetch from Hugging Face into the PVC. First load
     downloads (≈84s for the 5.0G E4B), later loads are cold-start only.

2. **Validate before pushing** (the image's own validator):

   ```sh
   python3 -c 'import yaml;print(yaml.safe_load(open("apps/llama-swap/configmap.yaml"))["data"]["config.yaml"],end="")' \
     > /tmp/llama-swap.yaml
   docker run --rm --entrypoint /app/llama-swap \
     -v /tmp/llama-swap.yaml:/cfg.yaml:ro \
     ghcr.io/mostlygeek/llama-swap:v258-vulkan-b11176 -config /cfg.yaml -validate
   ```

   `config is valid: 7 model(s), 0 peer(s)` is what success looks like.
   `--entrypoint` matters: the image bakes `-config /app/config.yaml
   -watch-config` into its entrypoint, so plain `docker run IMG …` appends
   after them instead of replacing them.

3. **Commit and push.** Origin is Forgejo, which mirrors to GitHub — Flux pulls
   the GitHub copy, so the commit shows up there on its own.

4. **Reconcile and watch it land:**

   ```sh
   flux reconcile kustomization llama-swap --with-source
   kubectl logs -n llama-swap deploy/llama-swap -f | grep -E 'reload|failed'
   curl -s https://llama-swap.sakul-flee.de/v1/models | jq -r '.data[].id'
   ```

**No pod restart.** The ConfigMap is mounted as a whole directory (no
`subPath`), so kubelet swaps the file in place and `--watch-config` (2s poll)
picks it up. Measured end-to-end: edit → new model listed in **9–45s**, the
spread being kubelet's ConfigMap sync period (up to ~60s). Pod restart count
stays 0 and the loaded model is not disturbed.

**A broken config does not take the service down.** llama-swap parses the new
file itself and logs `failed to reload config: …`, keeping the previous config
active — so `grep failed` in step 4 is the real pass/fail signal, not the
absence of an error from Flux (Flux only validates the manifest, not the YAML
*inside* the block scalar).

Edits to `deployment.yaml` are different: those roll the pod, and `strategy:
Recreate` means a short outage while it starts.

## Bumping llama-swap

The tag is pinned, not floating: `ghcr.io/mostlygeek/llama-swap:vNNN-vulkan-bNNNNN`,
where `NNNNN` is the bundled llama.cpp build (`--version` prints `v258 (69cb75a)`,
and responses carry `"system_fingerprint":"b11176-…"`).

Do **not** go back to `:vulkan`: it is a moving tag while `imagePullPolicy` is
`IfNotPresent`, so the node never re-pulls and the pod silently freezes on
whatever it first fetched — that combination had it stuck on `v251`/b10603 from
August 24 while the tag had moved to `v258`/b11176. Bump both halves of the
tag together.

Edit the tag in `deployment.yaml`, push, reconcile — do not `kubectl set image`
to shortcut it, Flux owns that field and reverts it at the next interval.
Confirm afterwards with
`kubectl exec -n llama-swap deploy/llama-swap -- /app/llama-swap --version`.

## Verifying the GPU is actually used

```sh
# while a generation is streaming:
watch -n1 kubectl exec -n llama-swap deploy/llama-swap -- \
  cat /sys/class/drm/card0/device/gpu_busy_percent
```

It must leave `0` for as long as tokens are being produced. Reference numbers
on the Rembrandt 680M, Gemma4 E4B @UD-Q4_K_XL: **37.6 tok/s** generated, 83
tok/s prompt, MTP accepting 227 of 513 draft tokens, 7.1G held in
`mem_info_gtt_used`, 100% `gpu_busy_percent`. `Vulkan0: AMD Radeon 680M (RADV
REMBRANDT)` should be the only entry of `--list-devices`.

## Troubleshooting

- **Pod stuck `Pending`, `Insufficient devic.es/dri`** — the node advertises
  `devic.es/dri: 0` (and `devic.es/rocm: 0`), which happens after the node
  flaps `NodeNotReady`: kubelet loses the device-plugin registration and the
  plugin does not re-register on its own. Pods already running keep their
  allocations, so nothing else is disturbed — just roll it:

  ```sh
  kubectl rollout restart ds/generic-device-plugin -n kube-system
  kubectl get node homelab -o jsonpath='{.status.allocatable.devic\.es/dri}'   # expect 4
  ```

  Capacity is `4`, not 8: the DaemonSet declares a second group for
  `/dev/dri/card1` + `renderD129`, which this node does not have (only
  `card0`/`renderD128` exist), so only the first group's `count: 4` registers.
- **`500 Invalid input batch`** — seen once during the v258 rollout and not
  reproduced in the 30 valid requests that followed (sequential, 8-way
  concurrent, and two retries of the exact failing payload). Retry; if it
  recurs, capture the request body before blaming the config. A `500` whose
  body is `json.exception.parse_error` is a malformed *request*, not a server
  fault — llama-server reports bad JSON as a 500 rather than a 400.
- **`403 Forbidden` while connected to the VPN** — the hostname fell out of the
  split-horizon allowlist in `apps/wireguard/coredns-configmap.yaml` (A, AAAA
  *and* HTTPS templates; `llama-swap` is currently in all three). See
  `apps/hermes/README.md` for the `dig` check.
- **A model id vanished or never appears** — `grep failed` on the pod log for
  `failed to reload config`. Common causes: two entries with the same key, a
  missing `${PORT}`, or a YAML error inside the block scalar. Also note the
  config's last line has no trailing newline in git — anything appending to the
  file programmatically must add one itself, or it fuses into the previous
  `-hf` line.
- **Where the weights live** — the PVC is mounted at `/root/.cache`, not
  `/app/models`; the HF blobs sit under
  `/root/.cache/huggingface/hub/models--…`.
- **PVC fills up** — 32Gi cannot hold all seven models: only the E4B (5.0G)
  has been downloaded so far, and the other six are 9B or larger. Delete blobs
  under `/root/.cache/huggingface/hub/` from inside the pod, or grow
  `models-pvc.yaml` (the backing disk has 378G free).
- **`memory: 40Gi` limit exceeds the node** — the node has 30.6Gi total, so the
  limit can never be reached; it is the 4Gi *request* that is scheduled. Set
  the limit below 30Gi if OOM behaviour should ever matter.
- **`[unsloth] Qwen3.5 9B @Q4_K_XL [MTP]` loads the wrong weights** — its `cmd`
  points at `unsloth/Qwen3.6-35B-A3B-MTP-GGUF`, the same repo as the Qwen3.6
  entry, so both ids download one 35B-A3B model. Untested and unfixed on
  purpose: pick the correct repo before trusting that id.

## Pointing another app at it

In-cluster base URL is `http://llama-swap.llama-swap.svc:8080/v1` with **no**
`Authorization` header — llama-swap does not check one. Set `model.default` to
an exact id from `GET /v1/models` (ids contain spaces and brackets, so quote
them). Renaming an id in `configmap.yaml` breaks any caller pinned to the old
string.
