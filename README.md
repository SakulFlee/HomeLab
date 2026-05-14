# HomeLab

This setup is currently tested with [K3s](https://k3s.io) and **all** its defaults, including the storage classes.

## StorageClasses

However, for better data security, I would recommend to **delete** the default storage class K3s introduces:

```bash
kubectl delete storageclass local-path
```

The repository will provide alternative StorageClasses:

| name | reclaim policy |
| - | - |
| local-path-persistent | Retain |
| local-path-volatile | **Delete** |

## Flux Bootstrap

Once ready, deploy Flux with this repository:

```bash
flux bootstrap git \
  --url=ssh://git@github.com/SakulFlee/HomeLab.git \
  --branch=main \
  --private-key-file ~/.ssh/id_ed25519 \
  --path=clusters/k0s-homelab
```

This will bootstrap Flux and setup this repository as the `flux-source` for syncronization.
When prompted to give access to the repository, type `y`.

The private key mentioned here isn't strictly required as the repository itself is public.
However, the secret repository (... containing all the secrets, credentials, auth info, etc. ...) **is** private and **requires** access.
You can also use a GitHub app, deploy key or other means, but since I am deploying from my work machine, which also uses this SSH key to access GitHub, I can just pass this on.

### Flux Reconciliation

After a change has been **pushed** into this repository, FluxCD will automatically detect changes about every 10 minutes.
If you want to force a reconciliation early, run the following command:
```bash
flux reconcile kustomization flux-system --with-source
```

`flux-system` is the main file handling this whole repository.
If you just want to update a specific kustomization, simply exchange `flux-system` with the flux kustomization name of your choice!

