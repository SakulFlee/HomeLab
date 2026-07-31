{ config, pkgs, lib, inputs, ... }:
{
  imports = [
    inputs.jovian.nixosModules.default
    ./hardware.nix
    ../../shared/common/_.nix
    ../../users/_.nix
  ];

  jovian.steam = {
    enable = true;
    autoStart = true;
    user = "sakulflee";
    desktopSession = "plasma";
  };

  networking.hostName = "SteamDeck";

  programs.gamescope = {
    enable = true;
    capSysNice = false;
  };

  home-manager.users.sakulflee = {
    programs.plasma.configFile."kwinrulesrc" = {
      "General" = { count = 1; };
      "1" = {
        Description = "Virtual Keyboard - prevent focus steal";
        windowclass = "maliit_keyboard";
        windowclassrule = 2;
        acceptfocus = "false";
        acceptfocusrule = 3;
      };
    };
  };

  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id == "org.freedesktop.udisks2.filesystem-mount" &&
          subject.isInGroup("wheel")) {
        return polkit.Result.YES;
      }
    });
  '';
}
