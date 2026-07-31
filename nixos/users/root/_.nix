{ config, lib, pkgs, ... }: {
  config = {
    users.users.root = {
      shell = pkgs.zsh;
    };

    home-manager.users.root = {
      imports = [ ../../shared/home-manager/zsh.nix ];

      home.stateVersion = "25.11";
    };
  };
}
