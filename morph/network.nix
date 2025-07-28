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
}
