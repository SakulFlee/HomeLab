{ lib, pkgs, ... }: {
  services.displayManager = {
    sddm = {
      enable = true;
      wayland.enable = true;

      settings = {
        Input = {
          "Keyboard.layout" = "de";
        };
        Theme = {
          CursorTheme = "Bibata-Modern-Classic";
          CursorSize = 24;
          Font = "Noto Sans,10,-1,0,400,0,0,0,0,0,0,0,0,0,0,1,,0,0";
        };
      };

      wayland.compositorCommand =
        "${pkgs.coreutils}/bin/env XKB_DEFAULT_LAYOUT=de ${lib.getBin pkgs.kdePackages.kwin}/bin/kwin_wayland --no-global-shortcuts --no-kactivities --no-lockscreen --locale1";
    };

    # mkDefault so hosts (e.g. SteamDeck via Jovian) can override
    defaultSession = lib.mkDefault "plasma";
  };

  environment.systemPackages = with pkgs; [
    kdePackages.sddm-kcm
  ];
}
