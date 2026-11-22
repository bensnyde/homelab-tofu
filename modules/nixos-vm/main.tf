# A NixOS VM on Proxmox:
#   1. clone a Debian cloud image with cloud-init (static IP + SSH key),
#   2. write hosts/<name>/settings.json for the NixOS flake,
#   3. replace Debian with nixosConfigurations.<name> via nixos-anywhere.

locals {
  ip_address = split("/", var.ipv4_cidr)[0]
  host_dir   = "${var.flake_dir}/hosts/${var.name}"
  # `path:` makes Nix read the directory as-is instead of only git-tracked
  # files, so the gitignored settings.json is visible to the flake.
  flake_ref = "path:${var.flake_dir}#${var.name}"
}

resource "proxmox_virtual_environment_vm" "this" {
  name        = var.name
  node_name   = var.node
  vm_id       = var.vm_id
  description = "NixOS host ${var.name}, managed by OpenTofu"
  tags        = ["nixos", var.name, "opentofu"]

  on_boot         = true
  stop_on_destroy = true

  # The Debian bootstrap image has no guest agent; with this enabled the
  # provider would block waiting for it. NixOS runs qemu-guest-agent, so set
  # guest_agent = true after the install (enables fs-freeze during backups).
  agent {
    enabled = var.guest_agent
  }

  operating_system {
    type = "l26"
  }

  cpu {
    cores = var.cores
    type  = "host"
  }

  memory {
    dedicated = var.memory_mb
  }

  scsi_hardware = "virtio-scsi-single"

  # Shows up as /dev/sda inside the guest (see nixos/modules/disk-config.nix).
  disk {
    datastore_id = var.datastore
    file_id      = var.bootstrap_image_id
    interface    = "scsi0"
    size         = var.disk_gb
    discard      = "on"
    iothread     = true
    ssd          = true
  }

  network_device {
    bridge  = var.bridge
    model   = "virtio"
    vlan_id = var.vlan_id
  }

  serial_device {}

  initialization {
    datastore_id = var.datastore

    ip_config {
      ipv4 {
        address = var.ipv4_cidr
        gateway = var.ipv4_gateway
      }
    }

    dns {
      servers = var.dns_servers
    }

    user_account {
      username = "debian"
      keys     = var.ssh_public_keys
    }
  }

  lifecycle {
    # After NixOS is installed, cloud-init and the bootstrap image are irrelevant.
    ignore_changes = [initialization, disk[0].file_id]
  }
}

# Values the NixOS flake reads at evaluation time (gitignored).
resource "local_file" "settings" {
  filename        = "${local.host_dir}/settings.json"
  file_permission = "0644"
  content = jsonencode(merge({
    hostname        = var.name
    ipv4_address    = local.ip_address
    ipv4_prefix     = tonumber(split("/", var.ipv4_cidr)[1])
    ipv4_gateway    = var.ipv4_gateway
    dns_servers     = var.dns_servers
    ssh_public_keys = var.ssh_public_keys
    timezone        = var.timezone
    # Read by scripts/push-secrets.sh, not by Nix.
    secrets = var.secrets
  }, var.settings))

  lifecycle {
    precondition {
      condition     = can(cidrhost(var.ipv4_cidr, 0)) && !strcontains(jsonencode(var.settings), "{domain}")
      error_message = "${var.name}: unresolved {lan}/{domain} placeholder (ipv4_cidr = ${var.ipv4_cidr}) - is .env loaded with TF_VAR_lan_prefix and TF_VAR_base_domain?"
    }
    precondition {
      condition     = fileexists("${local.host_dir}/default.nix")
      error_message = "No NixOS config for this VM: create nixos/hosts/${var.name}/default.nix."
    }
  }
}

# Replace Debian with NixOS. Runs once per VM and WIPES the disk, so it is
# intentionally not re-triggered by config changes; use scripts/rebuild.sh.
resource "terraform_data" "install" {
  triggers_replace = [proxmox_virtual_environment_vm.this.id]

  depends_on = [local_file.settings]

  provisioner "local-exec" {
    command = "${path.module}/install.sh"
    environment = {
      TARGET_HOST = local.ip_address
      TARGET_USER = "debian"
      FLAKE       = local.flake_ref
      # File names; the values come from .env in tofu's own environment.
      SECRETS = join(" ", var.secrets)
    }
  }
}
