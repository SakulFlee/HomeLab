# Host-side ttyd: a terminal over the web, behind Caddy, VPN-only.
#
# Stateless by design: no volume, no database, nothing to back up. That is why
# there is no entry in services/backup.nix and no snapshot policy anywhere --
# a recreate/rebuild loses nothing because there is nothing to lose.
#
# Reached via ttyd.sakul-flee.de (see hosts/caddy/default.nix). Caddy
# terminates TLS and gates on `remote_ip 100.64.0.0/10`; this service speaks
# plain HTTP on the bridge so the container can dial it at 10.0.0.1 without
# touching the 192.168.178.200 DNAT.
#
# Basic auth stays on even behind the VPN gate: the gate checks the network,
# this checks the caller. The password lives in sops (host-only, never rendered
# into a container) and is read by the unit at every start via LoadCredential,
# so rotating it is `sops set` + rebuild -- no drift like the wireguard-ui
# password, which only seeds the DB on first boot.
{ config, ... }:
{
  services.ttyd = {
    enable = true;
    port = 7681;

    # Interactive shell. Null is rejected by the module's own assertion, so
    # this is explicit rather than a default anyone has to guess at.
    writeable = true;

    # Root + login: the login binary prompts for the account, so this is a full
    # shell behind two gates (VPN + basic auth). Same threat model as the Incus
    # UI vhost: anything past both gates is already a host administrator.
    user = "root";

    username = "admin";
    passwordFile = config.sops.secrets.ttyd_password.path;
  };
}
