# A NixOS module for wireguard-ui.
#
# Nixpkgs packages the binary (pkgs/by-name/wi/wireguard-ui) but ships no service
# module, so this is one. Everything below is derived from reading the source of
# the package we are actually running, not from the upstream README:
#
#   * the tunnel interface is hardcoded to `wg0` (util/config.go) and cannot be
#     configured, so there is deliberately no option for it here;
#   * the client database is opened as the *relative* path ./db
#     (main.go: jsondb.New("./db")), which makes the systemd working directory
#     load-bearing -- see dataDir below;
#   * there is no exec.Command anywhere in the source, so the interface is
#     configured over netlink with wgctrl rather than by shelling out to
#     wg-quick. That is why wireguard-tools is not a dependency here.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.wireguard-ui;

  # -session-secret takes its value inline on the command line, so it cannot be
  # passed through the environment or an EnvironmentFile. A wrapper is the only
  # way to keep it out of the Nix store (and therefore out of world-readable
  # /nix/store, where anyone on the LAN could read it).
  #
  # This matters: the compiled-in default is a fixed string in the upstream
  # source, published in every checkout of it. Left alone, anyone who has read
  # it can mint a session cookie for the admin UI and skip the login entirely.
  # The UI can add a client that reaches the whole homelab.
  wrapper =
    let
      quoted = lib.escapeShellArgs cfg.extraArgs;
      secretFlag =
        if cfg.sessionSecretFile == null then
          ""
        else
          # `cat` inside a subshell rather than a Nix readFile, so the value is
          # only ever read at service start.
          ''-session-secret "$(cat ${cfg.sessionSecretFile})"'';
    in
    pkgs.writeShellScript "wireguard-ui-wrapper" ''
      set -eu
      exec ${lib.getExe cfg.package} \
        -bind-address ${cfg.bindAddress} \
        ${secretFlag} \
        ${quoted}
    '';
