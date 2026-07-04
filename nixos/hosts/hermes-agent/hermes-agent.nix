{ config, pkgs, lib, hermes-agent, ... }: {
  imports = [ hermes-agent.nixosModules.default ];

  sops.defaultSopsFile = ../../secrets/hermes-agent.sops.yaml;
  sops.secrets."hermes-env" = { };

  services.hermes-agent = {
    enable = true;
    addToSystemPackages = true;

    extraDependencyGroups = [ "messaging" ];

    environmentFiles = [ config.sops.secrets."hermes-env".path ];

    authFile = pkgs.writeText "auth.json" "{}";

    settings = {
      model = {
        provider = "opencode-go";
        default = "deepseek-v4-flash";
      };

      terminal.backend = "local";
      terminal.cwd = "/var/lib/hermes/workspace";
      toolsets = [ "all" ];

      compression = {
        enabled = true;
        threshold = 0.85;
      };

      messaging.discord.enabled = true;
    };
  };

  nix.settings.max-jobs = 1;

  environment.systemPackages = with pkgs; [
    ripgrep
    ffmpeg
  ];
}
