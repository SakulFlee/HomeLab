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
#   * there is no os/exec anywhere in the source, and the only wgctrl.New() is in
#     the read-only status page, so this binary cannot bring an interface up at
#     all. It writes wg0.conf and stops; applying that file is systemd's job.
#     Upstream ships a wgui.path + wgui.service pair for exactly that, and here
#     the same job is done by NixOS's own networking.wg-quick. See the tunnel
#     section of hosts/wireguard/default.nix.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.wireguard-ui;

  # The binary is exec'd directly instead of through a generated wrapper.
  #
  # A wrapper used to exist for one reason: -session-secret takes its value
  # inline on the command line, so it could not be passed by environment or
  # EnvironmentFile, and a generated script was the only way to keep it out of
  # the world-readable Nix store. With sessionSecretFile gone there is nothing
  # left to wrap.
  #
  # What remains is a bind address and extraArgs, both of which are not secret
  # and are equally visible either way. A wrapper would only add a store path
  # between systemd and the binary.
  wrapper = pkgs.writeShellScript "wireguard-ui-wrapper" ''
    set -eu
    exec ${lib.getExe cfg.package} \
      -bind-address ${cfg.bindAddress} \
      ${lib.escapeShellArgs cfg.extraArgs}
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

    # No passwordFile / password option. The admin account is created once, from
    # a default, and its hash is authoritative from then on; the password is
    # changed in the UI, which is what upstream documents. A Nix-side password
    # would not be read again after that first start, so it could not track the
    # change -- and nothing written here would ever be written back to sops.

    # No sessionSecretFile option. It is deliberately not offered: see the note
    # on renderedSecrets in hosts/wireguard/incus.nix for why the compiled-in
    # default is accepted for this instance. If that ever stops being true, the
    # option to add back is a -session-secret flag on the wrapper above, fed
    # from a rendered secret.

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

        # No WGUI_PASSWORD_FILE. Upstream documents it as "used for db
        # initialization only", so it seeds the admin hash on the first start
        # against an empty users table and is never read again. Changing the
        # password in the UI afterwards does not consult it, and there is no path
        # by which a password chosen in the UI is written back to sops. It would
        # be a secret that looks managed and is not.
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

        # No capabilities, and it does not run as root by choice.
        #
        # This service only writes a config file and serves HTTP. It never touches
        # netlink: there is no os/exec in the binary and the one wgctrl.New() is
        # in the read-only status page. An earlier version of this module granted
        # CAP_NET_ADMIN on the reasoning that the app configured wg0 itself -- it
        # does not, and the capability was doing nothing. The interface belongs to
        # networking.wg-quick, which runs `wg-quick up` in its own unit and brings
        # its own privileges.
        #
        # PrivateTmp does not conflict with the private staging of
        # /tmp/wg0.conf that networking.wg-quick does: those are different units
        # with separate namespaces, and the copy is made by wg-quick's own
        # ExecStart, not by this service.
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectControlGroups = true;
      };

      restartIfChanged = true;
    };

    # Re-apply the tunnel when the UI rewrites the config.
    #
    # This is upstream's `wgui.path`, and it is the only half of upstream's pair
    # that is needed here. Upstream's wgui.service exists solely to run
    # `systemctl restart wg-quick@wg0.service`; NixOS's networking.wg-quick
    # already provides that unit as wg-quick-wg0.service, so hand-writing the
    # service would only be a `systemctl restart` wrapper around something that
    # already exists.
    #
    # The unit name is wg-quick-<iface>, NOT wg-quick@<iface>. Copying upstream's
    # ExecStart verbatim would restart a unit that does not exist, and because it
    # is Type=oneshot that failure is quiet -- which is how the tunnel would end
    # up silently absent again.
    #
    # Why a path unit is needed at all: networking.wg-quick copies the config into
    # /tmp/wg0.conf in its ExecStart, at runtime, on every start. Nothing watches
    # the source file, so without this a save in the UI would rewrite wg0.conf and
    # change nothing until the next reboot.
    #
    # A restart, not a reload, so this is upstream's behaviour and its cost:
    # saving in the UI bounces wg0 and drops live connections for a moment. That
    # is the documented trade-off; a `wg setconf` apply would avoid it but is not
    # what upstream does.
    systemd.paths.wgui = {
      # PathChanged, not PathModified. Both are valid, but PathModified also
      # fires on a bare touch; either alone gives one trigger per change, and
      # setting both would restart wg-quick twice for a single save.
      #
      # PathChanged tolerates the file not existing yet, which matters because on
      # a fresh volume wireguard-ui writes wg0.conf after systemd has already
      # started the path unit. PathDoesNotExist would put the unit in a failed
      # state until something else restarted it.
      pathConfig.PathChanged = cfg.configFilePath;
      wantedBy = [ "multi-user.target" ];

      unitConfig = {
        Description = "Re-apply wg0 when wireguard-ui rewrites its config";
      };
    };

    # The action the path unit runs when the config changes.
    #
    # The name is deliberately `wgui.service`, because that is the name a
    # `.path` unit looks for: systemd's PathChanged= runs `<trigger-unit>.service`
    # for `<trigger-unit>.path`. Naming it anything else -- wgui-trigger, say --
    # produces "Refusing to start, unit wgui.service to trigger not loaded", and
    # since the path unit is Type=oneshot that failure is quiet.
    #
    # `wantedBy` on a .path generates RequiredBy, i.e. systemd pulls this in and
    # orders it before the path unit. Ordering it before the *path* unit is what
    # creates the cycle, though: paths.target wants every .path unit, and
    # wg-quick's unit needs network-online.target, which is after paths.target.
    # The first version of this had `before = [ "wgui.path" ]` and produced
    #   basic.target/start after paths.target/start after wgui.path/start after
    #   wgui-trigger.service/start - after basic.target
    # with systemd deleting a job to break it. No `before` here: the RequiredBy
    # dependency systemd creates is the right one, and ordering is left to it.
    #
    # try-restart, not restart: on the first change after a boot where wg-quick
    # is already up this is a no-op-safe re-apply, but if wg-quick is not running
    # (still waiting on network-online, say) try-restart declines rather than
    # starting a tunnel that is not wanted yet. autostart handles the boot case.
    systemd.services.wgui = {
      description = "Restart wg-quick when wireguard-ui rewrites wg0.conf";
      wantedBy = [ "wgui.path" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.systemd}/bin/systemctl try-restart wg-quick-wg0.service";
      };
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
