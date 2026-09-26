# llama-swap

An OpenAI-compatible router that owns the iGPU and runs **one model at a time**,
loading it on demand and unloading it `unloadTimeout: 300`s after the last
request. llama-swap has no notion of a default model — a client names the model
it wants, so "selecting models" here means editing the `models:` map.

| URL | What |
| --- | --- |
| `https://llama-swap.sakul-flee.de/` | Web UI |
| `https://llama-swap.sakul-flee.de/v1` | OpenAI API (`/v1/models`, `/v1/chat/completions`, …) |
| `llama-swap.llama-swap.svc:8080` | ClusterIP, for in-cluster callers |

VPN-only (`wireguard-vpn-only@kubernetescrd`), `letsencrypt-production`, and
**no API key** — anything on the tunnel can use the GPU.

## The lineup (10 models)

Measured on the Rembrandt 680M through llama-swap, non-streaming, 100 output
tokens, reading llama-server's own `timings` field (see *Benchmarks lie* below).
**These are single samples and they vary ±20% run to run**; treat them as
ordering, not as promises.

| Model id (exact string for `model:`) | tok/s | prompt tok/s | Speculation | Weights |
| --- | ---: | ---: | --- | ---: |
| `MiniCPM5-2B @Q4_K_M [ngram]` | 8.9 | ~178 | ngram | 1.5G |
| `MiniCPM-V-4.6 @Q8_0 [ngram]` | 11.5 | ~113 | ngram | 0.8G + 1.1G mmproj (host) |
| `Qwen3.6 35B-A3B @UD-IQ3_S [MTP]` | 6.0 | 23 | MTP 60/76 | 13.7G |
| `Qwen3.5 9B @UD-Q4_K_XL [ngram]` | 5.2 | 30 | ngram (MTP disabled, see matrix) | 5.5G |
| `Gemma4 26B-A4B @UD-Q4_K_XL [QAT MTP]` | 4.8 | 19 | MTP 66/132 | 14.5G |
| `North-Mini-Code @UD-Q3_K_M [ngram]` | 4.4 | 43 | ngram | 8.7G |
| `Gemma4 12B @UD-Q4_K_XL [QAT MTP]` | 4.0 | 21 | MTP 64/104 | 7.0G |
| `Ornith-1.5 35B-A3B @Q2_K_L [MTP]` | 3.6 | 29 | MTP 41/170 | 13.8G |
| `Ornith-1.5 9B @Q4_K_M [MTP]` | 3.0 | 31 | MTP 74/135 | 5.5G |
| `MiMo-V2.6-Distill-9B @Q4_K_M [MTP]` | 2.0 | 28 | MTP 46/153 | 5.5G |

`MiniCPM5-2B` is the fast tier and is the outlier: it once measured **27.96
tok/s** when ngram locked onto the reasoning text and accepted 70 of 70 drafts
at a mean length of 36. It sits at 8.9 without that lock-on, so the honest
number is the slow one — the fast one is what happens when speculation lines up.

Two `500 Invalid input batch` failures per cold start are normal — see
*Cold-start MTP race* below. Every id above has been seen to generate.

### MTP / ngram matrix

| Has MTP? | Models | Flag |
| --- | --- | --- |
| **Yes** (nextn tensors or an `mtp-*.gguf` sidecar, auto-downloaded) | Gemma4 12B, Gemma4 26B, Qwen3.6 35B, Ornith 9B, Ornith 35B, MiMo 9B | `${mtp}` → `--spec-type draft-mtp` |
| **No** (nothing to speculate with — plain `llama`/`qwen35` archs) | North Mini Code, MiniCPM5-2B, MiniCPM-V-4.6 | `${ngram}` → `--spec-type ngram-mod` |
| **Has it, but runs ngram anyway** | **Qwen3.5 9B** — Hermes' default, and the only id at `-c 65536`. At 64k the cold-start draft race below is near-certain rather than occasional (5 of 6 fresh loads), and it is not self-healing: once the first decode fails the buffer never populates, so the agent's own 3 retries all land in the same broken process. See *Cold-start MTP race*. | `${ngram}` |

### mmproj matrix

