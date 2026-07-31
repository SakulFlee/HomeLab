{ config, pkgs, lib, inputs, ... }: {
  imports = [ inputs.hermes-agent.nixosModules.default ];

  sops.secrets."hermes-env" = {};

  services.hermes-agent = {
    enable = true;
    addToSystemPackages = true;

    package = (inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default).override {
      extraPythonPackages = [
        (pkgs.python312Packages.ddgs.overrideAttrs (old: {
          dontCheckRuntimeDeps = true;
          doInstallCheck = false;
          propagatedBuildInputs = lib.filter
            (p: p.pname != "click")
            (old.propagatedBuildInputs or []);
          passthru = (old.passthru or {}) // {
            requiredPythonModules = lib.filter
              (p: p.pname != "click")
              (old.passthru.requiredPythonModules or []);
          };
        }))
      ];
    };

    environmentFiles = [ config.sops.secrets."hermes-env".path ];

    authFile = pkgs.writeText "auth.json" "{}";

    settings = {
      model = {
        provider = "auto";
        default = "opencode-go/deepseek-v4-flash";
      };

      custom_providers = [
        {
          name = "llama-swap";
          base_url = "http://127.0.0.1:30001/v1";
          discover_models = true;
        }
      ];

      terminal.backend = "local";
      terminal.cwd = "/var/lib/hermes/workspace";
      toolsets = [ "all" ];

      approvals.mode = "smart";

      compression = {
        enabled = true;
        threshold = 0.85;
      };

      messaging.discord.enabled = true;
    };
  };

  systemd.services.hermes-agent.environment = {
    MATRIX_AUTO_THREAD = "false";
    MATRIX_DM_AUTO_THREAD = "false";
    MATRIX_REQUIRE_MENTION = "false";
    MATRIX_SESSION_SCOPE = "room";
    MATRIX_E2EE_MODE = "optional";
  };

  services.ollama.enable = lib.mkForce false;

  nix.settings.max-jobs = 1;

  environment.systemPackages = with pkgs; [
    ripgrep
    ffmpeg
  ];

  services.homelab-restic = {
    enable = true;
    paths = [ "/var/lib/hermes" ];
  };
}
