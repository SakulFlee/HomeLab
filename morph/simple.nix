{
  network = {
    nixpkgs = import ./nixpkgs.nix { };
    description = "HomeLab";
    ordering = {
      tags = [
        "ddns"
        "web"
        "svc"
      ];
    };
  };

  "cf-ddns" = _: {
    deployment.tags = [ "ddns" ];
    system.stateVersion = "25.05";
  };

  "caddy" = _: {
    deployment.tags = [ "web" ];
    system.stateVersion = "25.05";
  };

  "syncthing" = _: {
    deployment.tags = [ "svc" ];
    system.stateVersion = "25.05";
  };

  "minecraft" = _: {
    deployment.tags = [ "svc" ];
    system.stateVersion = "25.05";
  };
}
