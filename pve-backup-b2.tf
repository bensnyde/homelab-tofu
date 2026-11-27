# Off-site copies of the VM images: every night the PVE host backs up each VM
# in the backup job (local.pve_backup_vmids) with vzdump and streams it,
# encrypted, to B2 <bucket>/proxmox/vm-<id>/. Each file is a full backup that
# restores on its own; nothing is written to the host's disk. Same B2 key as
# the VMs' app backups; encrypted with B2_BACKUP_RESTIC_PASSWORD.
#
# The job itself is pve/backup-b2.sh; pve/install-backup-b2.sh puts it on the
# host over SSH (like images.tf), with the secrets from .env, not tofu state.
locals {
  pve_offsite = local.backup_enabled && var.pve_backup.offsite.enabled
  pve_offsite_settings = {
    SSH_TARGET  = "${var.proxmox_ssh_user}@${local.pve_ssh_host}"
    BUCKET      = var.backup_bucket
    VMIDS       = join(" ", local.pve_backup_vmids)
    SCHEDULE    = var.pve_backup.offsite.schedule
    KEEP_DAILY  = tostring(var.pve_backup.offsite.keep_daily)
    KEEP_WEEKLY = tostring(var.pve_backup.offsite.keep_weekly)
  }
}

resource "terraform_data" "pve_backup_b2" {
  count = local.pve_offsite ? 1 : 0

  input = { ssh = local.pve_offsite_settings.SSH_TARGET }
  triggers_replace = [
    local.pve_offsite_settings,
    filesha256("${path.module}/pve/backup-b2.sh"),
    filesha256("${path.module}/pve/install-backup-b2.sh"),
    var.pve_backup.offsite.secrets_version,
  ]

  provisioner "local-exec" {
    command     = "${path.module}/pve/install-backup-b2.sh"
    environment = local.pve_offsite_settings
  }

  # Stops the job; the backups in B2 are kept.
  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      ssh -o BatchMode=yes ${self.input.ssh} '
        systemctl disable --now pve-backup-b2.timer 2>/dev/null || true
        rm -f /etc/systemd/system/pve-backup-b2.service /etc/systemd/system/pve-backup-b2.timer \
          /usr/local/sbin/pve-backup-b2
        rm -rf /etc/pve-backup-b2
        systemctl daemon-reload'
    EOT
  }
}
