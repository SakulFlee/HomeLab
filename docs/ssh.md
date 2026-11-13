# SSH, Forgejo Git and initramfs unlock

## Port map

| Port | Service |
| --- | --- |
| `22/tcp` | Forgejo's built-in Git SSH, published by the Forgejo container (`22:2222`) |
| `2222/tcp` | Host OS `sshd` |
| `2222/tcp` | dropbear-initramfs, only during the initramfs phase |

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
  FORGEJO__server__START_SSH_SERVER: "true"
  FORGEJO__server__SSH_CREATE_AUTHORIZED_KEYS_FILE: "false"
```

The old `/data/ssh` host keys are preserved. Forgejo's default built-in SSH
host keys are `ssh/gitea.rsa` and `ssh/gogs.rsa` relative to `APP_DATA_PATH`. If
the old volume uses different filenames, set
`FORGEJO__server__SSH_SERVER_HOST_KEYS` in `stacks/forgejo/compose.yaml` to the
comma-separated list of existing files.

After the first start, compare the fingerprint with the old host:

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
DROPBEAR_OPTIONS="-p 2222 -s -j -k"
```

Then:

```bash
sudo update-initramfs -u -k all
```

At boot, connect to port 2222 and run `cryptroot-unlock`.

### known_hosts caveat

dropbear and the host `sshd` use different host keys but the same `host:2222`.
Clients may report a host-key mismatch depending on whether the machine is in
the initramfs or fully booted. Use a separate SSH config alias or move dropbear
to 2223 if that becomes annoying.

Keep a physical console/recovery path and a LUKS recovery key. A headless host
with a broken initramfs is not recoverable over the network.
