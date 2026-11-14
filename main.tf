locals {
  flake_dir = abspath("${path.root}/nixos")
  ssh_keys  = [for f in var.ssh_public_key_files : trimspace(file(pathexpand(f)))]

  acme_enabled   = var.acme_email != ""
  backup_enabled = var.backup_r2_account_id != ""
  backup_base    = "s3:https://${var.backup_r2_account_id}.r2.cloudflarestorage.com/${var.backup_r2_bucket}"
}

# ------------------------------------------------------------- NixOS VMs ---
module "nixos_vm" {
  source   = "./modules/nixos-vm"
  for_each = var.nixos_vms

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
  ipv4_gateway    = var.ipv4_gateway
  dns_servers     = each.value.dns_servers != null ? each.value.dns_servers : var.dns_servers
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

  # Copied to /var/lib/secrets on the VM at install time (never in state).
  secrets = merge(
    local.acme_enabled && each.value.domain != "" ? {
      "/var/lib/secrets/acme-dns.env" = var.acme_dns_env_file
    } : {},
    local.backup_enabled ? {
      "/var/lib/secrets/restic.env"      = var.backup_env_file
      "/var/lib/secrets/restic-password" = var.backup_password_file
    } : {},
  )
}

# ------------------------------------------------ Home Assistant OS VMs ---
module "haos_vm" {
  source   = "./modules/haos-vm"
  for_each = var.haos_vms

  name        = each.key
  node        = var.proxmox_node
  vm_id       = each.value.vm_id
  cores       = each.value.cores
  memory_mb   = each.value.memory_mb
  disk_gb     = each.value.disk_gb
  mac_address = each.value.mac_address
  usb_devices = each.value.usb_devices

  ipv4_cidr    = each.value.ipv4_cidr
  ipv4_gateway = var.ipv4_gateway
  dns_servers  = each.value.dns_servers != null ? each.value.dns_servers : var.dns_servers
  pve_endpoint = var.proxmox_endpoint

  datastore = var.vm_datastore
  bridge    = var.network_bridge
  vlan_id   = var.vlan_id
  image_id  = terraform_data.haos_image[each.value.haos_version].input.volume
}
