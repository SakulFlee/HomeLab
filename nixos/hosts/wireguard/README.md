# wireguard

The VPN, as an Incus **VM**. This replaces `apps/wireguard/` (wg-access-server
in k3s), which is Docker-only.

For why it is a VM and not a container, and for the four differences that
`type = "vm"` implies, see `../../../incus/README.md` → *Containers and VMs*.

| file               | what it is                                                    |
| ------------------ | ------------------------------------------------------------- |
| `default.nix`      | the guest: networkd addressing, firewall, the web UI settings  |
| `wireguard-ui.nix` | a NixOS module for the service — nixpkgs has the binary but no module |
| `disk.nix`         | format-once and mount the data volume                          |
| `incus.nix`        | the Incus half: `type = "vm"`, the bridged NIC, the block volume, the rendered secrets |

## What is actually running

`wireguard-ui` — the **ngoduykhanh fork**, v0.6.2, from nixpkgs
(`pkgs/by-name/wi/wireguard-ui`) — plus the kernel's own WireGuard. No Docker,
no `security.privileged`, no `/dev/net/tun` passthrough. A VM brings its own
kernel, and that kernel has WireGuard built in.

`wg-easy` was the other candidate and is **not** in nixpkgs; it is Docker-first.
`wireguard-ui` is packaged, so it is the one that fits a Nix-native build.

The binary is a Go program with the web assets embedded, and the source is worth
reading before trusting any of the below — several details are load-bearing and
none of them are in its README:

* the tunnel interface is **hardcoded `wg0`** (`util/config.go`) and cannot be
  configured;
* the client database is opened as the **relative** path `./db`
  (`main.go: jsondb.New("./db")`) — so the systemd `WorkingDirectory` decides
  where every client key lives. Get this wrong and the service starts perfectly
  happily against an empty database;
* there is **no `exec.Command` anywhere in the source**: `wg0` is configured
  over netlink with `wgctrl`, not by shelling out to `wg-quick`. That is why
  `wireguard-tools` is not a dependency here;
* there is **no masquerade or nftables code either**. `WGUI_FIREWALL_MARK` and
  `WGUI_TABLE` are stored in the database and never read. Both are set to empty
  anyway, so a future version that does implement them cannot silently start
  SNATing clients — Caddy's Incus vhost gate matches `remote_ip 100.64.0.0/10`,
  and a masquerade here would rewrite every VPN client to the tunnel interface's
  own address and be refused by that gate.

The tunnel interface's `wg0` name happens to match what the k3s deployment used,
which is what keeps the client migration short.

## Addresses

| what            | value                     | where it is set                          |
| --------------- | ------------------------- | ---------------------------------------- |
| VM on the LAN   | `192.168.178.210`         | `default.nix`, pinned by `hwaddr` in `incus.nix` |
| web UI          | `192.168.178.210:51821`   | `bindAddress`                            |
| tunnel listen   | `100.64.0.1/24`, UDP 51820| `serverInterfaceAddresses`, `listenPort`  |
| public endpoint | `wg.sakul-flee.de:51820`  | `endpointAddress`                        |
| VPN resolver    | `192.168.178.200`         | `dnsServers`, and the guest's own DNS     |

The resolver is still the split-horizon CoreDNS in k3s. Deliberate: moving DNS in
the same change as the VPN would mean debugging routing and name resolution at
the same time. This VM is on the LAN, so it can reach it. When DNS moves too,
these two values become the VM's own address.

The tunnel subnet stays `100.64.0.0/24` because two existing allow-lists match
inside it — the Traefik vpn-only middleware (`100.64.0.0/10`) and Caddy's Incus
vhost gate. Renumber the tunnel and both have to change with it.

## Before the first deploy

Four things are outside this repository's reach. All four are needed before the
VM is useful.

**1. The two secrets.** They do not exist yet; `nixos/modules/sops.nix`
declares them and `nixos/secrets.yaml` does not have them, so the host will fail
to build until they are added. Run on the host, as root, from `/etc/nixos`:

Both of these are **already in `secrets.yaml`**, encrypted to all nine
recipients. Re-run them only to *rotate*.

