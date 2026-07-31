{ pkgs, config, lib, ... }: {
  # 1. TTY / Console — rotate framebuffer 180°
  boot.kernelParams = [ "fbcon=rotate:2" ];

  # 2. KDE Plasma — rotate via kscreen-doctor on graphical session start
  systemd.user.services.rotate-kde = {
    description = "Rotate KDE Plasma display by 180 degrees";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];

    script = ''
      ${pkgs.kdePackages.libkscreen}/bin/kscreen-doctor output.DP-1.rotation.inverted
    '';
  };
}
