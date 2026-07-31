{ pkgs, ... }:

let
  srv = pkgs.writeShellScriptBin "srv" ''
    set -e
    if [ $# -lt 1 ]; then
      echo "Usage: srv <service> [action]"
      echo "  action defaults to 'start'"
      echo "  Examples:"
      echo "    srv nixos-auto-update"
      echo "    srv nixos-auto-update restart"
      echo "    srv postgresql status"
      exit 1
    fi

    SERVICE="$1"
    CMD="''${2:-start}"

    systemctl "$CMD" "$SERVICE" &
    journalctl -u "$SERVICE" -f
  '';
in {
  environment.systemPackages = [ srv ];
}
