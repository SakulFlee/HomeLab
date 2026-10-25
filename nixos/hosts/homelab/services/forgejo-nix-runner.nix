{ pkgs, ... }:
let
  # The host runner is deliberately separate from the Incus runner VM:
  # it has the host's own Nix store, so the NixOS-Config flake-lock gate
  # builds the Dendra configuration where its inputs and outputs already
  # live. It declares only `nix-rebuild`, never a Docker or Ubuntu label.
  stateDir = "/var/lib/forgejo-nix-runner";

  configFile = pkgs.writeText "forgejo-nix-runner.yaml" ''
    log:
      level: info
      job_level: info
    runner:
      # `forgejo-runner register` writes this file with the uuid/token and
      # address; the daemon's FromRegistration() turns it into
      # server.connections. It is created once, by hand, as the service user.
      file: .runner
      capacity: 1
      envs:
        DEBIAN_FRONTEND: noninteractive
      timeout: 4h
      shutdown_timeout: 3m
      labels:
        - "nix-rebuild:host"
    cache:
      # No artifact cache here. The flake-lock workflow does not use
      # actions/cache, and the host runner must not grow another cache.
      enabled: false
    container:
      network: ""
      enable_ipv6: false
      privileged: false
      options: ""
      workdir_parent: ${stateDir}/workspace
      valid_volumes: []
      docker_host: "-"
      force_pull: false
      force_rebuild: false
    host:
      workdir_parent: ${stateDir}/workspace
  '';
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
  # registration file (uuid/token), the checkout workspace and the runner's
  # home. The Nix store itself stays owned by the Nix daemon.
  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 forgejo-nix-runner forgejo-nix-runner -"
    "d ${stateDir}/home 0750 forgejo-nix-runner forgejo-nix-runner -"
    "d ${stateDir}/workspace 0750 forgejo-nix-runner forgejo-nix-runner -"
  ];

  # The one-time registration command runs from PATH.
  environment.systemPackages = [ pkgs.forgejo-runner ];

  # The flake-lock gate builds with --no-link, so the Dendra closure is
  # unrooted and the host's weekly nix.gc (nixos/modules/gc.nix) collects it.
  # If that churn is too large for a weekly window, shorten the host GC; the
  # runner itself has no artifact cache.
  systemd.services.forgejo-nix-runner = {
    description = "Forgejo Actions host runner (Nix rebuilds only)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "nix-daemon.socket" ];
    wants = [ "network-online.target" ];

    # No .runner file means no uuid/token. v13 exits with "runner: 0 server
    # connections configured, terminating"; making the unit skip instead of
    # fail keeps a host rebuild safe before the one-time registration.
    unitConfig.ConditionPathExists = [ "${stateDir}/.runner" ];

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
      ExecStart = "${pkgs.forgejo-runner}/bin/forgejo-runner daemon --config ${configFile}";

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