`--no-mmproj-offload` is **load-bearing, not an optimization**. If a repo ships
an `mmproj-*.gguf` and the flag is absent, *text* requests die with
`invalid token[0] = 262144` (or an `Invalid input batch`), because the projector
gets allocated past the end of the GTT aperture and produces garbage embeddings.

| Ships `mmproj`? | Models | Flag |
| --- | --- | --- |
| **Yes** | Gemma4 12B, Gemma4 26B, Qwen3.5 9B, Qwen3.6 35B, Ornith 9B, Ornith 35B, **MiniCPM-V-4.6** | `${mmproj_host}` (mandatory) |
| **No** | North Mini Code, MiMo 9B, **MiniCPM5-2B** | — |

Adding a model whose repo has an `mmproj-*.gguf`? Add `${mmproj_host}`. Check:

```sh
curl -s https://huggingface.co/api/models/<repo>/tree/main \
  | jq -r '.[].path' | grep -i mmproj
```

**The vision slot is `MiniCPM-V-4.6`.** Gemma4 cannot fill it: its image path
fails with `invalid token[0] = 262144` even *with* the flag. MiniCPM-V-4.6 was
verified against a solid-red test image and answered `red`.

## Hardware: the GTT ceiling

The binding constraint is **not** the 24Gi pod limit (nowhere near reached) —
it is the **GTT aperture, 15663 MiB (15.29 GiB)**, one fixed budget that
everything on the iGPU shares: weights, KV cache, mmproj, and Vulkan's own
scratch. radv over-reports the heap as 16175 MiB, so anything computing a
margin against `VkHeap` lands ~512 MiB short of reality.

**Empirical rule: a model that starts loading with under ~600 MiB of GTT spare
fails to load.** Measured spares after a successful load: Gemma 26B 817 MiB,
Qwen3.6 708, North 1142, Ornith 35B 1512. Verified failures: Qwen3.6 IQ3_S
without `-np 1`, Ornith IQ3_XXS even at `-c 8192`, North UD-IQ4_NL, North Q3_K_M
without `-np 1` (126 MiB spare).

Read it in-pod with:

```sh
kubectl exec -n llama-swap deploy/llama-swap -- sh -c \
  'cat /sys/class/drm/card0/device/mem_info_gtt_used \
       /sys/class/drm/card0/device/mem_info_gtt_total'
#                            (bytes — total is 16424607744)
```

Levers, cheapest first: `-np 1` (drops n_slots 4→1 and divides the unified KV
budget by 4 — used by the 26B/35B class), `${mmproj_host}`, a lower `-c`, a
smaller quant. Note `-np 1` made `Qwen3.5 9B` *slower* (3.81 vs 6.05 tok/s), so
it is applied only where GTT forces it.

## Files

| File | Holds |
| --- | --- |
| `configmap.yaml` | **The model list.** This is the only file you edit to add/remove/retarget models. |
| `deployment.yaml` | Image tag, `--watch-config`, GPU device limit, the ConfigMap + PVC mounts, `memory: 24Gi` |
| `models-pvc.yaml` | 32Gi `local-path-volatile` HF cache, mounted at `/root/.cache` |
| `service.yaml`, `ingress.yaml` | `:8080` ClusterIP, the hostname + TLS |
| `../../clusters/homelab/apps/llama-swap.yaml` | Flux Kustomization (`interval: 30m`, `wait: true`, `prune: true`) |

## Changing the model list

1. **Edit `models:` in `apps/llama-swap/configmap.yaml`.** The map key is the
   exact id clients pass to `model:`, e.g.
   `"Qwen3.5 9B @UD-Q4_K_XL [MTP]"`. Each entry expands the `macros:` above it
   and needs:

   - `${PORT}` **somewhere in `cmd`** — llama-swap rejects the whole reload with
     `proxy uses ${PORT} but cmd does not` if it is missing.
   - `-hf <repo>:<quant>` to fetch from Hugging Face into the PVC. First load
     downloads. **Download one model at a time** — two concurrent ~14G
     downloads plus a loaded model push the pod past its 24Gi limit and it gets
     OOMKilled.
   - `${base}` (or the explicit equivalent) — llama-server, `--host`, `--port`,
     `-fa on`, `-fit on`.
   - `${ctx_m}` (32k) or `${ctx_l}` (16k), `${mtp}` or `${ngram}`, and
     `${mmproj_host}` if the repo ships an mmproj (see the matrix above).

