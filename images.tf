# OS images on the PVE host, shared by all VMs that use them.

# Debian cloud image used to bootstrap every NixOS install (any Linux with
# cloud-init + SSH works for nixos-anywhere).
resource "proxmox_download_file" "debian" {
  count = length(var.nixos_vms) > 0 ? 1 : 0

  node_name    = var.proxmox_node
  datastore_id = var.image_datastore
  content_type = "iso"
  # PVE only accepts .img/.iso names for "iso" content.
  file_name = replace(basename(var.debian_image_url), ".qcow2", ".img")
  url       = var.debian_image_url
  # Don't re-download (and thereby replace VMs) when Debian publishes a new build.
  overwrite = false
}

# Home Assistant OS images, one per distinct haos_version. They ship as
# .qcow2.xz, which Proxmox can't decompress, so they are downloaded and
# unpacked on the PVE host over SSH. Named .img for the "iso" content type;
# the disk import detects the qcow2 format from the file contents.
locals {
  pve_ssh_host  = regex("^https?://([^:/]+)", var.proxmox_endpoint)[0]
  haos_versions = toset([for vm in values(var.haos_vms) : vm.haos_version])
}

resource "terraform_data" "haos_image" {
  for_each         = local.haos_versions
  triggers_replace = [each.value, var.image_datastore]

  input = {
    ssh    = "${var.proxmox_ssh_user}@${local.pve_ssh_host}"
    volume = "${var.image_datastore}:iso/haos_ova-${each.value}.img"
    url    = "https://github.com/home-assistant/operating-system/releases/download/${each.value}/haos_ova-${each.value}.qcow2.xz"
  }

  provisioner "local-exec" {
    command = <<-EOT
      ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new ${self.input.ssh} '
        set -eu
        f=$(pvesm path ${self.input.volume})
        if [ ! -s "$f" ]; then
          echo "downloading ${self.input.url}"
          curl -fsSL "${self.input.url}" | xz -d > "$f.part"
          mv "$f.part" "$f"
        fi
        ls -l "$f"'
    EOT
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = "ssh -o BatchMode=yes ${self.input.ssh} 'rm -f \"$(pvesm path ${self.input.volume})\"'"
  }
}
