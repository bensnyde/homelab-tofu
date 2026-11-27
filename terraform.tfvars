# Committed to git: private values are placeholders filled in from .env
# (see private.tf): {domain} = TF_VAR_base_domain, {lan} = TF_VAR_lan_prefix.
# Secrets and other private values (acme_email, bucket names) are TF_VAR_* in .env.
# Load it first: set -a; source .env; set +a

# --- Proxmox -----------------------------------------------------------------
proxmox_endpoint = "https://{lan}.168:8006/"
proxmox_node     = "proxmox"
vm_datastore     = "local-lvm"
image_datastore  = "local"
network_bridge   = "vmbr0"

# --- Shared NixOS defaults ---------------------------------------------------
ipv4_gateway         = "{lan}.1"
dns_servers          = ["{lan}.1"]
ssh_public_key_files = ["~/.ssh/id_ed25519.pub"]
timezone             = "UTC"

# --- TLS (Let's Encrypt via Cloudflare DNS-01) -------------------------------
# acme_email: TF_VAR_acme_email in .env
pve_domain = "proxmox.{domain}" # Let's Encrypt cert for the Proxmox UI

# --- Backups (restic to Backblaze B2) ----------------------------------------
backup_b2_endpoint = "s3.us-east-005.backblazeb2.com"
# backup_bucket: B2_BACKUP_BUCKET in .env (passed as TF_VAR_backup_bucket)
# Credentials: B2_BACKUP_KEY_ID / B2_BACKUP_TOKEN / B2_BACKUP_RESTIC_PASSWORD in .env

# --- VMs ---------------------------------------------------------------------
nixos_vms = {
  authentik = {
    vm_id       = 102
    ipv4_cidr   = "{lan}.50/24"
    cores       = 2
    memory_mb   = 4096
    disk_gb     = 32
    domain      = "auth.{domain}"
    guest_agent = true
  }

  k3s = {
    ipv4_cidr   = "{lan}.59/24"
    cores       = 4
    memory_mb   = 8192
    disk_gb     = 40
    domain      = "k3s.{domain}"
    guest_agent = true
    dns_servers = ["1.1.1.1", "9.9.9.9"] # not Pi-hole itself, or it can't start
    secrets     = ["audiobooks-b2.env"]  # Audiobookshelf library mount (B2)
  }

  kasm = {
    ipv4_cidr   = "{lan}.55/24"
    cores       = 4
    memory_mb   = 12288
    disk_gb     = 100
    domain      = "kasm.{domain}"
    guest_agent = true
  }

  # Tailscale gateway to k3s and Kasm (nixos/hosts/gateway). No ports forwarded.
  gateway = {
    ipv4_cidr   = "{lan}.51/24"
    cores       = 1
    memory_mb   = 2048 # the install (kexec) needs >= 1.5 GiB
    disk_gb     = 16
    secrets     = ["tailscale-authkey"]
    guest_agent = true
  }
}

haos_vms = {
  homeassistant = {
    vm_id        = 101
    haos_version = "18.4" # initial install only; HAOS updates itself
    cores        = 4
    memory_mb    = 8192
    disk_gb      = 32
    mac_address  = "BC:24:11:57:00:01" # fixed, for a DHCP reservation
    # Stays on the IoT VLAN (tagged on the Proxmox port) with the devices it
    # controls; everything else is on the Servers network ({lan}).
    vlan_id      = 3
    ipv4_cidr    = "{iot}.57/24"
    ipv4_gateway = "{iot}.1"
    dns_servers  = ["{iot}.1"]
    usb_devices = {
      zigbee-zwave = "10c4:8a2a" # Silicon Labs HubZ (Zigbee + Z-Wave)
      bluetooth    = "0b05:1bf6" # Realtek Bluetooth
    }
  }
}

# --- Proxmox VM backups ------------------------------------------------------
pve_backup = {
  # No local VM backups: `local` is the host's 100 GB root disk, too small for
  # them (Kasm and k3s are ~22-26 GB each). The VMs are backed up to B2 only
  # (offsite, pve-backup-b2.tf): 2 daily + 2 weekly full images per VM.
  enabled     = false
  extra_vmids = []
}
