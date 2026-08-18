{ pkgs, lib, ... }:

let
  # Jellyfin's ffmpeg generates Vulkan init flags that conflict with
  # scale_vaapi on AMD RADV. This wrapper invokes the real ffmpeg
  # directly, bypassing the default wrapper that would add those flags.
  # We use symlinkJoin so ffprobe and other ffmpeg binaries are preserved.
  jellyfin-ffmpeg-no-vulkan = pkgs.symlinkJoin {
    name = "jellyfin-ffmpeg-no-vulkan";
    paths = [
      (pkgs.writeShellScriptBin "ffmpeg" ''
        exec ${pkgs.jellyfin-ffmpeg}/bin/ffmpeg "$@"
      '')
      pkgs.jellyfin-ffmpeg
    ];
  };
in {
  services.jellyfin = {
    enable = true;
    package = pkgs.jellyfin.override {
      jellyfin-ffmpeg = jellyfin-ffmpeg-no-vulkan;
    };

    # Manage encoding config from NixOS
    forceEncodingConfig = true;

    hardwareAcceleration = {
      enable = true;
      type = "vaapi";
      device = "/dev/dri/renderD128";
    };

    transcoding = {
      enableHardwareEncoding = true;
      enableToneMapping = false;
    };
  };

  # Jellyfin needs access to /dev/dri/renderD128 for AMD VAAPI HW transcoding
  # and access to NAS media shares
  users.users.jellyfin.extraGroups = [ "video" "render" "media" ];
}
