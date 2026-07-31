{ config, pkgs, inputs, ... }: {
    imports = [
      inputs.nix-flatpak.nixosModules.nix-flatpak
    ];

    services.flatpak.enable = true;

    # Auto updates
    services.flatpak.update.auto.enable = true;
    services.flatpak.update.auto.onCalendar = "weekly";

    services.flatpak.packages = [
        "org.jdownloader.JDownloader"
    ];

    services.flatpak.remotes = [
        {
          name = "flathub";
          location = "https://dl.flathub.org/repo/flathub.flatpakrepo";
        }
    ];
}
