{ pkgs, ... }:

let
  wrapJetbrainsForDirenv = pkg:
    pkgs.symlinkJoin {
      name = "${pkg.meta.mainProgram}-direnv";
      paths = [ pkg ];
      nativeBuildInputs = [ pkgs.makeWrapper ];
      postBuild = ''
        wrapProgram $out/bin/${pkg.meta.mainProgram} \
          --set XKB_DEFAULT_LAYOUT de \
          --run '
            if command -v direnv &>/dev/null && [ -f .envrc ]; then
              eval "$(direnv export bash 2>/dev/null)"
            fi
          '
      '';
    };
in {
  home.packages = with pkgs; [
    (wrapJetbrainsForDirenv jetbrains.clion)
    (wrapJetbrainsForDirenv jetbrains.datagrip)
    (wrapJetbrainsForDirenv jetbrains.dataspell)
    (wrapJetbrainsForDirenv jetbrains.gateway)
    (wrapJetbrainsForDirenv jetbrains.idea)
    (wrapJetbrainsForDirenv jetbrains.rust-rover)
    (wrapJetbrainsForDirenv pkgs.android-studio)
  ];
}
