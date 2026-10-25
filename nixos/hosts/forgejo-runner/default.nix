# NixOS inside the "forgejo-runner" VM.
#
# What is actually running: the Forgejo Actions runner (pkgs.forgejo-runner,
# the code.forgejo.org/forgejo/runner project, v13) with the Docker
# executor, and a Docker daemon to execute the jobs on. That pairing is
# the whole reason this is a VM and not an LXC: the runner executes
# arbitrary code from the marketplace, and running each job as a
# container needs a container runtime *inside* the instance -- which an
# LXC can only do as `security.privileged`, the thing the repo's rule
# ("LXC unless something needs security.privileged, in which case VM")
# exists to avoid. A VM brings its own kernel and its own dockerd, and
# the jobs are as isolated from the host as Docker makes them.
#
# See incus.nix for the Incus half and ../../../incus/README.md for the
# instance model (immutable image, disposable single root disk).
{ config, lib, pkgs, ... }:

let
  # The VM's address on incusbr0. Set in the guest, not through Incus:
  # Incus can hand a *container* a static address, but a guest
  # configures its own network. The address is matched on the NIC's MAC,
  # which incus.nix pins, so it survives a re-create (an Incus-assigned
  # MAC would not -- see hosts/wireguard/default.nix for the same
  # arrangement on the VPN VM).
  bridgeAddress = "10.0.0.102";

  # Must match hwaddr in incus.nix.
  bridgeMac = "00:16:3e:00:00:12";

  # The Forgejo instance this runner serves. The internal address on
  # incusbr0, not the public vhost: the runner is on the same bridge,
  # so the API is one hop away and nothing between here and Forgejo
  # (Caddy, DNS, Cloudflare) is on the critical path. If the runner is
  # ever moved off incusbr0, this is the value to change.
  forgejoUrl = "http://10.0.0.101:3000";

  # The job image behind every label.
  #
  # ghcr.io/catthehacker/ubuntu:act-24.04, a full Ubuntu with the tooling
  # act-based runners are expected to have -- git, curl, python3, jq, and the
  # Docker CLI itself. That last part is the reason to move off node:22-bookworm:
  # a job that runs `docker build` expects a docker client on PATH, and a
  # node image has none. The runner keeps the socket out of the job (see
  # container.docker_host below), so the CLI is present but cannot reach a
  # daemon of its own -- a workflow that needs a real build asks the runner,
  # which runs it as a sibling container.
  #
  # Measured: 0.54 GiB compressed over 6 layers, against node:22-bookworm's
  # 0.38 GiB over 8. Docker stores layers uncompressed, so on disk it is
  # roughly 2.2 GiB against 1.4 GiB -- paid once per VM, and pruned daily by
  # forgejo-runner-prune.timer.
  #
  # Third-party image: it is not a Forgejo or GitHub base, it is the image the
  # local act ecosystem converges on. That is a conscious choice for closer
  # parity with hosted runners, not a default.
  jobImage = "ghcr.io/catthehacker/ubuntu:act-24.04";

  # The labels the k3s runner declared, so nothing that runs-on one of
  # them has to change. Labels are what Forgejo matches jobs against,
  # and they are declared to the instance at every daemon start (the
  # runner's Declare RPC), so the last daemon to start wins -- see
  # NOTES.md, "Labels".
  # The Nix rebuild executor is NOT here any more. The NixOS-Config
  # flake-lock gate builds the host configuration on a dedicated host
  # runner on the HomeLab host that uses the host's own Nix store. This VM
  # declares no `nix` label, so a stray `runs-on: nix` job cannot land in
  # the runner VM and grow its root disk with a ROCm/llama.cpp closure.
  #
  # `docker:host` is the same host executor for image builds. Buildah needs
  # CAP_SYS_ADMIN (or a user namespace) and cannot run in an unprivileged
  # job container, so a workflow that builds an image runs here and uses the
  # VM's own Docker daemon. The ordinary `docker://` labels stay unprivileged.
  runnerLabels = [
    "default:docker://${jobImage}"
    "ubuntu-latest:docker://${jobImage}"
    "ubuntu-24.04:docker://${jobImage}"
    "docker:host"
  ];
