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

- `OLLAMA_IGGPU_ENABLE=1` — without it Ollama logs `dropping integrated GPU`
  and skips the 680M because it is also the display device.
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

Importing a GGUF with `ollama create` reads `tokenizer.chat_template` from
the file itself, so **do not add a `TEMPLATE` line** to the Modelfile. Doing
so overrides a working template: the `TEMPLATE {{ .Prompt }}` fallback that
`ollama create` writes when it cannot find one will render raw prompt text
with no chat formatting, and the model answers that as garbage-looking
output. Omitting the line entirely is correct and the GGUF template is what
renders. The same applies to vision projectors — they are dropped on import,
which costs nothing here.

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
