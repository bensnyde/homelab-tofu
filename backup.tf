# Nightly Proxmox backup of all VMs (full images, for fast rollback). Off-site,
# app-level backups are separate: restic to Backblaze B2, see nixos/modules/backup.nix.
resource "proxmox_backup_job" "nightly" {
  id       = "homelab-nightly"
  enabled  = var.pve_backup.enabled
  schedule = var.pve_backup.schedule
  storage  = var.pve_backup.storage
  mode     = var.pve_backup.mode
  compress = var.pve_backup.compress
  comment  = "Nightly backup of all homelab VMs (managed by OpenTofu)"

  vmid = [for id in sort(distinct(concat(
    [for vm in module.nixos_vm : tostring(vm.vm_id)],
    [for vm in module.haos_vm : tostring(vm.vm_id)],
    [for id in var.pve_backup.extra_vmids : tostring(id)],
  ))) : id]

  prune_backups  = var.pve_backup.prune_backups
  notes_template = "{{guestname}} {{node}}"
}
