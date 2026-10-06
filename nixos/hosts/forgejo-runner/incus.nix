# Incus-level definition of the "forgejo-runner" instance.
#
# This file describes the VM, not the software inside it. Anything
# NixOS can configure belongs in default.nix, which is what gets
# built into the image; what is left is the handful of facts only
# Incus knows: how much CPU and RAM, where writable data lives,
# and which network device the guest gets.
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

    # A VM's extra disk is a raw block device, so this volume is
    # `block` and the guest mounts it itself. incus/apply.sh
    # defaults a VM's volumes to block and strips `path` from disk
    # devices for VMs; `type` is spelled out anyway because this
    # is the one place the difference actually bites.
    #
    # No `path`: a VM has no filesystem view of an attached disk.
    runner-data = {
      type = "disk";
      pool = "persistent";
      source = "forgejo-runner-data";
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

  # The k3s deployment this replaces ran capacity 4 with a limit of
  # 1 cpu and 4 GiB per job pod, so its worst case was four
  # concurrent builds plus the runner itself. 4 cpu and 8 GiB is
  # that ceiling plus room for dockerd and the image layers a
  # build pulls in; it is a cap, not a reservation. The host has
  # 16 cores and 30 GiB, so there is room to raise this if the
  # queue backs up -- the reason to keep it here is parity with
  # what k3s did. Adjustable live with `incus config set`.
  limits = {
    memory = "8GiB";
    cpu = "4";
  };

  # The root disk, sized. `limits.memory` and `limits.cpu` cap what the
  # instance may use; this is how much it is *given*.
  #
  # 40 GiB, because the root disk has to hold the NixOS closure, the
  # Docker image store and a running job's writable layer at once. On the
  # first real job, with one 5.06 GB CI image pulled:
  #
  #   at rest    7.3 G used   1.9 G free   80%
  #   in a job   8.8 G used   360 M free   97%
  #
  # 40 GiB is the closure, several 5 GB CI images, and concurrent job
  # layers, with room to spare.
  #
  # WHY A FIELD HERE AND NOT A BIGGER IMAGE. The image could be built
  # bigger -- make-disk-image.nix's `additionalSpace` does exactly that --
  # but that build cannot finish: the image is assembled in a VM from
  # `pkgs.vmTools.runInLinuxVM` whose `vm-run` script passes qemu no `-m`,
  # so it gets qemu's 128 MB default and the guest sees 100 MB. A 45 GiB
  # ext4's metadata does not fit in that, and the guest kernel panics
  # ("deadlocked on memory") before cptofs finishes. full.nix explains
  # this at length; the short version is that the image must stay small
  # and the capacity has to come from here.
  #
  # It also would not be needed. incus-virtual-machine.nix sets
  # `autoResize = true` and `boot.growPartition = true`, so the guest
  # grows its partition and filesystem to fill whatever disk Incus gives
  # it. The live instance shows it: a 4.86 GiB image, a 10 GiB disk, and
  # a 9.7 GiB `nixos` partition. Incus decides the size; the guest claims
  # it.
  #
  # `incus config set <vm> limits.disk.size` is NOT the way, and its
  # rejection is what makes this field look necessary. Incus sizes a VM's
  # root disk through the `root` disk device's own `size` key, which is what
  # apply.sh sets; `limits.disk.*` is a different thing and the CLI rejects
  # it on a VM.
  #
  # It is not in `devices`, and apply.sh does not reconcile it there on
  # purpose: sync_devices reconciles by remove-then-add, because a device's
  # type cannot be changed in place, and doing that to `root` would destroy
  # the instance's root disk. It applies this with an in-place write instead.
  #
  # That write is an `override`, not a `set`, and the reason is worth keeping
  # in mind: `root` is inherited from the `default` profile, and Incus refuses
  # to modify a profile device on a single instance ("Override device or
  # modify profile instead"). The profile cannot carry the size -- `default`
  # is shared with caddy, forgejo and wireguard, which would all inherit a
  # runner-sized disk. So apply.sh overrides `root` onto this instance alone.
  # The consequence: from here this instance's root disk no longer follows
  # the profile. If `default`'s root ever changes pool, this one will not.
  #
  # Verified on this host, both directions: the override is accepted while
  # `root` is still inherited, a plain `set` is accepted afterwards, and
  # repeating the override is refused ("The device already exists").
  #
  # Two consequences worth knowing before changing the number:
  #
  #   * Growing a VM's disk is one-way. Incus will not shrink a VM root
  #     disk, so this only ever goes up. Lowering it here will not give
  #     the space back.
  #   * The guest needs a restart to claim a larger disk, because
  #     `autoResize`/`growPartition` run at boot. Growing a running VM
  #     therefore leaves the extra space invisible to `df` until the
  #     next reboot.
  #
  # One more, observed rather than predicted: growing the disk renumbered
  # the guest's virtio disks, so the root filesystem moved from `sda2` to
  # `sdb2` and the data volume took over `sda`. disk.nix finds its disk by
  # LABEL rather than by name precisely so that this is a non-event, and it
  # was -- but it is why nothing in this guest may assume `sda`.
  rootDiskSize = "40GiB";

  # The runner's writable state, on `persistent` and
  # deliberately NOT restic'd, for two reasons that are the same
  # reason stated twice:
  #
  #   * the generated config.yaml lands here, and it holds the
  #     runner token. A backed-up copy of a live credential is a
  #     liability, and nothing here is irreplaceable -- apply.sh
  #     and the generator unit rewrite both the secrets and the
  #     config from the host's sops store on demand (the caddy
  #     secrets volume is on this pool for exactly this reason).
  #   * the job workspaces and the actions cache are live, mutable
  #     data whose loss costs a cache miss and a re-checkout, not
  #     anything anyone would miss.
  #
  # What is NOT here and why: Docker's own image store
  # (/var/lib/docker) is on the root disk. Images are re-pullable
  # by definition, so losing them to a re-create costs one re-pull
  # per label, and keeping them off the volume keeps the volume's
  # contents to the things that are actually state.
  volumes = [
    {
      pool = "persistent";
      name = "forgejo-runner-data";
      description = "Runner state: actions cache, job workspaces, rendered secrets and the generated config (holds the runner token) -- not restic'd";
    }
  ];

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
  # `dir` is on the data volume, so the secrets survive a
  # re-create like everything else the runner needs. The default
  # mode (0400, root:root) is right here: the only reader is the
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
