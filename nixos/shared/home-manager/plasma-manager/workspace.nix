{ ... }: {
  programs.plasma.workspace = {
    clickItemTo = "select";
    lookAndFeel = "org.kde.breezedark.desktop";
    wallpaper = "/usr/share/wallpapers/cachyos-wallpapers/PurpleFeathers.png";
  };

  programs.plasma.input.keyboard = {
    layouts = [
      { layout = "de"; }
    ];
  };

  programs.plasma.configFile."kwinrc" = {
    "ElectricBorders" = {
      "BottomLeft" = "NoAction";
      "BottomRight" = "NoAction";
      "TopLeft" = "NoAction";
      "TopRight" = "NoAction";
    };
  };

  programs.plasma.startup.desktopScript."set_desktop_url" = {
    text = ''
      var allDesktops = desktops();
      for (var i = 0; i < allDesktops.length; i++) {
          var d = allDesktops[i];
          d.currentConfigGroup = ["General"];
          d.writeConfig("url", "file:///home/sakulflee/Sync/Desktop");
      }
    '';
    priority = 3;
  };
}
