# Incus-level definition of the "forgejo-runner" instance.
#
# This file describes the VM, not the software inside it. Anything
# NixOS can configure belongs in default.nix, which is what gets
# built into the image; what is left is the handful of facts only
# Incus knows: how much CPU and RAM, the root disk size, and which
# network device the guest gets.
#
# Read at build time by incus/apply.sh through the `incusInstances`
# flake output. See ../../../incus-instances.nix for the list.
#
# This is a VM, not an LXC, for the same reason the wireguard VM
# is: the runner executes arbitrary code from the marketplace and
# runs each job as a container, which needs a container runtime
# *inside* the instance. An LXC can only provide one with
# security.privileged, which hands the guest the host kernel -- the
# exact thing the repo's "LXC unless privileged, then VM" rule
# exists to refuse. A VM runs its own kernel and its own dockerd,
# and a job container is then as isolated from the host as Docker
# makes it.
let
  devices = {
    # On incusbr0, like every other instance, so the guest reaches
    # Forgejo at 10.0.0.101 in one hop and the internet through
    # incusbr0's NAT (image pulls, the actions cache upstream).
    #
    # The address is NOT configured here. Incus can hand a container
    # a static address; it cannot configure a guest's network. The
    # guest sets 10.0.0.102 itself, matching on this NIC's MAC --
    # which is why hwaddr is pinned rather than left to Incus: an
    # Incus-assigned MAC can change on a re-create, and a networkd
    # unit that matches nothing leaves the VM booted, unrouted and
    # silent. Must match bridgeMac in default.nix.
    eth0 = {
      type = "nic";
      name = "eth0";
      network = "incusbr0";
      hwaddr = "00:16:3e:00:00:12";
    };
  };
in
{
  # The single switch that changes how this instance is built and
  # created. Omitted means container, so every existing spec keeps
  # working.
  type = "vm";

  description = "Forgejo Actions runner (Docker executor)";

  # Start on boot, and bring it back up after apply.sh recreates
  # it. An instance that was deliberately stopped stays stopped;
  # see apply.sh.
  autostart = true;

  # 8 GiB, down from 12. This is a cap, not a reservation, but a VM keeps
  # whatever it has touched -- mostly page cache -- resident on the host
  # until the balloon reclaims it, so at 12 GiB the host showed the full
  # 12 even when the guest reported far less. With `capacity: 2` (see
  # default.nix) the peak is two jobs, not four, so 8 GiB leaves a real
  # working set (~4.5 GiB anonymous at idle) plus headroom. Nix's
  # `min-free`/`max-free` in default.nix keep the store from filling the
  # disk again. Adjustable live with `incus config set`.
  limits = {
    memory = "12GiB";
    cpu = "4";
  };

  # The root disk, sized. This is the VM's only disk: the NixOS closure
  # (/nix/store), the Docker image store, a running job's writable layer,
  # the runner's state, the artifact cache and the job workspaces all
  # share it.
  #
  # 100 GiB is sized for the artifact cache, not for the OS. The Orbital
  # CI workflows save multi-gigabyte sccache/cargo entries under keys that
  # change with Cargo.lock; at the observed 12-15 GiB/day, 100 GiB is
  # roughly the seven-day retention window. The cache guard in default.nix
  # wipes the artifact cache when free space drops below 10 GiB, so the
  # disk cannot fill and break job setup.
  #
  # The host-side Nix builds moved to the dedicated host runner on the
  # HomeLab host (nixos/hosts/homelab/services/forgejo-nix-runner.nix),
  # which uses the host's own store. That is why this disk no longer carries
  # the ROCm/llama.cpp closure the old 80 GiB root disk had to hold.
  #
  # WHY A FIELD HERE AND NOT A BIGGER IMAGE. The image could be built
  # bigger -- make-disk-image.nix's `additionalSpace` does exactly that --
  # but that build cannot finish: the image is assembled in a VM from
  # `pkgs.vmTools.runInLinuxVM` whose `vm-run` script passes qemu no `-m`,
  # so it gets qemu's 128 MB default and the guest sees 100 MB. A 45 GiB
  # ext4's metadata does not fit in that, and the guest kernel panics
  # ("deadlocked on memory") before cptofs finishes.
  #
  # It also would not be needed. incus-virtual-machine.nix sets
  # `autoResize = true` and `boot.growPartition = true`, so the guest grows
  # its partition and filesystem to fill whatever disk Incus gives it.
  # Incus decides the size; the guest claims it.
  #
  # `incus config set <vm> limits.disk.size` is NOT the way: Incus sizes a
  # VM's root disk through the `root` disk device's own `size` key, and
  # apply.sh overrides `root` onto this instance alone, because the shared
  # `default` profile cannot carry a runner-sized disk.
  #
  # Growing is one-way: Incus will not shrink a VM root disk, and the guest
  # needs a restart to claim a larger one because `autoResize`/
  # `growPartition` run at boot.
  rootDiskSize = "100GiB";

  # No extra volumes. The runner's state, artifact cache and workspaces
  # live on the single root disk. They are regenerable: a re-create loses
  # them, the host re-renders the secrets, and the first jobs are cold.
  # That is the trade for not carrying a second disk.

  devices = devices;

  # Secrets the host decrypts and writes into this instance, from
  # the runner's own registration. The host reads `source` (which
  # sops-nix materialised at /run/secrets on the host) and writes
  # the bytes into `dir/file` inside the instance.
  #
  # These are the runner's *persistent* credentials -- the uuid and
  # token Forgejo issued when the runner was first registered --
  # not a registration token. Nothing is consumed by using them,
  # and nothing has to re-register: the daemon presents them to
  # Forgejo on every poll. That is what makes this design work on
  # an immutable image: the credentials are rendered, never baked
  # in, and a re-create loses nothing (see NOTES.md,
  # "Registration").
  #
  # `dir` is on the single root disk. A re-create loses it, but that
  # is deliberate: the host re-renders both values from sops on the
  # next `incus-secrets` run, and the runner's registration is
  # persistent (see NOTES.md, "Registration"). The default mode
  # (0400, root:root) is right here: the only reader is the
  # generator unit, which runs as root and embeds both values into
  # the config.yaml the daemon reads. The daemon itself never
  # opens these files.
  #
  # `format = "raw"` for both: a uuid and a token are values to
  # be embedded, not KEY=value lines, and `env` would wrap each in
  # RUNNER_UUID=..., which is not what the generator reads.
  renderedSecrets = [
    {
      format = "raw";
      file = "runner-uuid";
      dir = "/var/lib/forgejo-runner/secrets";
      source = "/run/secrets/forgejo_runner_uuid";
    }
    {
      format = "raw";
      file = "runner-token";
      dir = "/var/lib/forgejo-runner/secrets";
      source = "/run/secrets/forgejo_runner_token";
    }
  ];

  # Units inside the instance that read what the host writes, and
  # that must therefore run again when it changes.
  #
  # The generator first, the daemon second: apply.sh restarts the
  # consumers in the order given, and the daemon reads the config
  # the generator has just rewritten. An unconditional restart
  # rather than try-restart, because on a first deploy neither
  # unit has ever started (the generator fails until the secrets
  # exist, by design -- see default.nix).
  secretConsumers = [
    "forgejo-runner-config.service"
    "forgejo-runner.service"
  ];
}
