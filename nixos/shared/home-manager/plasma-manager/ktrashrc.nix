{ ... }: {
  programs.plasma.configFile."ktrashrc" = {
    "/home/sakulflee/.local/share/Trash" = {
      "UseSizeLimit" = true;
      "Percent" = 10;
      "LimitReachedAction" = 0;
      "UseTimeLimit" = true;
      "Days" = 30;
    };
  };
}