in
{
  options.services.wireguard-ui = {
    enable = lib.mkEnableOption "wireguard-ui, a web interface for WireGuard";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.wireguard-ui;
      defaultText = lib.literalExpression "pkgs.wireguard-ui";
      description = "The wireguard-ui package to run.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/wireguard-ui";
      example = "/var/lib/wireguard-ui";
      description = ''
        Working directory for the service, and the only thing here that is
        genuinely load-bearing: upstream opens its database as the relative path
        `./db` (main.go), so the client records, the server settings and the
        login user are all created beneath `${config.services.wireguard-ui.dataDir}/db`.

        This is the only state in the instance that cannot be regenerated.
        Point it at the root disk instead of the data volume and every
        previously issued client key -- including the phone's -- is gone, while
        the service still starts and still looks healthy.
      '';
    };

    bindAddress = lib.mkOption {
      type = lib.types.str;
      example = "192.168.178.210:51821";
      description = ''
        Address:port for the web UI. Bound to an address rather than 0.0.0.0 on
        purpose: the UI can hand out a working client for the whole homelab, so
        it should not be on every interface the machine has.
      '';
    };

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 51820;
      description = ''
        UDP port the WireGuard interface listens on. This is the tunnel, not
        the web UI -- they are separate settings and upstream defaults both to
        numbers that invite confusion.
      '';
    };

    serverInterfaceAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = [ "100.64.0.1/24" ];
      description = ''
        Addresses to put on the tunnel interface. Upstream joins these with
        commas (util.LookupEnvOrStrings), so more than one is allowed.

        The upstream default is 10.252.1.0/24, left over from a headscale-era
        tailnet. Set this explicitly.
      '';
    };

    endpointAddress = lib.mkOption {
      type = lib.types.str;
      example = "wg.example.com:51820";
      description = ''
        Public endpoint written into generated client configs. This must be the
        name and port the router forwards, not this instance's LAN address, or
        every client config it hands out will be unusable from outside.
      '';
    };

    dnsServers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Resolvers advertised to clients. Comma-joined by upstream.";
    };

    mtu = lib.mkOption {
      type = lib.types.int;
      default = 1420;
      description = ''
        MTU advertised to clients. Upstream defaults to 1450. If existing
        clients were issued with a different value, keep it: an MTU mismatch
        shows up as unexplained throughput loss on a phone rather than as an
        error anywhere.
      '';
    };

    persistentKeepalive = lib.mkOption {
      type = lib.types.int;
      default = 25;
      description = ''
        Keepalive interval in seconds, for peers behind NAT. Upstream defaults
        to 15.
      '';
    };

    configFilePath = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.dataDir}/wg0.conf";
      defaultText = "${cfg.dataDir}/wg0.conf";
      description = ''
        Where the generated wg0.conf is written. Defaults onto the data volume
        rather than upstream's /etc/wireguard/wg0.conf, so it lives with the
        rest of the state. It is rewritten from the database on every start, so
        it is a convenience for debugging rather than a source of truth.
      '';
    };

    username = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      description = "Web UI login name.";
    };

    passwordFile = lib.mkOption {
      type = lib.types.path;
      example = "/run/secrets/wireguard-ui-password";
      description = ''
        File holding the web UI password. Use a file rather than `password` so
        the value comes from the host's sops secrets at deploy time and never
        enters the Nix store.

        Note this is read on first start only: the login user is created in the
        database then, and changing the file afterwards does not rotate it.
        Rotate through the UI, or delete the user record on the data volume.
      '';
    };

    sessionSecretFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        File holding the session cookie key. Strongly recommended, and not
        optional in practice: the compiled-in default is a constant in the
        upstream source, so leaving it unset leaves the admin UI's session
        cookies forgeable by anyone who has read the source.
      '';
    };

    logLevel = lib.mkOption {
      type = lib.types.str;
      default = "info";
      description = "Log level passed as WGUI_LOG_LEVEL.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Extra command line flags. Provided for the flags that have no
        configuration option here (SMTP, Telegram, -subnet-ranges); upstream
        exposes those as flags only.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.wireguard-ui = {
      description = "wireguard-ui web interface for WireGuard";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      # The database path is ./db relative to the working directory, so this is
      # what puts the client keys on the data volume rather than the root disk.
      #
      # Inside serviceConfig, not a sibling of it: `workingDirectory` is not a
      # systemd.services option in NixOS, and setting it there gives
      # "The option `systemd.services.wireguard-ui.workingDirectory' does not
      # exist".
      environment = {
        WGUI_USERNAME = cfg.username;
        WGUI_PASSWORD_FILE = cfg.passwordFile;
        WGUI_SERVER_INTERFACE_ADDRESSES = lib.concatStringsSep "," cfg.serverInterfaceAddresses;
        WGUI_SERVER_LISTEN_PORT = toString cfg.listenPort;
        WGUI_ENDPOINT_ADDRESS = cfg.endpointAddress;
        WGUI_DNS = lib.concatStringsSep "," cfg.dnsServers;
        WGUI_MTU = toString cfg.mtu;
        WGUI_PERSISTENT_KEEPALIVE = toString cfg.persistentKeepalive;
        WGUI_CONFIG_FILE_PATH = cfg.configFilePath;
        WGUI_LOG_LEVEL = cfg.logLevel;

        # Upstream defaults the firewall mark to 0xca6c and the routing table to
        # "auto", but this build contains no iptables/nftables code at all --
        # both values are stored in the database and never read by anything. Set
        # them to empty anyway so a future version that does implement them
        # starts from a known state instead of silently SNATing clients.
        #
        # That last part is the one to watch: the Incus vhost gate in Caddy
        # matches remote_ip 100.64.0.0/10. A masquerade here would rewrite
        # client addresses to the tunnel interface's own and every VPN request
        # would be refused by that gate.
        WGUI_FIREWALL_MARK = "";
        WGUI_TABLE = "";
      };

      serviceConfig = {
        ExecStart = wrapper;
        WorkingDirectory = cfg.dataDir;

        # "simple", not "notify". There is no sd_notify in this binary and no
        # systemd dependency in its go.mod at all, so with Type=notify systemd
        # would wait for a READY=1 that is never sent, hold the start job open
        # for the full 90s default timeout, and then kill the service and mark
        # it failed -- every single start, with nothing in the log but a
        # timeout. Type=simple means "running as soon as execve succeeded",
        # which for an HTTP server is very nearly true.
        Type = "simple";
        Restart = "on-failure";
        RestartSec = "5s";

        # Do not start unless the data volume is actually mounted. Without this
        # a failed or absent mount leaves an empty directory on the root disk,
        # the service starts there, and every existing client is simply not
        # there any more.
        RequiresMountsFor = [ cfg.dataDir ];

        # Creates and configures the wg0 interface over netlink, so it needs
        # CAP_NET_ADMIN. It runs as root for that reason rather than by choice.
        AmbientCapabilities = [ "CAP_NET_ADMIN" ];
        CapabilityBoundingSet = [ "CAP_NET_ADMIN" "CAP_NET_RAW" ];

        # Modest hardening that does not fight the netlink work: ProtectSystem
        # is left alone because the service writes its config file, and the
        # kernel tunables/control groups are reachable only via the
        # capabilities above.
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectControlGroups = true;
      };

      restartIfChanged = true;
    };

    # The config file is created empty so its parent directory exists and the
    # service never has to create it. Nix keeps it as a symlink into the store,
    # which upstream overwrites in place -- fine, but it means this path should
    # be on the data volume, not in /etc.
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0700 root root -"
    ];
  };
}
