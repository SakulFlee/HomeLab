resource "proxmox_virtual_environment_container" "caddy" {
  node_name    = "aetherium"
  vm_id        = 200
  description  = "Caddy reverse proxy (NixOS)"
  start_on_boot = true
  started      = true
  unprivileged  = true
  template     = false
  tags         = ["nixos", "caddy"]

  initialization {
    hostname = "caddy"

    ip_config {
      ipv4 {
        address = "10.0.0.200/24"
        gateway = "10.0.0.1"
      }
    }

    user_account {
      keys = [var.ssh_public_key]
    }
  }

  cpu {
    cores = 1
  }

  memory {
    dedicated = 512
    swap      = 0
  }

  network_interface {
    name      = "eth0"
    bridge    = "aether"
    firewall  = true
    enabled   = true
  }

  operating_system {
    template_file_id = var.lxc_template
  }

  startup {
    order = 1
  }

  lifecycle {
    ignore_changes = [
      operating_system[0].template_file_id,
    ]
  }
}

resource "null_resource" "nixos_infect" {
  depends_on = [proxmox_virtual_environment_container.caddy]

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = var.bastion_user
      host        = var.bastion_host
      port        = var.bastion_port
      private_key = file(var.ssh_private_key_path)
    }
    inline = [
      # Bring up networking
      "pct exec 200 -- ip link set eth0 up",
      "pct exec 200 -- ip addr add 10.0.0.200/24 dev eth0",
      "pct exec 200 -- ip route add default via 10.0.0.1",
      "pct exec 200 -- sh -c 'echo nameserver 1.1.1.1 > /etc/resolv.conf'",

      # Inject SSH key
      "pct exec 200 -- mkdir -p /root/.ssh",
      "pct exec 200 -- sh -c 'echo \"${var.ssh_public_key}\" >> /root/.ssh/authorized_keys'",
      "pct exec 200 -- chmod 600 /root/.ssh/authorized_keys",
      "pct exec 200 -- systemctl start ssh 2>/dev/null || true",

      # Create minimal NixOS bootstrap config via temp file on Proxmox host
      <<-EOCMD
        cat > /tmp/nixos-bootstrap.nix << 'CONFIGEOF'
        { config, pkgs, ... }: {
          boot.isContainer = true;
          networking = {
            hostName = "caddy";
            useDHCP = false;
            interfaces.eth0.ipv4.addresses = [{
              address = "10.0.0.200";
              prefixLength = 24;
            }];
            defaultGateway = "10.0.0.1";
            nameservers = [ "1.1.1.1" ];
          };
          system.stateVersion = "26.05";
          services.openssh.enable = true;
          users.users.root.openssh.authorizedKeys.keys = ["__SSHKEY__"];
        }
        CONFIGEOF
      EOCMD
      ,
      "sed -i 's|__SSHKEY__|${var.ssh_public_key}|g' /tmp/nixos-bootstrap.nix",
      "pct push 200 /tmp/nixos-bootstrap.nix /etc/nixos/configuration.nix",

      # Download and run nixos-infect
      "pct exec 200 -- curl -fsSL https://raw.githubusercontent.com/nix-community/nixos-infect/master/nixos-infect -o /tmp/nixos-infect",
      "pct exec 200 -- bash /tmp/nixos-infect 2>&1 || true",
    ]
  }
}

resource "null_resource" "deploy_flake" {
  depends_on = [null_resource.nixos_infect]

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for container to reboot after nixos-infect..."
      PROXY="ssh -p ${var.bastion_port} -i ${var.ssh_private_key_path} \
             ${var.bastion_user}@${var.bastion_host} -W %h:%p"
      i=0
      while [ $i -lt 30 ]; do
        i=$((i + 1))
        if ssh -o StrictHostKeyChecking=no -o ProxyCommand="$PROXY" \
              -i ${var.ssh_private_key_path} \
              root@10.0.0.200 "echo ready" 2>/dev/null; then
          echo "Container reachable after $((i * 10)) seconds"
          break
        fi
        sleep 10
      done

      echo "Deploying NixOS flake..."
      tar czf - -C ${path.module}/../nixos . | \
        ssh -o StrictHostKeyChecking=no -o ProxyCommand="$PROXY" \
          -i ${var.ssh_private_key_path} \
          root@10.0.0.200 \
          "tar xzf - -C /etc/nixos && nixos-rebuild switch --flake /etc/nixos#caddy --show-trace"
    EOT
  }
}
