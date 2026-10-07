# Every Incus instance this host manages, and the only place that knows the
# list of names.
#
# Two consumers, deliberately:
#
#   * nixos/flake.nix reads it to expose `incusInstances.<name>` as a flake
#     output, so incus/apply.sh can ask the flake what an instance should look
#     like (nix eval --json .#incusInstances.<name>) without parsing Nix in
#     shell.
#   * nixos/hosts/homelab/services/incus-instances.nix reads it to generate one
#     systemd service and one systemd.paths unit per instance.
#
# Because both derive from this one file, an instance cannot exist in one place
# and not the other. Adding an entry here is the whole job; there is no second
# list to keep in sync.
#
# The value of each entry is the instance's *Incus-level* definition -- the
# things the container config cannot express: which image, how much CPU and
# memory, which storage volumes, which extra devices. See
# nixos/hosts/<name>/incus.nix. The OS config lives beside it in
# nixos/hosts/<name>/default.nix.
{
  caddy = import ./hosts/caddy/incus.nix;
  dns = import ./hosts/dns/incus.nix;
  forgejo = import ./hosts/forgejo/incus.nix;
  # A VM. Its incus.nix sets `type = "vm"`, which is what switches the image
  # build (qcow2 rather than squashfs+metadata), the create call (`-t vm`), the
  # volume type (block, not filesystem) and the disk devices (no `path`).
  # The forgejo-runner is a VM for the same reason wireguard is: it runs
  # Docker inside the guest, which an LXC could only do privileged.
  wireguard = import ./hosts/wireguard/incus.nix;
  forgejo-runner = import ./hosts/forgejo-runner/incus.nix;
}
