# ollama

ROCm-accelerated model server. Replaces the llama-swap + Unsloth pair; the
public WebUI is Open-WebUI (see `../open-webui/`), which talks to this over
the cluster network.

## Layout

| File | Purpose |
|---|---|
| `models-pvc.yaml` | 32Gi `local-path-volatile` store at `/root/.ollama` |
| `deployment.yaml` | The ROCm traps live here — read the comments |
| `service.yaml` | ClusterIP `ollama.ollama.svc:11434` |
| `ingress.yaml` | `ollama.sakul-flee.de`, VPN-only via Traefik |

## Why Ollama and not llama-swap

llama-swap served a model that answered every prompt with the single token
`))))))))` and reported draft acceptance `1.00000` — the ngram draft
matching perfectly because it was drafting garbage. It does not recover on
its own: `ttl` evicts on idle, and a wedged model that keeps being retried
never goes idle, so recovery required an explicit unload.

The same weights on Ollama's ROCm runner produced 40/40 clean turns across
8 conversations, and 16/16 on CPU. The model was never the problem. llama-swap
was running an older bundled llama.cpp (`0.5.0-dev`, build 11176) against
Ollama's `0.4.1-dev`; the AMD-maintained `rocm` images for llama-swap exist
but the Vulkan build it was pinned to was the fault, not the hardware.

The documented trigger was a Vulkan context loss, and standing up a second
process on the device reliably caused one. This node has 26Gi of RAM with a
15.29Gi GTT aperture carved out of it, so a second 15Gi consumer does not
fail politely — it starves the node. 51 containers were OOMKilled at one
point, including `coredns`, `traefik`, and every Flux controller. Ollama is
now the only GPU compute consumer here. Jellyfin also holds
`devic.es/dri`, but that is VA-API on the video engine and takes tens of MB;
it has never been a factor.

## ROCm on this APU

Two environment variables are load-bearing, and **both fail silently** —
Ollama serves correct-looking responses on CPU with no error in either case.
If generation is unexpectedly slow, check these before anything else:

- `OLLAMA_IGPU_ENABLE=1` — without it Ollama logs `dropping integrated GPU`
  and skips the 680M because it is also the display device. **One G:
  `IGPU`, not `IGGPU`.** A misspelling is treated as an unknown variable and
  ignored, so the GPU is dropped with no warning whatsoever — that typo
  shipped here once before being caught.
- `HSA_OVERRIDE_GFX_VERSION=10.3.0` — `gfx1035` is absent from the ROCm 6.x
  JIT table. The override claims the `gfx1030` sibling; same RDNA2 ISA, so
  the kernels are correct. Verified twice on this hardware.

`/dev/kfd` is `EPERM` via `hostPath` alone — the container device cgroup
denies it even as root, so `devic.es/rocm` must be requested alongside
`devic.es/dri`.

### Confirming the GPU is actually in use

```bash
kubectl exec -n ollama deploy/ollama -- ollama ps      # PROCESSOR column
```

`100% GPU` is the answer. `CPU` means one of the two traps above is back.
`ollama ps` also shows the context length and the KV cache size, which is
how you confirm a model actually loaded instead of being silently refused.

## Hybrid SSM models are broken on this ROCm build

**`minicpm-v4.6` cannot generate on the GPU.** It loads, reports `100% GPU`,
answers `/health`, and then emits one token forever:

```
$ curl -s localhost:11434/api/generate -d '{"model":"minicpm-v4.6", ...}'
prediction aborted, token repeat limit reached
```

The repeat guard is Ollama's own, in `llm/llama_server.go`: it aborts after
100 consecutive identical streamed chunks. Unfiltered, the model emits `!`
at `temperature: 0, top_k: 1` — it is not sampling badly, it is confidently
wrong. Same result at temperature 0, 0.7 and 1.5, on `/api/generate` with
`raw: true` (no chat template involved) and on `/api/chat`.

The cause is the architecture. From the GGUF metadata:

```
qwen35.ssm.conv_kernel          = 4        qwen35.ssm.inner_size  = 2048
qwen35.ssm.state_size           = 128      qwen35.ssm.group_count = 16
qwen35.block_count              = 24
qwen35.full_attention_interval  = 4
```

This is a **hybrid state-space (Mamba-style) + attention** model: of 24
layers only every 4th is full attention, the other 18 are SSM. Proved by
A/B on the identical weights:

| | |
|---|---|
| GPU (`100% GPU`) | degenerate, one repeated token |
| CPU (`100% CPU`, `OLLAMA_LLM_LIBRARY=cpu`) | coherent, correct `<think>` block, correct answer |

So the weights and the quant are fine — the **ROCm/HIP kernel path for this
architecture is broken**. Two unrelated architectures were clean on the same
GPU in the same session, which rules out the serving stack, the ROCm setup
and the model store:

| Model | Arch | Result |
|---|---|---|
| `minicpm-v4.6` | `qwen35` (hybrid SSM) | degenerate |
| `north-mini-code-1.0` | `cohere2moe` | `GPU OK` |
| `SparkLLM/Spark-X2.5-4B` | `spark2_5` | `GPU OK` |

