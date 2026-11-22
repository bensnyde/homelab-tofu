locals {
  flake_dir = abspath("${path.root}/nixos")
  ssh_keys  = [for f in var.ssh_public_key_files : trimspace(file(pathexpand(f)))]

  acme_enabled   = var.acme_email != ""
  backup_enabled = var.backup_b2_endpoint != ""
  backup_base    = "s3:https://${var.backup_b2_endpoint}/${var.backup_bucket}"
}

# ------------------------------------------------------------- NixOS VMs ---
module "nixos_vm" {
  source   = "./modules/nixos-vm"
  for_each = local.nixos_vms

  name        = each.key
  node        = var.proxmox_node
  vm_id       = each.value.vm_id
  cores       = each.value.cores
  memory_mb   = each.value.memory_mb
  disk_gb     = each.value.disk_gb
  guest_agent = each.value.guest_agent

  datastore          = var.vm_datastore
  bridge             = var.network_bridge
  vlan_id            = var.vlan_id
  bootstrap_image_id = proxmox_download_file.debian[0].id

  ipv4_cidr       = each.value.ipv4_cidr
  ipv4_gateway    = local.ipv4_gateway
  dns_servers     = each.value.dns_servers != null ? each.value.dns_servers : local.dns_servers
  ssh_public_keys = local.ssh_keys
  timezone        = var.timezone

  flake_dir = local.flake_dir

  # Read by nixos/modules/{acme,backup}.nix; extra per-VM values on top.
  settings = merge({
    domain      = each.value.domain
    acme_email  = local.acme_enabled && each.value.domain != "" ? var.acme_email : ""
    acme_dns    = var.acme_dns_provider
    backup_repo = local.backup_enabled ? "${local.backup_base}/${each.key}" : ""
  }, each.value.settings)

  # Files for /var/lib/secrets on the VM, built from .env values at install
  # time (never in state); scripts/push-secrets.sh updates them later.
  secrets = distinct(concat(
    local.acme_enabled && each.value.domain != "" ? ["acme-dns.env"] : [],
    local.backup_enabled ? ["restic.env", "restic-password"] : [],
    each.value.secrets,
  ))
}

# ------------------------------------------------ Home Assistant OS VMs ---
module "haos_vm" {
  source   = "./modules/haos-vm"
  for_each = local.haos_vms

  name        = each.key
  node        = var.proxmox_node
  vm_id       = each.value.vm_id
  cores       = each.value.cores
  memory_mb   = each.value.memory_mb
  disk_gb     = each.value.disk_gb
  mac_address = each.value.mac_address
  usb_devices = each.value.usb_devices

  ipv4_cidr    = each.value.ipv4_cidr
  ipv4_gateway = local.ipv4_gateway
  dns_servers  = each.value.dns_servers != null ? each.value.dns_servers : local.dns_servers
  pve_endpoint = local.proxmox_endpoint

  datastore = var.vm_datastore
  bridge    = var.network_bridge
  vlan_id   = var.vlan_id
  image_id  = terraform_data.haos_image[each.value.haos_version].input.volume
}
