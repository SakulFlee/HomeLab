resource "proxmox_virtual_environment_container" "bitmagnet" {
  node_name     = "aetherium"
  vm_id         = 114
  description   = "BitMagnet DHT crawler & torrent indexer (NixOS)"
  start_on_boot = true
  started       = true
  unprivileged  = true
  template      = false
  tags          = ["nixos", "bitmagnet"]

  clone {
    vm_id        = var.template_ct_id
    datastore_id = "local"
  }

  disk {
    datastore_id = "local"
    size         = 16
  }

  initialization {
    hostname = "bitmagnet"

    ip_config {
      ipv4 {
        address = "10.0.0.114/24"
        gateway = "10.0.0.1"
      }
      ipv6 {
        address = "fdbe::114/64"
        gateway = "fdbe::1"
      }
    }
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 2048
    swap      = 1024
  }

  network_interface {
    name      = "eth0"
    bridge    = "aether"
    firewall  = true
    enabled   = true
  }

  features {
    nesting = true
  }

  lifecycle {
    prevent_destroy = false
    ignore_changes = [
      clone,
      tags,
      unprivileged,
      mount_point,
      device_passthrough,
    ]
  }
}

resource "null_resource" "deploy_flake_bitmagnet" {
  triggers = {
    container_id = proxmox_virtual_environment_container.bitmagnet.id
  }
  depends_on = [proxmox_virtual_environment_container.bitmagnet]

  provisioner "local-exec" {
    command = <<-EOT
      echo "Setting TUN device passthrough..."
      ssh -p ${var.bastion_port} -i ${var.ssh_private_key_path} \
        ${var.bastion_user}@${var.bastion_host} \
        "CONFIG=/etc/pve/lxc/114.conf
         grep -q 'lxc.cgroup2.devices.allow: c 10:200 rwm' \"\$CONFIG\" ||
           echo 'lxc.cgroup2.devices.allow: c 10:200 rwm' >> \"\$CONFIG\"
         grep -q 'lxc.mount.entry: /dev/net/tun' \"\$CONFIG\" ||
           echo 'lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file' >> \"\$CONFIG\"
         pct reboot 114"

      echo "Waiting for container to become reachable via SSH (after TUN reboot)..."
      PROXY="ssh -p ${var.bastion_port} -i ${var.ssh_private_key_path} \
             ${var.bastion_user}@${var.bastion_host} -W %h:%p"
      i=0
      while [ $i -lt 30 ]; do
        i=$((i + 1))
        if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand="$PROXY" \
              -i ${var.ssh_private_key_path} \
              root@10.0.0.114 "echo ready" 2>/dev/null; then
          echo "Container reachable after $((i * 10)) seconds"
          break
        fi
        sleep 10
      done

      echo "Copying repository via tar/ssh..."
      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand="$PROXY" \
        -i ${var.ssh_private_key_path} \
        root@10.0.0.114 \
        "rm -rf /etc/nixos && mkdir -p /etc/nixos" && \
      tar cz --owner=0 --group=0 -C ${path.root}/.. . | \
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand="$PROXY" \
          -i ${var.ssh_private_key_path} \
          root@10.0.0.114 \
          "tar xz -C /etc/nixos && nix --extra-experimental-features 'nix-command flakes' profile install nixpkgs#git && nixos-rebuild switch --flake /etc/nixos/nixos#bitmagnet --show-trace && nix-collect-garbage --delete-old"
    EOT
  }
}
