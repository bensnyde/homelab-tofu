output "nixos_vms" {
  description = "NixOS VMs: ID, address, SSH and rebuild commands, URL."
  value = {
    for name, vm in module.nixos_vm : name => {
      vm_id   = vm.vm_id
      ip      = vm.ip_address
      ssh     = vm.ssh
      rebuild = vm.rebuild
      url     = var.nixos_vms[name].domain != "" ? "https://${var.nixos_vms[name].domain}" : null
    }
  }
}

output "haos_vms" {
  description = "Home Assistant OS VMs: ID and web UI (DHCP address from the guest agent)."
  value = {
    for name, vm in module.haos_vm : name => {
      vm_id = vm.vm_id
      ip    = vm.ip_address
      url   = vm.url
    }
  }
}

output "pve_backup" {
  description = "Proxmox backup job: schedule and included VM IDs."
  value = {
    schedule = proxmox_backup_job.nightly.schedule
    vmids    = proxmox_backup_job.nightly.vmid
  }
}

output "pve_certificate" {
  description = "Proxmox web UI certificate (Let's Encrypt), if pve_domain is set."
  value = local.pve_tls ? {
    url     = "https://${var.pve_domain}:8006/"
    issuer  = proxmox_acme_certificate.pve[0].issuer
    expires = proxmox_acme_certificate.pve[0].not_after
  } : null
}
