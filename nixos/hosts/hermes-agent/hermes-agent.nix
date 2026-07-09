{ config, pkgs, lib, hermes-agent, ... }: {
  imports = [ hermes-agent.nixosModules.default ];

  sops.defaultSopsFile = ../../secrets/hermes-agent.sops.yaml;
  sops.secrets."hermes-env" = { };

  services.hermes-agent = {
    enable = true;
    addToSystemPackages = true;

    # The upstream "full" package (= `default`) ships a pre-baked venv with
    # anthropic, messaging, matrix, honcho, voice, and all platform backends
    # (nix/packages.nix:46).  We override it to add ddgs (DuckDuckGo web
    # search) as an extraPythonPackage — it's not a declared dep of hermes,
    # and baking it into `package` avoids the NixOS module's effectivePackage
    # override logic that would otherwise blow away the full dep group list.
    # Click is stripped from ddgs (it only needs it for its CLI, not the
    # library API Hermes uses) to avoid the collision checker rejecting the
    # duplicate.  extraDependencyGroups and extraPythonPackages are left at
    # their defaults (empty) so the module uses `cfg.package` as-is.
    package = (hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default).override {
      extraPythonPackages = [
        (pkgs.python312Packages.ddgs.overrideAttrs (old: {
          dontCheckRuntimeDeps = true;
          doInstallCheck = false;
          propagatedBuildInputs = lib.filter
            (p: p.pname != "click")
            (old.propagatedBuildInputs or [ ]);
          passthru = (old.passthru or { }) // {
            requiredPythonModules = lib.filter
              (p: p.pname != "click")
              (old.passthru.requiredPythonModules or [ ]);
          };
        }))
      ];
    };

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

      approvals.mode = "smart";

      compression = {
        enabled = true;
        threshold = 0.85;
      };

      messaging.discord.enabled = true;

      matrix = {
        require_mention = false;
        auto_thread = true;
        session_scope = "room";
        e2ee_mode = "optional";
      };
    };
  };

  nix.settings.max-jobs = 1;

  environment.systemPackages = with pkgs; [
    ripgrep
    ffmpeg
  ];
}
