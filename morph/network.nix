let
  pkgs = import (import ./nixpkgs.nix) { };
in
{
  network = {
    inherit pkgs;
    description = "HomeLab";
  };

  "cf-ddns" =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      imports = [ ./hosts/cf-ddns/configuration.nix ];
    };

  "caddy" =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      imports = [ ./hosts/caddy/configuration.nix ];
    };

  "minecraft" =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      imports = [ ./hosts/minecraft/configuration.nix ];
    };

  # "copyparty" =
  #   {
  #     config,
  #     pkgs,
  #     lib,
  #     ...
  #   }:
  #   {
  #     imports = [ ./hosts/copyparty/configuration.nix ];
  #   };
}
