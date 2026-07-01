# TODO

## Jellyfin hardware acceleration (VA-API passthrough)

- [ ] Configure `/dev/dri` device passthrough for unprivileged LXC
- [ ] Set `services.jellyfin.hardwareAcceleration = true`
- [ ] Install `intel-media-driver` / `va-driver-all` / `mesa-va-drivers`
- [ ] Add `jellyfin` user to `render` and `video` groups
