# Translate the Incus-level instance specs into OpenTofu resource
# definitions. The result is serialised with builtins.toJSON and written to
# incus/infra/generated.tf.json by incus/gen-tf.sh.
#
# This lives inside the flake root (nixos/) rather than beside apply.sh in
# incus/ because a flake cannot read paths above its own root, and `nix eval`
# is how the generator gets its inputs without a JSON parser in shell.
#
# Everything here is plain data. The one thing Nix cannot express is image
# identity: incus_image cannot be imported, so the image resources are created
# on the first apply and instances are replaced to point at them.
{ lib, instances, instanceProjects, projects, artifacts }:
let
  inherit (builtins)
    attrNames
    attrValues
    concatMap
    elem
    filter
    head
    listToAttrs
    mapAttrs
    removeAttrs
    ;

  # Terraform identifiers may contain hyphens, but normalising them keeps the
  # generated references unsurprising and avoids quoting concerns in .tf.json.
  tfn = name: lib.replaceStrings [ "-" "." ] [ "_" "_" ] name;

  instanceNames = attrNames instances;
  projectOf = name: instanceProjects.${name} or "";
  kindOf = name: if (instances.${name}.type or "container") == "vm" then "vm" else "container";

  # Only add `project` when the instance is not in Incus's default project.
  # Referencing the resource (rather than repeating the name) also orders the
  # project before the images, volumes and instances placed in it.
  withProject = name: attrs:
    let p = projectOf name; in
    if p == "" then attrs else attrs // { project = "\${incus_project.${tfn p}.name}"; };

  # ---------------------------------------------------------------------
  # Volumes
  # ---------------------------------------------------------------------
  allVolumes = concatMap
    (name: map (v: v // { instance = name; volume = v.name; }) (instances.${name}.volumes or [ ]))
    instanceNames;

  volumeNames = map (v: v.volume) allVolumes;

  stringify = v:
    if builtins.isBool v then (if v then "true" else "false") else toString v;

  # Nix reads `features.images = true;` as a nested attribute set, while Incus
  # wants the flat config key "features.images". Flatten recursively.
  flattenConfig = prefix: attrs:
    lib.concatMapAttrs
      (k: v:
        if builtins.isAttrs v
        then flattenConfig "${prefix}${k}." v
        else { "${prefix}${k}" = stringify v; })
      attrs;

  # A device's `type` is a separate argument in the provider schema, and a VM
  # gets raw block devices so `path` is not accepted at all. The source is
  # rewritten to the volume resource's name so Terraform creates/updates the
  # volume first -- including the replicated volumes another instance owns.
  deviceProperties = kind: dev:
    let
      raw =
        if kind == "vm" && (dev.type or "") == "disk"
        then removeAttrs dev [ "type" "path" ]
        else removeAttrs dev [ "type" ];
      withSource =
        if raw ? source && elem raw.source volumeNames
        then raw // { source = "\${incus_storage_volume.${tfn raw.source}.name}"; }
        else raw;
    in
    mapAttrs (_: stringify) withSource;

  deviceList = name:
    let
      spec = instances.${name};
      kind = kindOf name;
      declared = lib.mapAttrsToList
        (dname: dev: {
          name = dname;
          type = dev.type;
          properties = deviceProperties kind dev;
        })
        (spec.devices or { });
      root = lib.optional (spec ? rootDiskSize) {
        name = "root";
        type = "disk";
        properties = {
          pool = "persistent";
          path = "/";
          size = spec.rootDiskSize;
        };
      };
    in
    declared ++ root;

  volumeConfig = v:
    lib.optionalAttrs (v ? snapshots && v.snapshots ? schedule) {
      "snapshots.schedule" = v.snapshots.schedule;
    }
    // lib.optionalAttrs (v ? snapshots && v.snapshots ? expiry) {
      "snapshots.expiry" = v.snapshots.expiry;
    };

  volumeResources = listToAttrs (map
    (v:
      let
        kind = kindOf v.instance;
        contentType =
          if (v.type or (if kind == "vm" then "block" else "filesystem")) == "block"
          then "block"
          else "filesystem";
      in
      {
        name = tfn v.volume;
        value = withProject v.instance {
          name = v.volume;
          pool = v.pool;
          type = "custom";
          content_type = contentType;
          description = v.description or "";
          config = volumeConfig v;
        };
      })
    allVolumes);

  # ---------------------------------------------------------------------
  # Images
  # ---------------------------------------------------------------------
  imageResources = lib.mapAttrs'
    (name: _:
      lib.nameValuePair (tfn name) (withProject name {
        source_file = {
          data_path = "${artifacts.${name}}/${if kindOf name == "vm" then "rootfs.qcow2" else "rootfs.squashfs"}";
          metadata_path = "${artifacts.${name}}/metadata.tar.xz";
        };
        # The old image is still in use by the instance that is about to be
        # replaced. Creating the replacement first is what keeps Incus from
        # refusing the delete with "Image is in use by an instance".
        lifecycle = { create_before_destroy = true; };
      }))
    instances;

  # ---------------------------------------------------------------------
  # Instances
  # ---------------------------------------------------------------------
  instanceConfig = spec:
    lib.optionalAttrs (spec ? limits && spec.limits ? memory) {
      "limits.memory" = spec.limits.memory;
    }
    // lib.optionalAttrs (spec ? limits && spec.limits ? cpu) {
      "limits.cpu" = spec.limits.cpu;
    }
    # apply.sh sets this unconditionally for every instance, independent of the
    # spec's `autostart` (which only decides whether to start it now).
    // { "boot.autostart" = "true"; }
    // lib.optionalAttrs (spec ? description) {
      "user.description" = spec.description;
    };

  instanceResources = lib.mapAttrs'
    (name: spec:
      lib.nameValuePair (tfn name) (withProject name {
        name = name;
        type = if kindOf name == "vm" then "virtual-machine" else "container";
        image = "\${incus_image.${tfn name}.fingerprint}";
        running = spec.autostart or true;
        profiles = [ "default" ];
        config = instanceConfig spec;
        device = deviceList name;
      }))
    instances;

  # ---------------------------------------------------------------------
  # Network forwards
  #
  # Incus keys a forward by (network, listen address), so every instance's
  # ports on one address belong to ONE resource. `networkForwards` (plural,
  # fluxer's older shape) is folded in alongside `networkForward`.
  # ---------------------------------------------------------------------
  firstNic = spec:
    head (filter (d: (d.type or "") == "nic" && d ? network) (attrValues (spec.devices or { })));

  forwardPorts = name:
    let
      spec = instances.${name};
      network = (firstNic spec).network;
      single =
        if spec ? networkForward then
          map
            (p: {
              inherit network;
              listenAddress = spec.networkForward.listenAddress;
              protocol = p.protocol;
              listenPort = p.listenPort;
              targetPort = p.targetPort or p.listenPort;
              targetAddress = p.targetAddress or spec.networkForward.targetAddress;
            })
            spec.networkForward.ports
        else
          [ ];
      multi = map
        (f: {
          inherit network;
          listenAddress = f.listenAddress;
          protocol = f.protocol;
          listenPort = f.listenPort;
          targetPort = f.targetPort or f.listenPort;
          targetAddress = f.targetAddress;
        })
        (spec.networkForwards or [ ]);
    in
    single ++ multi;

  allForwardPorts = concatMap forwardPorts instanceNames;

  forwardResources = lib.mapAttrs'
    (key: ports:
      let
        first = head ports;
        resourceName = "${tfn first.network}_${tfn first.listenAddress}";
      in
      lib.nameValuePair resourceName {
        network = first.network;
        listen_address = first.listenAddress;
        ports = map
          (p: {
            description = "";
            protocol = p.protocol;
            # The provider models ports as strings.
            listen_port = toString p.listenPort;
            target_port = toString p.targetPort;
            target_address = p.targetAddress;
          })
          ports;
      })
    (lib.groupBy (p: "${p.network}/${p.listenAddress}") allForwardPorts);

  # ---------------------------------------------------------------------
  # Projects
  # ---------------------------------------------------------------------
  projectResources = lib.mapAttrs'
    (pname: p:
      lib.nameValuePair (tfn pname) {
        name = pname;
        description = p.description or "";
        force_destroy = false;
        config = flattenConfig "" (removeAttrs p [ "description" ]);
      })
    projects;