**Treat any hybrid-SSM architecture as unusable here** until the ROCm build
fixes it. `nemotron_h` is the same shape (`ssm.*` keys) and is in Ollama's
MTP/scheduling list alongside `qwen35`, so assume it is affected too. This is
not fixable from this repo — it needs an upstream llama.cpp/ROCm fix. If a
model you want is hybrid-SSM, the only working option is running it on CPU,
which is not worth it for a model this small.

## `num_ctx` can take the whole node down

`num_ctx` allocates a KV cache proportional to context, and on an APU that
cache is host RAM carved from the 15.29Gi aperture. It is not a rounding
error. Measured on this node:

| Request | Node memory | Outcome |
|---|---|---|
| `Spark-X2.5-4B` @ `num_ctx 65536` | ~11.5Gi peak | fine, `100% GPU` |
| `north-mini-code-1.0` (30.5B) @ `num_ctx 65536` | **>30Gi** | node exhausted |

The 30.5B at 64K drove the node to 29/30Gi used with load average **153**.
The k3s apiserver stopped completing TLS handshakes, so `kubectl` was dead,
and Prometheus was OOMKilled. It recovered on its own ~5 minutes later when
Ollama's `OLLAMA_KEEP_ALIVE` unloaded the model — no intervention needed, but
nothing could be managed in the meantime.

**Estimate the KV cache before raising `num_ctx`.** As a rule of thumb, f16 KV
cache is roughly `2 x layers x kv_heads x head_dim x 2 bytes x num_ctx`, and
whatever does not fit the aperture is added to host RAM on top of the weights.
For a 30.5B at 64K that is single-digit GiB of cache *plus* 18GB of weights on
a 30Gi node — it was never going to fit.

The `memory: 16Gi` limit in `deployment.yaml` exists to convert this from a
node-wide outage into a contained container OOM. Do not raise it.

## Constraints worth respecting

- **15.29Gi aperture, one model at a time.** `OLLAMA_MAX_LOADED_MODELS=1`.
  radv over-reports the heap by ~512Mi, so a load needs ~600Mi of slack or
  it fails. Large quants may need a smaller size or a lower `num_ctx`; this
  has not been tested.
- **`OLLAMA_KV_CACHE_TYPE` stays unset.** Setting `q8_0` collapses MTP draft
  acceptance to zero and throughput drops *below* the un-speculated
  baseline. f16 is the default and the reason speculation is worth having.
- **Nothing else may claim the GPU while a model is resident.** See above.

## Importing models

Models are imported through Open-WebUI, not pre-seeded here — the store
starts empty.

### Hermes needs `num_ctx 65536` at import

This is the one thing that is easy to miss. Ollama's default context is
**4096**, and its startup log says so outright:

```
msg="vram-based default context" total_vram="15.3 GiB" default_num_ctx=4096
```

Hermes refuses to run against anything smaller than 64K:

> ... has a context window of 32,768 tokens, which is below the minimum
> 64,000 required by Hermes Agent

`apps/hermes/configmap.yaml` sets `context_length: 65536` to override what
Hermes *believes* the window is, because Ollama's `/v1/models` omits
`max_model_len` exactly as llama-swap's did. But that override only declares
intent — Ollama still has to be willing to allocate the context. So any model
Hermes drives has to be created with:

```
PARAMETER num_ctx 65536
```

`OLLAMA_CONTEXT_LENGTH` would set this globally and is deliberately not set: it
would make every casual Open-WebUI chat reserve a 64K KV cache, and on a
15.3GiB aperture that is the difference between a 35B quant loading and not.
Per-model is the right granularity. `ollama ps` prints the context size the
model actually got, so check it after the first load.

### Do not add a TEMPLATE line

Importing a GGUF with `ollama create` reads `tokenizer.chat_template` from
the file itself, so **do not hand-write a `TEMPLATE` line** to the Modelfile.
`ollama create` always writes a `TEMPLATE {{ .Prompt }}` line into the
generated Modelfile regardless, and that line is inert: Ollama renders with
the GGUF's own template. `minicpm-v4.6` carries a real Jinja template
(`tokenizer.chat_template`, with `enable_thinking` handling) and renders
correctly on CPU with the auto-generated line in place. Supplying your own
template that does not match the model is what breaks output.

Vision projectors **are** kept on import when the GGUF ships one —
`minicpm-v4.6` retains its `clip` projector and reports a `vision`
capability.

### MTP speculation is opt-in

Ollama supports MTP (`--spec-type draft-mtp`) for Qwen3.5/3.6, Gemma4 and
friends, but `server/routes.go` forces `DraftNumPredict = 0` unless you ask
for it. There is no environment variable and no `LLAMA_ARG_SPEC_*` passthrough
— the request or the Modelfile is the only route. Add to the Modelfile:

```
PARAMETER draft_num_predict 4
```

Auto-detected from the GGUF (`nextn_predict_layers > 0`, or `qwen35`/`qwen35moe`
architecture with `mtp.*` tensors); no separate draft model is needed.

**Ollama has no ngram speculation.** llama-swap used `[ngram]` for MiniCPM5-2B
and North-Mini-Code, and it was worth a great deal: 8.9 → 27.96 tok/s at
70/70 accepted, mean draft length 36. That is gone. MTP models keep their
speculation; ngram models lose it. If ngram throughput turns out to matter
more than single-binary operations, that is the argument for keeping
llama-swap around for those two models.
