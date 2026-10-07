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
# Basic auth is deliberately OFF. The VPN gate in Caddy checks the network
# and the login binary checks the caller -- the same two gates SSH over VPN
# has, with no HTTP password in between. A third credential would add a
# secret to manage without adding a layer an attacker does not already face.
# The module requires username and passwordFile as a pair or neither; neither
# it is.
{
  services.ttyd = {
    enable = true;
    port = 7681;

    # Interactive shell. Null is rejected by the module's own assertion, so
    # this is explicit rather than a default anyone has to guess at.
    writeable = true;

    # Root + login: the login binary prompts for the account, so this is a
    # full shell behind the VPN gate plus the system login. Same threat model
    # as SSH over VPN.
    user = "root";
  };
}
