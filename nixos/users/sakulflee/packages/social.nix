{ pkgs, ... }: {
  home.packages = with pkgs; [
    discord
    cinny-desktop
    element-desktop
    fluffychat
    signal-desktop
  ];

  # Setting x11 here makes the title bar like any other application and not be GIGANTIC.
  xdg.desktopEntries.cinny = {
    name = "Cinny";
    exec = "env GDK_BACKEND=x11 cinny %U";
    icon = "cinny";
    terminal = false;
    categories = [ "Network" "InstantMessaging" ];
    mimeType = [ "x-scheme-handler/matrix" ];
  };
}
