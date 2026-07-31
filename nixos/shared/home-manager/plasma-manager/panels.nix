{ ... }: {
  programs.plasma.panels = [
    {
      location = "top";
      height = 28;
      floating = true;
      alignment = "center";
      lengthMode = "fill";
      hiding = "dodgewindows";

      widgets = [
        "org.kde.plasma.kickoff"
        "org.kde.plasma.appmenu"
        "org.kde.plasma.panelspacer"
        "org.kde.plasma.pager"
        "org.kde.plasma.systemtray"
        {
          digitalClock = {
            time.format = "24h";
          };
        }
      ];
    }

    {
      location = "bottom";
      height = 44;
      floating = true;
      alignment = "center";
      lengthMode = "fit";
      hiding = "dodgewindows";

      widgets = [
        {
          name = "org.kde.plasma.icontasks";
          config = {
            General = {
              launchers = [
                "preferred://filemanager"
                "preferred://browser"
                "applications:discord.desktop"
                "applications:obsidian.desktop"
                "applications:thunderbird.desktop"
                "applications:kitty.desktop"
              ];
            };
          };
        }
      ];
    }
  ];
}
