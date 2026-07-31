{ pkgs, ... }: {
  home.packages = with pkgs; [
    blender
    krita
    gimp
  ];
}
