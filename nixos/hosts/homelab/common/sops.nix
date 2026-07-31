# sops is configured via ../../shared/common/sops.nix (imported by _homelab.nix)
# Each service module declares its own sops.secrets inline.
# This adds the user SSH key so sops-install-secrets can decrypt user-level secrets.
{ ... }: {}
