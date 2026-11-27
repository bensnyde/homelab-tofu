# Nightly Proxmox backup of all VMs to local storage (full images, for fast
# rollback; pve_backup.enabled = false turns it off, e.g. when only the B2
# copies are wanted). Off-site copies of the same images: pve-backup-b2.tf.
# App-level backups are separate: restic to B2, see nixos/modules/backup.nix.
locals {
  # Every VM managed here, plus extra_vmids. Shared with pve-backup-b2.tf.
  pve_backup_vmids = [for id in sort(distinct(concat(
    [for vm in module.nixos_vm : tostring(vm.vm_id)],
    [for vm in module.haos_vm : tostring(vm.vm_id)],
    [for id in var.pve_backup.extra_vmids : tostring(id)],
  ))) : id]
}

resource "proxmox_backup_job" "nightly" {
  id       = "homelab-nightly"
  enabled  = var.pve_backup.enabled
  schedule = var.pve_backup.schedule
  storage  = var.pve_backup.storage
  mode     = var.pve_backup.mode
  compress = var.pve_backup.compress
  comment  = "Nightly backup of all homelab VMs (managed by OpenTofu)"

  vmid = local.pve_backup_vmids

  prune_backups  = var.pve_backup.prune_backups
  notes_template = "{{guestname}} {{node}}"
}
