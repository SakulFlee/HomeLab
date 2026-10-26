{ pkgs, ... }:
let
  # The host runner is deliberately separate from the Incus runner VM:
  # it has the host's own Nix store, so the NixOS-Config flake-lock gate
  # builds the Dendra configuration where its inputs and outputs already
  # live. It declares only `nix-rebuild`, never a Docker or Ubuntu label.
  stateDir = "/var/lib/forgejo-nix-runner";
  forgejoUrl = "http://10.0.0.101:3000";
in
{
  users.groups.forgejo-nix-runner = { };
  users.users.forgejo-nix-runner = {
    isSystemUser = true;
    group = "forgejo-nix-runner";
    home = "${stateDir}/home";
    createHome = false;
    description = "Forgejo Actions host runner for Nix rebuilds";
  };

  # The state tree is the one writable path the runner has. It holds the
  # generated config, the checkout workspace and the runner's home. The Nix
  # store itself stays owned by the Nix daemon.
  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 forgejo-nix-runner forgejo-nix-runner -"
    "d ${stateDir}/home 0750 forgejo-nix-runner forgejo-nix-runner -"
    "d ${stateDir}/workspace 0750 forgejo-nix-runner forgejo-nix-runner -"
  ];

  # The binary stays on PATH for debugging; registration is generated from
  # sops, not run by hand.
  environment.systemPackages = [ pkgs.forgejo-runner ];

  # The config is generated from sops because the runner's uuid/token are
  # persistent credentials, exactly like the VM runner's. The generated file
  # embeds them; the sops secrets stay at /run/secrets and are the source of
  # truth. The manual .runner file from the first registration is removed:
  # FromRegistration() refuses to combine it with server.connections.
  systemd.services.forgejo-nix-runner-config = {
    description = "Generate the host Nix runner config from sops";

    wantedBy = [ "multi-user.target" ];
    before = [ "forgejo-nix-runner.service" ];

    unitConfig.ConditionPathExists = [
      "/run/secrets/forgejo_nix_runner_uuid"
      "/run/secrets/forgejo_nix_runner_token"
    ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    path = with pkgs; [ coreutils ];

    script = ''
      set -eu
      state=${stateDir}
      uuid=$(cat /run/secrets/forgejo_nix_runner_uuid)
      token=$(cat /run/secrets/forgejo_nix_runner_token)

      install -d -o forgejo-nix-runner -g forgejo-nix-runner -m 0750 \
        "$state" "$state/home" "$state/workspace"

      cat > "$state/config.yaml.new" <<EOF
      log:
        level: info
        job_level: info
      runner:
        # The connection comes from server.connections below. The file is kept
        # only so a stray forgejo-runner register lands inside the state
        # directory; no .runner file exists after this generator runs.
        file: .runner
        capacity: 1
        envs:
          DEBIAN_FRONTEND: noninteractive
        timeout: 4h
        shutdown_timeout: 3m
        labels:
          - "nix-rebuild:host"
      cache:
        enabled: false
      container:
        network: ""
        enable_ipv6: false
        privileged: false
        options: ""
        workdir_parent: $state/workspace
        valid_volumes: []
        docker_host: "-"
        force_pull: false
        force_rebuild: false
      host:
        workdir_parent: $state/workspace
      server:
        connections:
          forgejo:
            url: ${forgejoUrl}
            uuid: "$uuid"
            token: "$token"
      EOF

      chown forgejo-nix-runner:forgejo-nix-runner "$state/config.yaml.new"
      chmod 0400 "$state/config.yaml.new"
      mv "$state/config.yaml.new" "$state/config.yaml"

      # The manual registration file would conflict with server.connections;
      # sops is the only source now.
      rm -f "$state/.runner"
    '';
  };

  # The flake-lock gate builds with --no-link, so the Dendra closure is
  # unrooted and the host's daily nix.gc (nixos/modules/gc.nix) collects it.
  systemd.services.forgejo-nix-runner = {
    description = "Forgejo Actions host runner (Nix rebuilds only)";
    wantedBy = [ "multi-user.target" ];
    requires = [ "forgejo-nix-runner-config.service" ];
    after = [ "forgejo-nix-runner-config.service" "network-online.target" "nix-daemon.socket" ];
    wants = [ "network-online.target" ];

    # The host executor forks a shell from the daemon, so everything the
    # flake-lock workflow runs must be here. `nix` talks to the host's own
    # daemon/store; `nodejs` is for actions/checkout; grep/tr appear in the
    # workflow's input loop; jq/curl are for the issue report.
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
      nix
      nodejs
      curl
      cacert
      openssh
      jq
    ];

    serviceConfig = {
      User = "forgejo-nix-runner";
      Group = "forgejo-nix-runner";
      WorkingDirectory = stateDir;
      Environment = [ "HOME=${stateDir}/home" ];
      ExecStart = "${pkgs.forgejo-runner}/bin/forgejo-runner daemon --config ${stateDir}/config.yaml";

      Restart = "on-failure";
      RestartSec = "5s";

      # The daemon drains for up to shutdown_timeout (3m) on TERM.
      TimeoutStopSec = "4min";

      # The runner needs the Nix daemon socket and its own state tree; it
      # does not need the Docker socket, the host filesystem or privileges.
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ReadWritePaths = stateDir;
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
    };
  };
}