2. **Validate before pushing** (the image's own validator):

   ```sh
   python3 -c 'import yaml;print(yaml.safe_load(open("apps/llama-swap/configmap.yaml"))["data"]["config.yaml"],end="")' \
     > /tmp/llama-swap.yaml
   docker run --rm --entrypoint /app/llama-swap \
     -v /tmp/llama-swap.yaml:/cfg.yaml:ro \
     ghcr.io/mostlygeek/llama-swap:v258-vulkan-b11176 -config /cfg.yaml -validate
   ```

   `config is valid: 10 model(s), 0 peer(s)` is what success looks like.
   `--entrypoint` matters: the image bakes `-config /app/config.yaml
   -watch-config` into its entrypoint, so plain `docker run IMG …` appends
   after them instead of replacing them.

3. **Commit and push.** Origin is Forgejo, which mirrors to GitHub — Flux pulls
   the GitHub copy, so the commit shows up there on its own.

   **Push before you test.** Flux reconciles every 30m and reverts anything
   local-but-unpushed; a reload mid-download kills the load with
   `unspecific error: group is shutting down`. An uncommitted edit will be
   reverted out from under you roughly half an hour in.

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

**A reload does not restart an already-resident model.** It keeps running with
its old command line. If you change a model's flags, unload it first (or wait
out `unloadTimeout`) or you will be testing the old arguments against the new
config — that shows up as a 500 that the config does not explain.

**A broken config does not take the service down.** llama-swap parses the new
file itself and logs `failed to reload config: …`, keeping the previous config
active — so `grep failed` in step 4 is the real pass/fail signal, not the
absence of an error from Flux (Flux only validates the manifest, not the YAML
*inside* the block scalar).

Edits to `deployment.yaml` are different: those roll the pod, and `strategy:
Recreate` means a short outage while it starts.

## Cold-start MTP race

**The first request after a cold load fails intermittently on MTP models** with
a plain `500` and `{"error":{"code":500,"message":"Invalid input batch."}}`.
Roughly two in three cold starts. `ngram` models (North, both MiniCPM) are
immune.

```
E init: invalid token[0] = 248320     <- garbage, not a real token
E spec draft: llama_decode[1] returned -1
E srv decode: Invalid input batch.
```

It is a timing race, not a config fault: the model decodes the whole prompt
correctly, then the *draft's* `llama_decode` fails. llama-swap's health check
only probes `/health`, which makes the client's first request the draft's very
first decode. It reproduces with 50 ms readiness polling and never with a 1 s
poll, which is exactly why it looked random.

**It is not self-healing.** Once the first decode fails, the draft's input
buffer is never populated, so *every* subsequent request in that llama-server
process fails until llama-swap unloads it. A client retry lands in the same
broken process and fails again — confirmed through Hermes, whose three built-in
retries (2.2s, 5.6s backoff) all hit `Invalid input batch` on the same id.

**Getting out of a broken process:** load any other model (llama-swap unloads
the current one to do it), or wait out `unloadTimeout: 300`, then retry. Plain
retrying does nothing.

**Qwen3.5 — Hermes' default — was moved off MTP to `${ngram}`** for exactly
this reason: it is the only id at `-c 65536` (Hermes requires ≥64K), and at
64k the race is near-certain rather than occasional — 5 of 6 requests after a
fresh load failed, against an occasional failure at 32k. The larger KV
allocation plausibly widens the race window. The id was renamed
`[MTP]` → `[ngram]` so it does not lie about what it runs; its MTP line
(`${mtp}` + `--spec-draft-n-max 6`, 81/106 accepted) is recorded in the config
for when this is fixed upstream. An agent that answers is worth more than the
~15% the draft bought.

**`-fit on` was investigated and left in.** Dropping it from the shared `base`
macro measured 8/8 clean against 2/4 failing in isolation, which looked like a
fix — but it was never confirmed end-to-end, it changed *every* model including
both Gemmas (known good with it), and it reported "no changes needed" for all of
them anyway. It sits in the shared macro for a reason. Do not remove it to chase
this bug without re-testing cold starts through llama-swap. The config's
`base` macro carries the same note.

The remaining honest alternatives: upgrade the llama.cpp build past b11176, or
move the other MTP ids to `${ngram}` too if a flaky first request ever matters
more than the draft's speedup.

