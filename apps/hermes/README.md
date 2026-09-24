# Hermes + Unsloth Studio

Two Flux Kustomizations that ship together:

| URL | Backend | Port |
| --- | --- | --- |
| `https://hermes.sakul-flee.de/` | Hermes WebUI | 8787 |
| `https://hermes.sakul-flee.de/v1` | Gateway OpenAI API | 8642 |
| `https://hermes-dashboard.sakul-flee.de/` | Monitoring dashboard | 9119 |
| `https://unsloth.sakul-flee.de/` | Unsloth Studio | 8000 |
| — | Unsloth JupyterLab (ClusterIP only) | 8888 |

All four hostnames are VPN-only (`wireguard-vpn-only@kubernetescrd`) and use
`letsencrypt-production`.

The agent's model provider is pinned in managed scope
(`apps/hermes/configmap.yaml`, mounted read-only at `/etc/hermes/config.yaml`),
which wins over `~/.hermes/config.yaml` — but only per key, so `model.default`
(the concrete model id) remains editable from the dashboard.

## Bootstrap order

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
5. **Pick a model** in the dashboard (*Change*) or with `hermes model`. This
   writes `model.default`, which managed scope deliberately does not pin.
6. **Smoke test** from inside the VPN:

   ```sh
   curl -H "Authorization: Bearer $API_SERVER_KEY" \
        https://hermes.sakul-flee.de/v1/models
   ```

## Adding a cloud provider later

Replace the `model:` block in `apps/hermes/configmap.yaml` and add the new key
to `apps/hermes/secrets`. Bump the ConfigMap name (`-v1` → `-v2`) as well:
editing values in place does not restart the pod, a changed name does.

## Troubleshooting

- **Container exits immediately with status 0** — the tag matters. `:latest`
  is the base image and its CMD is `python`, which hits EOF and exits. Use
  `unsloth/unsloth-rocm:studio` (supervisord launches Studio on 8000 and
  JupyterLab on 8888).
- **`/dev/kfd` EPERM** — the container device cgroup denies it unless the pod
  requests `devic.es/rocm`; hostPath alone is not enough. The group is defined
  in `apps/gpu-device-plugin/daemonset.yaml`, so that DaemonSet must be rolled
  out before Unsloth can start.
- **ROCm refuses the GPU** — the node's card is an AMD Rembrandt iGPU
  (`1002:1681`, gfx1035). If the container exits before Studio binds 8000, add
  `HSA_OVERRIDE_GFX_VERSION: "10.3.0"` to the Unsloth deployment env.
- **Silent CPU fallback** — `UNSLOTH_ALLOW_CPU=0` makes a missing GPU fail
  loudly instead of serving from CPU. Set it to `1` as a stop-gap only.
- **Config keys** — confirm what the running build actually accepts with
  `hermes config get model` before adding to managed scope.
- **WebUI streams look buffered** — if chat output arrives in bursts, the fix is
  a `ServersTransport` with a `flushInterval` on the Traefik side.
- **Empty `hermes-data`** — this deployment is intentionally fresh; the PVC
  never existed before, so there is nothing to migrate.
