{ pkgs, ... }: {
  # Fonts
  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
    font-awesome

    # CJK fonts (Chinese, Japanese, Korean)
    noto-fonts-cjk-sans
    noto-fonts-cjk-serif

    # Additional scripts (Arabic, Hebrew, Thai, Devanagari, etc.)
    noto-fonts

    # Emoji
    noto-fonts-color-emoji
  ];

  fonts.fontconfig = {
    enable = true;
    cache32Bit = true;
    defaultFonts = {
      sansSerif = [ "Noto Sans CJK SC" "Noto Sans" ];
      serif = [ "Noto Serif CJK SC" "Noto Serif" ];
      monospace = [ "JetBrainsMono Nerd Font" ];
    };
  };
}
