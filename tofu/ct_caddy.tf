resource "proxmox_virtual_environment_container" "caddy" {
  node_name    = "aetherium"
  vm_id        = 100
  description  = "Caddy reverse proxy (NixOS)"
  start_on_boot = true
  started      = true
  unprivileged  = true
  template     = false
  tags         = ["nixos", "caddy"]

  clone {
    vm_id        = var.template_ct_id
    datastore_id = "local"
  }

  initialization {
    hostname = "caddy"

    ip_config {
      ipv4 {
        address = "10.0.0.100/24"
        gateway = "10.0.0.1"
      }
      ipv6 {
        address = "fdbe::100/64"
        gateway = "fdbe::1"
      }
    }
  }

  cpu {
    cores = 1
  }

  memory {
    dedicated = 512
    swap      = 512
  }

  network_interface {
    name      = "eth0"
    bridge    = "aether"
    firewall  = true
    enabled   = true
  }

  startup {
    order = 1
  }

  lifecycle {
    prevent_destroy = false
    ignore_changes = [
      clone,
      unprivileged,
    ]
  }
}

resource "null_resource" "deploy_flake_caddy" {
  triggers = {
    container_id = proxmox_virtual_environment_container.caddy.id
  }
  depends_on = [proxmox_virtual_environment_container.caddy]

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for container to become reachable via SSH..."
      PROXY="ssh -p ${var.bastion_port} -i ${var.ssh_private_key_path} \
             ${var.bastion_user}@${var.bastion_host} -W %h:%p"
      i=0
      while [ $i -lt 30 ]; do
        i=$((i + 1))
        if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand="$PROXY" \
              -i ${var.ssh_private_key_path} \
              root@10.0.0.100 "echo ready" 2>/dev/null; then
          echo "Container reachable after $((i * 10)) seconds"
          break
        fi
        sleep 10
      done

      echo "Cloning repository..."
      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand="$PROXY" \
        -i ${var.ssh_private_key_path} \
        root@10.0.0.100 \
        "rm -rf /etc/nixos && nix --extra-experimental-features 'nix-command flakes' profile install nixpkgs#git && git clone https://forgejo.sakul-flee.de/sakulflee/HomeLab.git /etc/nixos && nixos-rebuild switch --flake /etc/nixos/nixos#caddy --show-trace"
    EOT
  }
}

resource "proxmox_virtual_environment_container" "website" {
  node_name     = "aetherium"
  vm_id         = 101
  description   = "Website (NixOS)"
  start_on_boot = true
  started       = true
  unprivileged  = true
  template      = false
  tags          = ["nixos", "website"]

  clone {
    vm_id        = var.template_ct_id
    datastore_id = "local"
  }

  initialization {
    hostname = "website"

    ip_config {
      ipv4 {
        address = "10.0.0.101/24"
        gateway = "10.0.0.1"
      }
      ipv6 {
        address = "fdbe::101/64"
        gateway = "fdbe::1"
      }
    }
  }

  cpu {
    cores = 1
  }

  memory {
    dedicated = 512
    swap      = 512
  }

  network_interface {
    name      = "eth0"
    bridge    = "aether"
    firewall  = true
    enabled   = true
  }

  startup {
    order = 2
  }

  lifecycle {
    prevent_destroy = false
    ignore_changes = [
      clone,
      unprivileged,
    ]
  }
}

resource "null_resource" "deploy_flake_website" {
  triggers = {
    container_id = proxmox_virtual_environment_container.website.id
  }
  depends_on = [proxmox_virtual_environment_container.website]

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for container to become reachable via SSH..."
      PROXY="ssh -p ${var.bastion_port} -i ${var.ssh_private_key_path} \
             ${var.bastion_user}@${var.bastion_host} -W %h:%p"
      i=0
      while [ $i -lt 30 ]; do
        i=$((i + 1))
        if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand="$PROXY" \
              -i ${var.ssh_private_key_path} \
              root@10.0.0.101 "echo ready" 2>/dev/null; then
          echo "Container reachable after $((i * 10)) seconds"
          break
        fi
        sleep 10
      done

      echo "Cloning repository..."
      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand="$PROXY" \
        -i ${var.ssh_private_key_path} \
        root@10.0.0.101 \
        "rm -rf /etc/nixos && nix --extra-experimental-features 'nix-command flakes' profile install nixpkgs#git && git clone https://forgejo.sakul-flee.de/sakulflee/HomeLab.git /etc/nixos && nixos-rebuild switch --flake /etc/nixos/nixos#website --show-trace"
    EOT
  }
}