```bash
cd /etc/nixos
printf '%s' "$(openssl rand -base64 24 | tr -d '\n')" \
  | jq -Rs . | sops set --value-stdin nixos/secrets.yaml '["wireguard_ui_password"]'
printf '%s' "$(openssl rand -base64 48 | tr -d '\n')" \
  | jq -Rs . | sops set --value-stdin nixos/secrets.yaml '["wireguard_ui_session_secret"]'
```

The `jq -Rs .` is not optional. `sops set` parses the value from stdin as JSON
regardless of the target file's format, so a bare base64 string is rejected:

```
Value for --set is not valid JSON
```

It also adds no trailing newline to the string, which matters: `jq -Rs` over
input that already ends in one would silently store that `\n` as part of the
password.

Neither secret may be *absent*. wireguard-ui's compiled-in defaults are
`admin`/`admin` and a **fixed session secret published in its own source** —
leave them unset and the admin UI is one known password away, with session
cookies anyone can mint.

`sops.secrets.wireguard_ui_*` is declared in `nixos/modules/sops.nix`, so **a
host rebuild fails outright if either is missing** from `secrets.yaml`:
sops-nix builds each one with `sops -d --extract`, which errors
`component [...] not found`. The declaration and the value are therefore a pair
— never land one without the other, or the hourly `nixos-auto-update` fails
every hour.

**2. A DHCP reservation** for `192.168.178.210`, outside the pool. The guest
configures its own address, so a lease conflict means two devices fighting and
an unreachable VM.

**3. The router's port forward** for UDP 51820, repointed from `192.168.178.200`
to `192.168.178.210`. This is the cutover, and it is the only step that touches
the live VPN — see below.

**4. The router must not** forward the web UI's 51821. It is bound to the LAN
address and reachable from home and over the VPN, which is the intent.

## Cutover

The VM comes up alongside the k3s deployment; nothing is switched over until
the router moves. That is what makes this reversible at every step.

1. Land this, and rebuild the host. `nixos/incus-instances.nix` gains a
   `wireguard` entry, which generates `incus-apply-wireguard.service` and a path
   unit — so the VM is **created automatically**, before any of steps 2–4.
   That is safe: the router still forwards 51820 to `192.168.178.200`, so the
   live VPN is untouched.
2. Check it booted, has its address, and formatted its data disk:
   `incus exec wireguard -- systemctl is-active wireguard-ui`, and
   `incus exec wireguard -- ls /var/lib/wireguard-ui/db` should show `clients`.
3. Open the UI at `http://192.168.178.210:51821` and **add the phone as a
   client**, pasting in its existing public key. Do not generate a new one: the
   key is what the phone's current config carries, and reusing it is what lets
   the phone work again without touching it.
4. From the LAN, with the old tunnel still up, confirm a client config the UI
   generated actually handshakes — `wg-quick up` it on a spare machine, or
   bring up the second interface in the VM.
5. **Only now** repoint the router's UDP 51820 forward to `192.168.178.210`.
6. Test from the phone, on mobile data, not on wifi.
7. Only once that is confirmed: tear down `apps/wireguard/` in k3s.

Keep the k3s deployment running until step 6 passes. It is the only remote
access, and a cutover with nothing to fall back to is a different kind of
decision.

## Failure modes worth knowing

**The service starts with an empty database.** Almost always the working
directory: `./db` is relative, so a `WorkingDirectory` that is not the data
volume produces a healthy-looking UI that has silently lost every client.

**The service is down after a recreate.** Expected, and it is meant to be loud.
The two secrets render to `/var/lib/incus-secrets/` on the **root** disk, which a
recreate wipes; the next reconcile re-renders them and restarts the unit. They
are deliberately not on the data volume — under the mount point they would be
written to the root disk and then shadowed by the mount, leaving the service
running on copies that had stopped being current.

**The data disk did not mount.** `wireguard-data-format.service` runs on every
boot, is a no-op once the label is there, and **refuses to guess** if it finds
more than one blank disk. The mount is `nofail`, so the VM still boots — and
`RequiresMountsFor` on the service keeps `wireguard-ui` down rather than letting
it start on the root disk.

**Nothing answers on 51820.** Check `nft list ruleset` inside the VM: UDP 51820
is opened by `networking.firewall.allowedUDPPorts`, and a bridged VM's own
firewall is the only thing between it and the LAN.