in
{
  # ---------------------------------------------------------------------
  # The disk image: deliberately NOT enlarged here
  # ---------------------------------------------------------------------
  # The single root disk has to hold the NixOS closure (/nix/store is not a
  # separate filesystem here), the Docker image store, a running job's
  # writable layer, and the runner's state, artifact cache and workspaces.
  # The artifact cache is the largest and least predictable consumer; the
  # cache guard below is what keeps it from filling the disk.
  #
  # The answer is a single 100 GiB root disk, and Incus is what applies it --
  # see `rootDiskSize` in incus.nix. The host-side Nix builds moved to the
  # dedicated host runner, so this disk no longer carries the ROCm/llama.cpp
  # closure.
  #
  # Why the image itself stays small, and why the size is not baked in:
  # make-disk-image.nix assembles the image inside a VM from
  # `pkgs.vmTools.runInLinuxVM`, whose `vm-run` script passes qemu no `-m`,
  # so the guest gets qemu's 128 MB default and a 45 GiB ext4's metadata
  # does not fit -- the guest panics before cptofs finishes. The same
  # derivation at the default additionalSpace builds fine. A bigger image is
  # also redundant: incus-virtual-machine.nix sets `autoResize` and
  # `boot.growPartition`, so the guest grows into whatever disk Incus gives
  # it. `virtualisation.diskSize` is not the knob; qemu-vm.nix uses it only
  # for the disk of the VM it starts to run a build in.
  #
  # So there is no override of `system.build.qemuImage` here at all.
  # incus-virtual-machine.nix's own call stands; capacity is Incus's to
  # grant, and the guest's job to claim.

  networking.hostName = "forgejo-runner";

  # ---------------------------------------------------------------------
  # Addressing
  # ---------------------------------------------------------------------
  # networkd rather than networking.interfaces, for the same two reasons
  # as the wireguard VM: nixpkgs has no way to match on a MAC through
  # networking.interfaces, and the virtio NIC's kernel name (enp1s0 and
  # friends) is not a safe thing to key a config on. Matching on the
  # pinned MAC is deterministic.
  networking.useNetworkd = true;

  systemd.network.networks."10-incus" = {
    matchConfig.MACAddress = bridgeMac;
    networkConfig = {
      Address = [ "${bridgeAddress}/24" ];

      # incusbr0's gateway, which is the host. Egress (image pulls, the
      # actions cache upstream) is NAT'd by incusbr0's ipv4.nat.
      Gateway = "10.0.0.1";

      # The router, which is what the host itself resolves through. Not
      # the host's CoreDNS (192.168.178.200): that is a k3s pod today
      # and dies with the cluster, while the router does not. The runner
      # only needs public names (docker registries); split-horizon names
      # are resolved by the Cloudflare wildcard either way.
      DNS = [ "192.168.178.1" ];
    };
  };

  # No guest firewall. This is a conclusion, not an omission, and it is
  # the same conclusion the k3s pods reached by being pods: the instance
  # has nothing to protect *from* on the networks it sits on.
  #
  # What reaches this VM: nothing from the LAN. It is on incusbr0 only,
  # no Incus forward points at it (the runner polls Forgejo outbound; it
  # listens for nothing), and incusbr0 is behind the host's NAT with no
  # route in from 192.168.178.0/24. The only inbound traffic is from
  # the VM's own Docker bridges -- job containers reaching the actions
  # cache proxy, which listens on a random port and is meant to be
  # reachable by exactly those containers.
  #
  # A firewall would therefore only do one thing: drop the cache proxy's
  # random port (proxy_port = 0 picks a free one at every start, so it
  # cannot be allow-listed). trustedInterfaces = [ "docker0" ] would
  # work for the default bridge but not for the network the runner
  # creates per job, whose name is not knowable here. The VM boundary is
  # the isolation; the guest firewall would add noise, not safety.
  networking.firewall.enable = false;

  # ---------------------------------------------------------------------
  # Docker -- the job executor
  # ---------------------------------------------------------------------
  # `virtualisation.docker.enable`, which despite the name IS the Docker
  # daemon: its own description in nixpkgs reads "This option enables docker, a
  # daemon that manages linux containers." There is no `services.docker` in
  # NixOS -- writing that here fails evaluation with
  #   error: The option `services.docker' does not exist
  # and the option set has no `build` submodule either, so nothing here is
  # about producing an image OF this system. Recorded because the name reads
  # the other way round and getting it wrong costs an evaluation to discover.
  virtualisation.docker.enable = true;

  # The runner's account. A dedicated user rather than root, in the
  # docker group: the runner only needs the socket, and the containers
  # it creates run as root inside their own namespaces regardless of the
  # runner's uid. The k3s deployment ran the runner as root because the
  # pod needed the socket; a VM can do better.
  users.groups.forgejo-runner = { };
  users.users.forgejo-runner = {
    isSystemUser = true;
    group = "forgejo-runner";
    description = "Forgejo Actions runner";

    # Home is a directory inside /var/lib/forgejo-runner, not that directory
    # itself.
    #
    # /var/lib/forgejo-runner is root:root 0755, which is correct for the
    # runner's state root -- and it is also the runner's home if set here
    # directly, which means the daemon cannot create anything in it. That is
    # not hypothetical: the first job to run died with
    #
    #   unable to init git repo at /var/lib/forgejo-runner/.cache/act/ff/<sha>:
    #   fatal: cannot mkdir ...: Permission denied
    #
    # The generator creates `cache/` and `workspace/` as the runner, so those
    # worked; act creates `$HOME/.cache/act` itself, as the runner, and could
    # not. The generator only creates the directories it knows about, so any
    # implicit write under $HOME is invisible to it -- which is the whole bug
    # class, and the reason the home is a subdirectory the generator owns
    # rather than a parent it happens to have write access to.
    #
    # A subdirectory rather than chowning the parent, because the parent is
    # the parent of `secrets/` -- root:root 0711, holding the 0400 files only
    # the generator reads. Letting the daemon's own uid own that parent would
    # let it rename or replace the secrets directory. Not a leak, but a way
    # for the runner to break its own configuration.
    #
    # createHome = false because the generator unit creates the directory
    # explicitly; NixOS's activation would otherwise create it as a plain
    # directory before the generator has set the ownership and mode.
    home = "/var/lib/forgejo-runner/home";
    createHome = false;

    extraGroups = [ "docker" ];
  };

  environment.systemPackages = [ pkgs.forgejo-runner ];

  # ---------------------------------------------------------------------
  # Nix, for the VM's own system
  # ---------------------------------------------------------------------
  # The host configuration is no longer built here; the dedicated host
  # runner has that job. Nix remains installed for the VM's own system and
  # for the Docker host executor, so the flake settings stay.
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Two jobs is enough for the VM's own system rebuilds. The heavy
  # NixOS-Config/ROCm closure no longer builds here; it moved to the host
  # runner. Keeping max-jobs low also leaves CPU and memory for the Docker
  # jobs that are the VM's actual workload.
  nix.settings.max-jobs = 2;

  # The VM's store only holds this system and the Docker-side runner's
  # packages, so the free-space thresholds can be much smaller than the
  # 15G/20G the host-build era needed. The cache guard is what protects the
  # shared 100 GiB disk; this only keeps Nix from accumulating old system
  # generations.
  nix.settings.min-free = "5G";
  nix.settings.max-free = "10G";

  # Daily, not weekly: the VM is re-created often enough that a weekly GC
  # would let old generations accumulate across the artifacts and cache that
  # share this disk. The host's own daily GC covers its store.
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 3d";
  };
  nix.settings.auto-optimise-store = true;

  # ---------------------------------------------------------------------
  # The generated config
  # ---------------------------------------------------------------------
  # forgejo-runner-config.service writes /var/lib/forgejo-runner/config.yaml
  # from the secrets apply.sh rendered into the instance, then
  # forgejo-runner.service runs the daemon against it. Two units because
  # the two have different lifecycles: the config is generated once per
  # boot (and once per secret change, by the reconciler), the daemon
  # restarts independently of it.
  #
  # The generator FAILS when the secrets are absent -- deliberately, and
  # it is the caddy pattern: on the first deploy the instance comes up
  # before apply.sh has rendered anything, the generator fails, the
  # daemon (which Requires it) stays down, and apply.sh then renders the
  # secrets and restarts both units via secretConsumers. A runner that
  # started without credentials would poll Forgejo, fail authentication
  # forever and look like a network problem.
  systemd.services.forgejo-runner-config = {
    description = "Generate the Forgejo runner config from the rendered secrets";

    wantedBy = [ "multi-user.target" ];

    # The secrets, the config and the daemon's state live on the single
    # root disk. There is no data volume to wait for; the generator's own
    # `install -d` creates the directories after boot.

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    # A NixOS unit's PATH is coreutils/findutils/grep/sed/systemd and
    # nothing else; everything used below is coreutils and named
    # through this path rather than assumed.
    path = [ pkgs.coreutils ];

    script = ''
      set -eu

      secrets=/var/lib/forgejo-runner/secrets
      uuid=$(cat "$secrets/runner-uuid")
      token=$(cat "$secrets/runner-token")

      # Everything the daemon writes, created as root so the daemon never
      # has to. `home` comes first and is what the other two live under: it is
      # $HOME, so act writes $HOME/.cache/act/... into it, which is a path
      # nothing here enumerates and which cost the first job until it was
      # created. One `install -d` for the parent is enough -- the other two
      # are then inside a directory the runner owns -- but they are named
      # explicitly anyway so a fresh root disk has them with the right mode
      # rather than whatever the daemon's umask leaves.
      install -d -o forgejo-runner -g forgejo-runner -m 0750 \
        /var/lib/forgejo-runner/home
      install -d -o forgejo-runner -g forgejo-runner -m 0750 \
        /var/lib/forgejo-runner/home/cache \
        /var/lib/forgejo-runner/home/workspace

      # The two values interpolated inside the heredoc below
      # are expanded by the shell at runtime, not by Nix at
      # build time -- they come from the rendered files, never
      # from the image. The heredoc is deliberately unquoted
      # for exactly that reason, and the YAML contains no
      # other $ or `, so there is nothing else for the shell
      # to expand.
      cat > /var/lib/forgejo-runner/config.yaml.new <<EOF
log:
  level: info
  job_level: info
runner:
  # Where the registration result would be stored. Unused in this
  # design -- the daemon takes its connection from server.connections
  # below -- but kept so a stray forgejo-runner register lands in the
  # runner's home directory rather than an arbitrary CWD.
  file: .runner
  capacity: 2
  envs:
    # The k3s podspec set this on the job container; here it applies to
    # every job the same way.
    DEBIAN_FRONTEND: noninteractive
  timeout: 4h
  shutdown_timeout: 3m
  labels:
    - "default:docker://${jobImage}"
    - "ubuntu-latest:docker://${jobImage}"
    - "ubuntu-24.04:docker://${jobImage}"
    - "docker:host"
cache:
  enabled: true
  dir: /var/lib/forgejo-runner/home/cache
container:
  # The runner creates its own bridge network per job; job containers
  # reach each other, the VM and the internet through it, and nothing
  # else.
  network: ""
  enable_ipv6: false
  privileged: false
  # Extra docker run options, as one string. Empty: no job gets more
  # than the defaults below.
  options: ""
  # Job workspaces, on the shared root disk. A checkout plus its build
  # artefacts can be large; the cache guard and the daily Docker prune are
  # what keep the disk from filling. Workspaces do not survive a re-create,
  # which is fine because they are regenerable.
  workdir_parent: /var/lib/forgejo-runner/home/workspace
  # The security boundary for what a job container may mount: nothing.
  # A workflow that declares volumes fails rather than reading host
  # paths -- the same posture the k3s podspec had (no volumes, no
  # service-account token). Widen with care; '**' allows any mount.
  valid_volumes: []
  # Do not hand the docker socket to job containers. An image build uses
  # the `docker:host` label above and runs on the VM, where Docker is
  # already available; the socket stays inside the VM.
  docker_host: "-"
  force_pull: false
  force_rebuild: false
# Host-executor jobs (the docker:host label) run in a shell forked from
# the daemon, directly on this VM. Their workspace is on the same root disk;
# the cache guard and the Docker prune bound it. The Nix rebuild job moved to
# the host runner, so this executor no longer carries a Nix store.
host:
  workdir_parent: /var/lib/forgejo-runner/home/workspace
server:
  connections:
    forgejo:
      url: ${forgejoUrl}
      uuid: ''${uuid}
      token: ''${token}
EOF

      # Atomic replace, and only when the content changed: a settled
      # redeploy rewrites nothing. The config is the daemon's to read,
      # and it holds the runner token, so 0400 forgejo-runner.
      if ! cmp -s /var/lib/forgejo-runner/config.yaml.new /var/lib/forgejo-runner/config.yaml; then
        chown forgejo-runner:forgejo-runner /var/lib/forgejo-runner/config.yaml.new
        chmod 0400 /var/lib/forgejo-runner/config.yaml.new
        mv /var/lib/forgejo-runner/config.yaml.new /var/lib/forgejo-runner/config.yaml
      else
        rm /var/lib/forgejo-runner/config.yaml.new
      fi
    '';
  };

  # ---------------------------------------------------------------------
  # The daemon
  # ---------------------------------------------------------------------
  systemd.services.forgejo-runner = {
    description = "Forgejo Actions runner";
    documentation = [ "https://forgejo.org/docs/latest/admin/actions/" ];

    wantedBy = [ "multi-user.target" ];

    # docker.service: the daemon checks the socket is reachable before
    # it declares itself (configCheck -> envcheck.CheckIfDockerRunning)
    # and exits if it is not. forgejo-runner-config.service: the config
    # it runs from. Both are Requires, not Wants: a runner without a
    # config or without Docker is not a runner.
    requires = [ "docker.service" "forgejo-runner-config.service" ];
    after = [ "docker.service" "forgejo-runner-config.service" "network-online.target" ];
    wants = [ "network-online.target" ];

    # A NixOS unit's PATH is coreutils/findutils/grep/sed/systemd and
    # nothing else. The `docker:host` executor forks a shell from this
    # process and inherits its environment, so everything that job needs has
    # to be here: git and docker for the work, and -- easy to miss -- nodejs,
    # because actions/checkout and any other JS action are run with a NodeJS
    # that will NOT be installed for you. `nix` is deliberately absent: the
    # Nix rebuild job moved to the host runner.
    path = with pkgs; [
      bash
      coreutils
      findutils
      gnugrep
      gnused
      gnutar
      gzip
      xz
      git
      nodejs
      curl
      cacert
      openssh
      jq
      docker
    ];

    serviceConfig = {
      User = "forgejo-runner";
      Group = "forgejo-runner";
      WorkingDirectory = "/var/lib/forgejo-runner/home";

      # The store path, not a bare name -- a NixOS service gets a PATH
      # from the unit's `path` or nothing, and the daemon is invoked
      # here exactly once.
      ExecStart = "${pkgs.forgejo-runner}/bin/forgejo-runner daemon --config /var/lib/forgejo-runner/config.yaml";

      # The runner holds jobs for up to `timeout`; a restart must not
      # cut a running job off, so it only restarts on failure and waits
      # (the daemon itself drains jobs on TERM within shutdown_timeout).
      Restart = "on-failure";
      RestartSec = "5s";

      # The daemon drains jobs for up to `shutdown_timeout` (3m) on TERM.
      # systemd's default stop timeout is 90s, so without this an explicit
      # stop (a deploy, or the cache guard below) would SIGKILL the daemon
      # halfway through that drain.
      TimeoutStopSec = "4min";

      # Hardening. The daemon talks to two things: the Docker socket
      # (connect only -- a read-only /var does not prevent that, it is
      # a socket, not a write) and Forgejo over the network. Everything
      # it writes is under /var/lib/forgejo-runner, which is the one
      # writable path. NoNewPrivileges is safe: the containers a job
      # runs are created by dockerd as root, not by this process.
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ReadWritePaths = "/var/lib/forgejo-runner";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
    };
  };

  # ---------------------------------------------------------------------
  # Docker hygiene
  # ---------------------------------------------------------------------
  # Every job pulls its label's image, and Docker never deletes images,
  # stopped containers, unused volumes or build cache on its own. On the
  # single 100 GiB disk those leftovers have to be bounded explicitly. The
  # image prune is the expensive one -- a pruned image is re-pulled by the
  # next job -- so it runs once a day, after the runner so it does not race
  # an in-flight pull. Container/volume/builder prune are cheap and safe:
  # they only remove objects nothing is using.
  systemd.services.forgejo-runner-prune = {
    description = "Prune unused Docker images, containers, volumes and build cache";

    serviceConfig = {
      Type = "oneshot";
    };

    script = ''
      set -eu
      docker=${pkgs.docker}/bin/docker

      "$docker" container prune --force
      "$docker" volume prune --all --force
      "$docker" image prune --all --force
      "$docker" builder prune --all --force
    '';

    after = [ "forgejo-runner.service" ];
  };

  systemd.timers.forgejo-runner-prune = {
    description = "Daily prune of unused Docker data";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Daily, not weekly: the image prune costs a re-pull only for an image
      # unused for a day, and that is exactly the case where reclaiming the
      # space matters. The container/volume/builder prunes are cheap.
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
  };

  # ---------------------------------------------------------------------
  # Cache pressure guard
  # ---------------------------------------------------------------------
  # The artifact cache (`cache.dir` above) is separate from the per-job
  # action checkout cache (`$HOME/.cache/act`) and has no size-based
  # eviction. forgejo-runner v13's GC only removes entries that are
  # incomplete for 5 minutes, unused for 7 days, or older than 30 days
  # (act/artifactcache/caches.go), and it runs at most hourly. A burst of
  # workflows with distinct Cargo.lock hashes can therefore create more
  # multi-gigabyte sccache entries than the disk can hold. When the root
  # disk fills, the next job dies in "Set up job" because `git worktree
  # add` cannot write its checkout into
  # /var/lib/forgejo-runner/home/workspace.
  #
  # This is the safety valve, not the cache policy. When free space on the
  # root disk drops below 10 GiB, stop the daemon (it drains jobs up to
  # shutdown_timeout), remove the cache server's content-addressed blobs and
  # its BoltDB index, and start it again. Both are regenerable; secrets,
  # config.yaml, and job workspaces are untouched. The guard refuses to
  # delete anything if the daemon did not actually stop, so it can never
  # pull the cache out from under a running job.
  systemd.services.forgejo-runner-cache-guard = {
    description = "Wipe the Forgejo runner artifact cache when the root disk is nearly full";

    serviceConfig = {
      Type = "oneshot";

      # `systemctl stop` can legitimately take the runner's full stop
      # timeout (4min, set above), then the wipe and start have to fit.
      TimeoutStartSec = "6min";
    };

    script = ''
      set -eu

      runner=forgejo-runner.service
      cache=/var/lib/forgejo-runner/home/cache
      threshold=$((10 * 1024 * 1024 * 1024))

      df=${pkgs.coreutils}/bin/df
      tail=${pkgs.coreutils}/bin/tail
      rm=${pkgs.coreutils}/bin/rm
      systemctl=${pkgs.systemd}/bin/systemctl
      logger=${pkgs.util-linux}/bin/logger

      # Never start a runner that was deliberately stopped.
      "$systemctl" is-active --quiet "$runner" || exit 0

      # `avail` is the space a non-root writer (the daemon) can use.
      avail=$("$df" --output=avail -B1 /var/lib/forgejo-runner | "$tail" -n 1)
      [ "$avail" -lt "$threshold" ] || exit 0

      "$logger" -t forgejo-runner-cache-guard \
        "root disk has $avail bytes free; wiping the artifact cache"

      # stop is explicit, so Restart=on-failure does not fight it.
      "$systemctl" stop "$runner" || true
      if "$systemctl" is-active --quiet "$runner"; then
        "$logger" -t forgejo-runner-cache-guard -p user.err \
          "runner did not stop; refusing to wipe the cache"
        exit 1
      fi

      "$rm" -rf "$cache/cache" "$cache/bolt.db"
      "$systemctl" start "$runner"

      "$logger" -t forgejo-runner-cache-guard \
        "artifact cache wiped; runner restarted"
    '';
  };

  systemd.timers.forgejo-runner-cache-guard = {
    description = "Check the Forgejo runner root disk for cache pressure";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/15";
      Persistent = true;
    };
  };
}
