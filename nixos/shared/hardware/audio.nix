{ pkgs, ...}:
{
  # Disable PulseAudio (outdated)
  services.pulseaudio.enable = false;

  # Enable PipeWire (replaces PulseAudio)
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # Enabled "RealtimeKit System Service"
  # Required for PulseAudio and/or PipeWire to work correctly.
  security.rtkit.enable = true;

  # Additional packages to control PipeWire better
  environment.systemPackages = with pkgs; [
    pavucontrol
  ];
}