in
{
  resource = {
    incus_server = {
      this = {
        config = {
          "core.https_address" = "192.168.178.200:8443";
          "core.https_allowed_websocket_origin" = "https://incus.sakul-flee.de";
        };
      };
    };

    incus_storage_pool = {
      persistent = {
        name = "persistent";
        driver = "btrfs";
        config = {
          source = "/var/lib/incus/storage-pools/persistent";
        };
      };
    };

    incus_network = {
      incusbr0 = {
        name = "incusbr0";
        type = "bridge";
        config = {
          "ipv4.address" = "10.0.0.1/24";
          "ipv4.nat" = "true";
          "ipv6.address" = "none";
        };
      };
    };

    # The nixpkgs incus module has no `projects` option and preseed cannot
    # manage the default profile's devices, so both are owned here. Creating
    # the "default" profile through the provider adopts and updates it.
    incus_profile = {
      default = {
        name = "default";
        device = [
          {
            name = "root";
            type = "disk";
            properties = {
              path = "/";
              pool = "persistent";
            };
          }
          {
            name = "eth0";
            type = "nic";
            properties = {
              name = "eth0";
              network = "incusbr0";
            };
          }
        ];
      };
    };

    incus_project = projectResources;
    incus_storage_volume = volumeResources;
    incus_image = imageResources;
    incus_instance = instanceResources;
    incus_network_forward = forwardResources;
  };
}
