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
# instance model (immutable image, disposable root disk, volumes).
{ config, lib, pkgs, inputs, ... }:

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
  # roughly 2.2 GiB against 1.4 GiB -- paid once per VM, and pruned weekly by
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
  runnerLabels = [
    "default:docker://${jobImage}"
    "ubuntu-latest:docker://${jobImage}"
    "ubuntu-24.04:docker://${jobImage}"
  ];
in
{
  # ---------------------------------------------------------------------
  # The disk image
  # ---------------------------------------------------------------------
  # The root disk has to hold three things at once: the NixOS closure
  # (/nix/store is NOT a separate filesystem here -- it is the same
  # partition as /), the Docker image store, and a running job's
  # writable layer. Measured on the first real job, with one
  # 5.06 GB CI image pulled:
  #
  #   at rest    7.3 G used   1.9 G free   80%
  #   in a job   8.8 G used   360 M free   97%
  #
  # which is not enough headroom to be useful. The label image itself
  # (ghcr.io/catthehacker/ubuntu:act-24.04) unpacks to roughly 2.2 GB,
  # so a workflow that does NOT pin its own image would fail to pull
  # with ENOSPC the moment a large CI image is also present.
  #
  # 40G: the closure, several 5 GB CI images, and concurrent job
  # layers, with room to spare. It is a cap on the qcow2's virtual size
  # and costs nothing on the host while unused -- the file stays sparse.
  #
  # WHY AN OVERRIDE AND NOT `virtualisation.diskSize`, which looks like
  # exactly the right knob and is not:
  #
  #   nixos/modules/virtualisation/disk-size-option.nix declares it as
  #   `either (enum ["auto"]) ints.positive` -- an integer is valid --
  #   but qemu-vm.nix only uses it for the disk of the VM it starts to
  #   RUN a build in (DISK_SIZE_MB at line 140). The image itself comes
  #   from incus-virtual-machine.nix, which calls make-disk-image.nix
  #   directly and passes neither `diskSize` nor `additionalSpace`.
  #
  # So the image inherits make-disk-image's defaults: diskSize "auto"
  # (computed as requiredFilesystemSpace + additionalSpace) and
  # `additionalSpace ? "512M"`. That 512 MB -- plus the closure -- is
  # where the 10 GiB came from, and setting virtualisation.diskSize
  # would change nothing at all while looking like it should.
  #
  # mkForce, because incus-virtual-machine.nix already defines this
  # attribute; two definitions of the same option is a conflict error.
  # The call below is that module's verbatim, plus `additionalSpace`.
  # If nixpkgs changes the arguments make-disk-image.nix takes, this
  # breaks loudly at evaluation rather than quietly producing a
  # differently-shaped image.
  system.build.qemuImage = lib.mkForce (import "${inputs.nixpkgs}/nixos/lib/make-disk-image.nix" {
    inherit pkgs lib config;
    partitionTableType = "efi";
    format = "qcow2-compressed";
    copyChannel = config.system.installer.channel.enable;
    additionalSpace = "40G";
  });

  imports = [ ./disk.nix ];

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

    # Home is a directory INSIDE the data volume, not the volume's mount point.
    #
    # The mount point is root:root 0755, which is correct for a filesystem
    # root -- and it is also the runner's home if set here directly, which
    # means the daemon cannot create anything in it. That is not hypothetical:
    # the first job to run died with
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
    # A subdirectory rather than chowning the mount point, because the mount
    # point is the parent of `secrets/` -- root:root 0711, holding the 0400
    # files only the generator reads. Letting the daemon's own uid own that
    # parent would let it rename or replace the secrets directory. Not a leak,
    # but a way for the runner to break its own configuration.
    #
    # createHome = false because the directory lives on the volume, and the
    # generator unit creates it after the mount; NixOS's activation would
    # otherwise create it on the root disk where the mount would hide it.
    home = "/var/lib/forgejo-runner/home";
    createHome = false;

    extraGroups = [ "docker" ];
  };

  environment.systemPackages = [ pkgs.forgejo-runner ];

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

    # The secrets, the config and the daemon's state all live on the
    # data volume. systemd's RequiresMountsFor= pulls in the .mount unit (and,
    # through it, the format unit), so this cannot run against the root disk
    # -- the failure mode it prevents is a config.yaml written to the volatile
    # root disk and lost on the next re-create.
    #
    # This is the systemd directive, reached through `unitConfig`, because
    # NixOS has no `services.*.requiresMountsFor` option of its own -- nixpkgs
    # spells it the same way in swap.nix, alsa.nix and security/wrappers.
    unitConfig.RequiresMountsFor = [ "/var/lib/forgejo-runner" ];

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
      # explicitly anyway so a fresh volume has them with the right mode
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
  # below -- but kept so a stray `forgejo-runner register` lands on the
  # volume instead of the root disk.
  file: .runner
  capacity: 4
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
  # Job workspaces, on the data volume rather than the root disk: a
  # checkout plus its build artefacts can be large, and the volume is
  # where anything that should outlive a re-create lives.
  workdir_parent: /var/lib/forgejo-runner/home/workspace
  # The security boundary for what a job container may mount: nothing.
  # A workflow that declares volumes fails rather than reading host
  # paths -- the same posture the k3s podspec had (no volumes, no
  # service-account token). Widen with care; '**' allows any mount.
  valid_volumes: []
  # Do not hand the docker socket to job containers. A job that needs
  # Docker (a docker build, a compose stack) asks the runner, and the
  # runner runs it as a sibling container -- the socket stays inside
  # the VM.
  docker_host: "-"
  force_pull: false
  force_rebuild: false
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
  # Image hygiene
  # ---------------------------------------------------------------------
  # Every job pulls its label's image, and pulled images are never
  # deleted by Docker. Without this, /var/lib/docker on the root disk
  # grows without bound -- the same reason the host runs a weekly
  # crictl prune for k3s (see hosts/homelab/services/k3s.nix). Weekly
  # rather than more often: a pruned image is re-pulled by the next job,
  # so pruning mid-day only moves bytes.
  systemd.services.forgejo-runner-prune = {
    description = "Prune unused Docker images left by finished jobs";

    serviceConfig = {
      Type = "oneshot";
      # Docker's own client, by store path: a NixOS
      # service gets a PATH of coreutils and little else, so the daemon has to
      # be named in full rather than left to PATH.
      ExecStart = "${pkgs.docker}/bin/docker image prune --all --force";
    };

    # After the daemon so a prune never runs while a job is pulling;
    # `docker image prune --all` skips images in use by a container, but
    # an image being pulled is not in use yet.
    after = [ "forgejo-runner.service" ];
  };

  systemd.timers.forgejo-runner-prune = {
    description = "Daily prune of unused Docker images";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Daily, not weekly. A prune exists to stop unused images filling
      # the disk, and being wrong about the interval is asymmetric: too
      # long and a job cannot pull the image it needs, too short and a job
      # re-pulls an image it used yesterday. Weekly was sized for a disk
      # with room to spare; measured on the first real job, with one
      # 5.06 GB CI image pulled, the root disk was at 97% and 360 MB free.
      # `docker image prune --all` skips images a container is using, so a
      # daily prune costs a re-pull only for an image unused for a day --
      # which is precisely the case where reclaiming the space is the point.
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
  };
}
