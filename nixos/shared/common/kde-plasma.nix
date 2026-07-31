{ config, pkgs, lib, ... }: {
  # KDE & SDDM
  services.desktopManager.plasma6.enable = true;

  xdg.portal = {
    enable = true;
    extraPortals = with pkgs; [ kdePackages.xdg-desktop-portal-kde ];
    config =  {
      common = {
        default = [ "kde" ];
      };
    };
  };

  # !!! READ THIS !!!
  # This is a temporary, possibly unstable, performance fix for KDE Plasma on NixOS.
  # Apparently, the main issue is that QT applications (which KDE Plasma is basically made out of) has to read a lot of different directories (/nix/store/*) on NixOS.
  # This is especially bad in KDE Plasma, as there are many different QT applications trying to find and read all kinds of files ...
  # Additionally, some environment variables which partially control this process (the "where to look") are extremely bloated on NixOS.
  # This patch was found on GitHub (https://github.com/NixOS/nixpkgs/issues/126590#issuecomment-3194531220) and only modifies these lookups, which results in a much more snappier KDE Plasma.
  # In the future, this will be fixed in nixpkgs _somehow_ at which point this should be removed!
  # Note, that this creates copies of a bunch of KDE-related files into a single directory. It does not seem to link these files.
  # If this patch is removed, those copies should be automatically cleaned up from the Nix-store.
  # However, there might also be problems upon KDE updates!
  nixpkgs.overlays = lib.singleton (final: prev: {
    kdePackages = prev.kdePackages // {
      plasma-workspace = let

        # the package we want to override
        basePkg = prev.kdePackages.plasma-workspace;

        # a helper package that merges all the XDG_DATA_DIRS into a single directory
        xdgdataPkg = pkgs.stdenv.mkDerivation {
          name = "${basePkg.name}-xdgdata";
          buildInputs = [ basePkg ];
          dontUnpack = true;
          dontFixup = true;
          dontWrapQtApps = true;
          installPhase = ''
            mkdir -p $out/share
            ( IFS=:
              for DIR in $XDG_DATA_DIRS; do
                if [[ -d "$DIR" ]]; then
                  cp -r $DIR/. $out/share/
                  chmod -R u+w $out/share
                fi
              done
            )
          '';
        };

        # undo the XDG_DATA_DIRS injection that is usually done in the qt wrapper
        # script and instead inject the path of the above helper package
        derivedPkg = basePkg.overrideAttrs {
          preFixup = ''
            for index in "''${!qtWrapperArgs[@]}"; do
              if [[ ''${qtWrapperArgs[$((index+0))]} == "--prefix" ]] && [[ ''${qtWrapperArgs[$((index+1))]} == "XDG_DATA_DIRS" ]]; then
                unset -v "qtWrapperArgs[$((index+0))]"
                unset -v "qtWrapperArgs[$((index+1))]"
                unset -v "qtWrapperArgs[$((index+2))]"
                unset -v "qtWrapperArgs[$((index+3))]"
              fi
            done
            qtWrapperArgs=("''${qtWrapperArgs[@]}")
            qtWrapperArgs+=(--prefix XDG_DATA_DIRS : "${xdgdataPkg}/share")
            qtWrapperArgs+=(--prefix XDG_DATA_DIRS : "$out/share")
          '';
        };

      in derivedPkg;
    };
  });
}