## Benchmarks lie

**Do not count SSE chunks.** Streaming responses arrive in wildly variable
chunks — 120 tokens produced 86 to 268 events in testing, so a chunk-counting
harness measured a 3.04 tok/s model as **47 tok/s**. It is not a small error.

Measure non-streaming and read llama-server's own `timings` from the JSON
response (`prompt_per_second`, `predicted_per_second`), or read the
`print_timing` lines in the pod log:

```sh
kubectl logs -n llama-swap deploy/llama-swap | grep print_timing
```

**Every model here is a reasoning model.** Text goes into `reasoning_content`
and `content` comes back `""` with `finish_reason: "length"` until the budget
exceeds the thought (reproduced at 5 and 15 tokens). A reader that only checks
`content` reports a false "no tokens". All numbers above were taken from
`reasoning_content`.

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

It must leave `0` for as long as tokens are being produced. `Vulkan0: AMD
Radeon 680M (RADV REMBRANDT)` should be the only entry of `--list-devices`.

Also check it is not being shared:

```sh
kubectl exec -n llama-swap deploy/llama-swap -- sh -c \
  'ls -l /dev/dri/renderD128'   # holders need fuser, which is absent in the image
```

When idle: `mem_info_gtt_used` around 13 MiB, `gpu_busy_percent` `0`, no
transcode or other consumer on `renderD128`.

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
- **`500 Invalid input batch`** — first see *Cold-start MTP race* above; a
  retry clears it. If it recurs on a warm model, capture the request body
  before blaming the config. A `500` whose body is `json.exception.parse_error`
  is a malformed *request*, not a server fault — llama-server reports bad JSON
  as a 500 rather than a 400.
- **`unspecific error: group is shutting down`** — llama-swap reloaded the
  config while the model was loading, killing it. Almost always Flux applying a
  commit that does not match the cluster (i.e. you edited locally without
  pushing), or a config apply landing mid-download. Push, re-apply, retry.
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
- **`models-pvc.yaml` says 32Gi** — that is a *declaration*, not an enforced
  quota: `local-path-volatile` does not honour it, and `df` inside the pod
  reports the backing disk (932G, ~126G used). The old claim that 32Gi cannot
  hold the whole lineup is false. Still true: two concurrent 14G downloads blow
  the **24Gi memory** limit, not the disk.
- **`memory: 24Gi` in `deployment.yaml`** — lowered from 40Gi (the node has
  30.6Gi total, so 40Gi could never be reached). 24Gi leaves the llama-server
  process and its downloads room while keeping the pod off the node's OOM
  killer. If the pod is OOMKilled, look for concurrent downloads first.
- **`logToStdout: "both"`** — the config forwards llama-server's own log lines
  to the pod log alongside llama-swap's. `print_timing`, `draft acceptance`, and
  the `E init:`/`E spec draft:` race messages above are only visible because of
  it. Turning it off makes the race undiagnosable.
- **`[unsloth] Qwen3.5 9B @Q4_K_XL [MTP]` loaded the wrong weights** — fixed.
  Its `cmd` used to point at `unsloth/Qwen3.6-35B-A3B-MTP-GGUF`, the same repo
  as the Qwen3.6 entry, so both ids downloaded one 35B-A3B model. It now points
  at its own repo and is measured at 5.2 tok/s.

## Pointing another app at it

In-cluster base URL is `http://llama-swap.llama-swap.svc:8080/v1` with **no**
`Authorization` header — llama-swap does not check one. Set `model.default` to
an exact id from `GET /v1/models` (ids contain spaces and brackets, so quote
them). Renaming an id in `configmap.yaml` breaks any caller pinned to the old
string.

Hermes is configured this way in `apps/hermes/configmap.yaml`; see that
README's *Unsloth* section for how to move it back.

**Budget for reasoning.** The QAT/MTP builds think first and put it in
`reasoning_content`, so a tight `max_tokens` can come back with
`content: ""` and `finish_reason: "length"` — reproduced at 5 and 15 tokens on
a Gemma, while 10 tokens happened to answer directly. Read that combination as
"raise `max_tokens`", not as a server fault.

**Budget for the cold start too.** The first request after an idle period also
pays for the load (up to ~45s for the 14G models) and may need one retry for
the race above.
