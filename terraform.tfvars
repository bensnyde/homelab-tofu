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
pve_domain        = "proxmox.{domain}" # Let's Encrypt cert for the Proxmox UI

# --- Backups (restic to Backblaze B2) ----------------------------------------
backup_b2_endpoint   = "s3.us-east-005.backblazeb2.com"
# backup_bucket: TF_VAR_backup_bucket in .env
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
    memory_mb   = 4096
    disk_gb     = 40
    domain      = "k3s.{domain}"
    guest_agent = true
    secrets     = ["cloudflared-token"] # Cloudflare Tunnel (apps/cloudflared.nix)
    dns_servers = ["1.1.1.1", "9.9.9.9"] # not Pi-hole itself, or it can't start
  }

  kasm = {
    ipv4_cidr = "{lan}.55/24"
    cores     = 4
    memory_mb = 16384
    disk_gb   = 100
    domain      = "kasm.{domain}"
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
    ipv4_cidr    = "{lan}.57/24"
    usb_devices = {
      zigbee-zwave = "10c4:8a2a" # Silicon Labs HubZ (Zigbee + Z-Wave)
      bluetooth    = "0b05:1bf6" # Realtek Bluetooth
    }
  }
}

# --- Proxmox VM backups ------------------------------------------------------
pve_backup = {
  # Old hand-made HA VM 100 is stopped (fallback after the move to VM 101);
  # its last backup stays on `local`. Re-add [100] here only if needed.
  extra_vmids = []
}
