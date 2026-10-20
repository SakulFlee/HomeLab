{ config, lib, pkgs, ... }:

let
  # The registry is still the only list of instances. Only the spec bundle is
  # generated; the rendering itself lives in incus-secrets.sh.
  instances = import ../../../incus-instances.nix;
  instanceProjects = import ../../../incus-instance-projects.nix;

  specs = pkgs.writeText "incus-secrets-specs.json" (builtins.toJSON {
    inherit instances;
    projects = instanceProjects;
  });

  incusSecrets = pkgs.writeShellApplication {
    name = "incus-secrets";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.jq
      config.virtualisation.incus.package
    ];
    # The script is intentionally not shellcheck-gated here: it is a direct,
    # tested port of apply.sh's render_secrets and sync_incus_trust, and the
    # guest-side quoting that check complains about is load-bearing.
    checkPhase = "";
    text = builtins.readFile ./incus-secrets.sh;
  };
in
{
  # ---------------------------------------------------------------------
  # Secrets and client-certificate trust
  #
  # This is the only imperative thing left on the host now that OpenTofu owns
  # instance/image/volume/network lifecycle. It is also the one thing Tofu
  # cannot do without either writing plaintext secrets into state or failing to
  # notice a rotated file (source_path uploads are not content-diffed).
  #
  # It runs at boot, when /run/secrets changes, and on a timer as a safety net.
  # The timer is the staleness bound for a change sops-nix makes without
  # touching /etc/nixos -- the same role incus-reconcile.timer used to have,
  # now with a much smaller job.
  # ---------------------------------------------------------------------
  systemd.services.incus-secrets = {
    description = "Render host secrets into the running Incus instances";

    after = [ "incus.service" "sops-install-secrets.service" ];
    wants = [ "network-online.target" ];
    requires = [ "incus.service" ];

    environment.INCUS_SECRETS_SPECS = "${specs}";

    serviceConfig = {
      Type = "oneshot";
      # A stopped instance is skipped; a secret render is a handful of execs.
      TimeoutStartSec = "10min";
    };

    script = "exec ${incusSecrets}/bin/incus-secrets";
  };

  systemd.timers.incus-secrets = {
    description = "Periodically re-render host secrets into Incus instances";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
      RandomizedDelaySec = "30s";
      AccuracySec = "1min";
      Persistent = false;
    };
  };

  # sops-nix replaces files under /run/secrets, which changes entries in that
  # directory. The timer covers a missed event; this covers the normal case
  # immediately.
  systemd.paths.incus-secrets = {
    description = "Watch the decrypted secret directory";
    wantedBy = [ "default.target" ];
    pathConfig = {
      PathModified = [ "/run/secrets" ];
      Unit = "incus-secrets.service";
    };
  };
}
