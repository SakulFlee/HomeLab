# HomeLab

## How to deploy

### Step 1.: K0s Cluster deployment

First we need to deploy k0s on each node.
To do so, head into the `k0s-cluster-config/` folder and make sure all IP addresses and settings are correct!
Then run the `k0sctl apply` command.

Next, generate a kubeconfig via `k0sctl kubeconfig` and optionally store it as your main kubeconfig:
```bash
k0sctl kubeconfig > ~/.kube/config
```

Let's verify that the cluster is deployed and working:
```bash
> kubectl get nodes
NAME             STATUS   ROLES           AGE     VERSION
k0s-controller   Ready    control-plane   6m33s   v1.34.1+k0s
k0s-worker-1     Ready    <none>          6m29s   v1.34.1+k0s
k0s-worker-2     Ready    <none>          6m29s   v1.34.1+k0s
```

Optionally, if we want to run container on the controller node too, we have to untaint it:
```bash
kubectl taint nodes k0s-controller node-role.kubernetes.io/control-plane:NoSchedule-
```

> Note the `-` at the end. That'll **remove** the taint.

### Step 2.: Bootstrap Flux

From the root of the repository run:
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

### Step 3.: Verification & Troubleshooting

After a bit, Flux should report that it is ready.
If the cluster is freshly installed, it sometimes fails to do DNS queries _for unknown reasons_.
**Fully restarting** each node usually fixes that, but you'll have to restart the `flux bootstrap`!

