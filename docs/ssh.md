# SSH, Forgejo Git and initramfs unlock

## Port map

| Port | Service |
| --- | --- |
| `22/tcp` | Forgejo's built-in Git SSH, published by the Forgejo container (`22:2222`) |
| `2222/tcp` | Host OS `sshd` (LAN/VPN only) |
| `2223/tcp` | dropbear-initramfs, only during the initramfs phase |

Forgejo keeps host port 22 so existing clone URLs do not change. The container
listens on 2222 internally and Docker publishes it as 22.

## Forgejo

`stacks/forgejo/compose.yaml` sets:

```yaml
ports:
  - "22:2222"
environment:
  FORGEJO__server__SSH_PORT: "22"
  FORGEJO__server__SSH_LISTEN_PORT: "2222"
  FORGEJO__server__SSH_USER: forgejo
  # SSH_USER only changes the username advertised in clone URLs. The built-in
  # server authenticates against this separate setting, whose default is "git".
  FORGEJO__server__BUILTIN_SSH_SERVER_USER: forgejo
  FORGEJO__server__START_SSH_SERVER: "true"
  FORGEJO__server__SSH_SERVER_HOST_KEYS: /data/gitea-ssh/ssh_host_ed25519_key,/data/gitea-ssh/ssh_host_rsa_key
  FORGEJO__server__SSH_CREATE_AUTHORIZED_KEYS_FILE: "false"
```

The old OpenSSH host keys from `/data/ssh` are copied to
`/srv/docker/forgejo/ssh-keys` and mounted at `/data/gitea-ssh` read-only.
They live outside `/data/ssh` because the image resets that directory's
ownership at startup, and Forgejo's built-in SSH server runs as UID 1000.

The built-in server authenticates as `forgejo`, matching the existing clone
URLs. `SSH_USER` alone is not enough: Forgejo authenticates against
`BUILTIN_SSH_SERVER_USER`, so without it key authentication fails with
`Permission denied (publickey)` while `git@` works. After the first start,
compare the fingerprint with the old host:

```bash
ssh-keyscan -p 22 forgejo.sakul-flee.de
```

Do not accept a new fingerprint for an existing name without checking why.

## Host SSH

`/etc/ssh/sshd_config` or a drop-in should set:

```text
Port 2222
PasswordAuthentication no
PermitRootLogin no
```

## LUKS and dropbear-initramfs

The root filesystem is LUKS-encrypted and unlocked over SSH from the initramfs.
On Debian:

```bash
sudo apt-get install -y cryptsetup-initramfs dropbear-initramfs
```

Add the public key to `/etc/dropbear/initramfs/authorized_keys`, configure the
initramfs network (DHCP or static `192.168.178.200`), and set the dropbear port:

```text
DROPBEAR_OPTIONS="-p 2223 -s -j -k"
```

Then:

```bash
sudo update-initramfs -u -k all
```

At boot, connect to port 2223 and run `cryptroot-unlock`. On this host the
initramfs uses a static address; `/etc/initramfs-tools/initramfs.conf` contains
`IP=192.168.178.200::192.168.178.1:255.255.255.0:homelab:eno1:off`.

Dropbear runs on its own port with its own host key, so there is no
`known_hosts` conflict with the fully booted host sshd on 2222.

Keep a physical console/recovery path and a LUKS recovery key. A headless host
with a broken initramfs is not recoverable over the network.
