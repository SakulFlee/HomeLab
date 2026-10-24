{ config, pkgs, ... }:
let
  forgejoUser = "sakulflee";

  gitCredentialHelper = pkgs.writeShellApplication {
    name = "git-credential-forgejo";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      case "''${1:-}" in
        get)
          printf 'username=%s\n' '${forgejoUser}'
          printf 'password=%s\n' "$(cat /var/lib/incus-secrets/forgejo-token)"
          ;;
        *)
          exit 0
          ;;
      esac
    '';
  };
in
{
  networking.hostName = "opencode";

  networking.firewall.enable = false;
  networking.nameservers = [ "192.168.178.1" ];
  services.openssh.enable = false;

  environment.systemPackages = with pkgs; [
    opencode
    git
    gitCredentialHelper
    curl
    jq
    nil
    nixfmt
    fd
    tree
    less
    openssh
    gnupg
  ];

  users.groups.opencode.gid = 990;

  users.users.opencode = {
    isSystemUser = true;
    group = "opencode";
    uid = 990;
    home = "/var/lib/opencode";
    createHome = false;
    shell = pkgs.bashInteractive;
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/opencode 0700 990 990 -"
    "d /srv/workspace 0755 990 990 -"
  ];

  programs.git = {
    enable = true;
    config = {
      user.name = "OpenCode";
      user.email = "opencode@sakul-flee.de";
      init.defaultBranch = "main";
      credential."https://forgejo.sakul-flee.de".helper =
        "!/run/current-system/sw/bin/git-credential-forgejo";
    };
  };

  environment.etc."opencode/opencode.json".text = builtins.toJSON {
    "$schema" = "https://opencode.ai/config.json";
    provider.openrouter.options.apiKey = "{env:OPENROUTER_API_KEY}";
  };

  systemd.services.opencode = {
    description = "OpenCode headless web server";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    startLimitIntervalSec = 0;
    path = config.environment.systemPackages;

    environment = {
      HOME = "/var/lib/opencode";
      XDG_CONFIG_HOME = "/var/lib/opencode/.config";
      XDG_DATA_HOME = "/var/lib/opencode/.local/share";
      XDG_STATE_HOME = "/var/lib/opencode/.local/state";
      XDG_CACHE_HOME = "/var/lib/opencode/.cache";
      XDG_RUNTIME_DIR = "/run/opencode";
      OPENCODE_CONFIG = "/etc/opencode/opencode.json";
      OPENCODE_DISABLE_AUTOUPDATE = "1";
      OPENCODE_SERVER_USERNAME = "opencode";
      BROWSER = "${pkgs.coreutils}/bin/true";
    };

    serviceConfig = {
      Type = "simple";
      User = "opencode";
      Group = "opencode";
      WorkingDirectory = "/srv/workspace";
      ExecStart = "${pkgs.opencode}/bin/opencode web --hostname 0.0.0.0 --port 4096";
      EnvironmentFile = [
        "/var/lib/incus-secrets/opencode-server-env"
        "/var/lib/incus-secrets/opencode-openrouter-env"
      ];
      Restart = "always";
      RestartSec = 5;
      RuntimeDirectory = "opencode";
      RequiresMountsFor = [
        "/var/lib/opencode"
        "/srv/workspace"
      ];
      UMask = "0022";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "full";
      ProtectHome = true;
      ReadWritePaths = [
        "/var/lib/opencode"
        "/srv/workspace"
      ];
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
    };
  };
}
