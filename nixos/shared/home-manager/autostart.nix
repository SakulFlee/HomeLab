{ pkgs, ... }: {
  # Link autostart entries
  xdg.configFile."autostart/sunshine.desktop".source = "${pkgs.sunshine}/share/applications/sunshine.desktop";
  xdg.configFile."autostart/obsidian.desktop".source = "${pkgs.obsidian}/share/applications/obsidian.desktop";
  xdg.configFile."autostart/keepassxc.desktop".source = "${pkgs.keepassxc}/share/applications/keepassxc.desktop";

  xdg.configFile."autostart/steam.desktop".text = ''
    [Desktop Entry]
    Name=Steam
    Comment=Application for managing and playing games on Steam
    Exec=${pkgs.steam}/bin/steam -silent
    Icon=steam
    Terminal=false
    Type=Application
    Categories=Network;FileTransfer;Game;
  '';

  xdg.configFile."autostart/discord.desktop".text = ''
    [Desktop Entry]
    Name=Discord
    Comment=All-in-one voice and text chat for gamers that's free, secure, and works on both your desktop and phone.
    Exec=${pkgs.discord}/bin/discord --start-minimized
    Icon=discord
    Terminal=false
    Type=Application
    Categories=Network;InstantMessaging;
  '';
}

