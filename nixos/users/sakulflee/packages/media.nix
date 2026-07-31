{ pkgs, inputs, ... }: {
  home.packages = with pkgs; [
    vlc
    yt-dlp
    ffmpeg
    inputs.fansly-recorder.packages.x86_64-linux.default
    obs-studio
  ];
}
