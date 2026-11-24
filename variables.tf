# ================================================================ Proxmox ===
variable "proxmox_endpoint" {
  description = "Proxmox VE API endpoint, e.g. https://192.0.2.10:8006/."
  type        = string
}

variable "proxmox_api_token" {
  description = "API token, format 'user@realm!tokenid=uuid'. Leave null to use PROXMOX_VE_API_TOKEN."
  type        = string
  default     = null
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification (the default PVE certificate is self-signed)."
  type        = bool
  default     = true
}

variable "proxmox_ssh_user" {
  description = "SSH user on the PVE node (disk import, image download). Key must be loaded in ssh-agent."
  type        = string
  default     = "root"
}

variable "proxmox_node" {
  description = "Name of the PVE node to create VMs on."
  type        = string
  default     = "pve"
}

variable "vm_datastore" {
  description = "Datastore for VM disks, EFI vars and cloud-init drives."
  type        = string
  default     = "local-lvm"
}

variable "image_datastore" {
  description = "Datastore (with 'ISO image' content enabled) for downloaded OS images."
  type        = string
  default     = "local"
}

variable "network_bridge" {
  type    = string
  default = "vmbr0"
}

variable "vlan_id" {
  description = "Optional VLAN tag for all VMs."
  type        = number
  default     = null
}

# ======================================================= Shared NixOS defaults ===
variable "ipv4_gateway" {
  description = "Default gateway for NixOS VMs, e.g. 192.0.2.1."
  type        = string
}

variable "dns_servers" {
  type    = list(string)
  default = ["1.1.1.1", "9.9.9.9"]
}

variable "ssh_public_key_files" {
  description = "Public keys allowed to log in as root on NixOS VMs. The matching private key must be in ssh-agent."
  type        = list(string)
  default     = ["~/.ssh/id_ed25519.pub"]
}

variable "timezone" {
  type    = string
  default = "UTC"
}

variable "debian_image_url" {
  description = "Bootstrap cloud image for NixOS installs. Only used to get SSH access; wiped by the install."
  type        = string
  default     = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
}

# ============================================== TLS: Let's Encrypt via DNS-01 ===
# Used by every NixOS VM that sets a `domain`. No inbound ports needed.
variable "acme_email" {
  description = "Let's Encrypt account email. Empty = no certificates."
  type        = string
  default     = ""
}

variable "acme_dns_provider" {
  description = "lego DNS provider for the DNS-01 challenge."
  type        = string
  default     = "cloudflare"
}

# The DNS token itself is CLOUDFLARE_DNS_API_TOKEN in .env (VMs get it via
# scripts/lib/secrets.sh); Proxmox gets it through this variable.
variable "cloudflare_dns_api_token" {
  description = "Cloudflare DNS token for the Proxmox certificate (TF_VAR_cloudflare_dns_api_token in .env). Sent write-only, never stored in state."
  type        = string
  default     = ""
  sensitive   = true
  ephemeral   = true
}

# =========================================== Backups: restic to Backblaze B2 ===
# Every NixOS VM backs up to <bucket>/<vm name> when this is configured. What
# gets backed up is defined per host via `homelab.backup` in its NixOS config.
variable "backup_b2_endpoint" {
  description = "S3 endpoint of the B2 bucket's region, shown on the bucket page, e.g. s3.us-west-004.backblazeb2.com. Empty = no off-site backups."
  type        = string
  default     = ""

  validation {
    condition     = var.backup_b2_endpoint == "" || can(regex("^s3\\.[a-z0-9-]+\\.backblazeb2\\.com$", var.backup_b2_endpoint))
    error_message = "backup_b2_endpoint must look like s3.us-west-004.backblazeb2.com (no https://, no bucket)."
  }
}

variable "backup_bucket" {
  description = "B2 bucket for restic repositories (one per VM, under <bucket>/<vm name>)."
  type        = string
  default     = "homelab-backup"
}

# Credentials (B2_BACKUP_KEY_ID, B2_BACKUP_TOKEN, B2_BACKUP_RESTIC_PASSWORD)
# come from .env; see scripts/lib/secrets.sh.

# ====================================================================== VMs ===
variable "nixos_vms" {
  description = <<-EOT
    NixOS VMs, keyed by name. Each name needs a NixOS config in
    nixos/hosts/<name>/default.nix.
  EOT
  type = map(object({
    ipv4_cidr   = string           # static address, e.g. 192.0.2.50/24
    vm_id       = optional(number) # null = next free
    cores       = optional(number, 2)
    memory_mb   = optional(number, 2048)
    disk_gb     = optional(number, 32)
    domain      = optional(string, "")       # FQDN; gets a Let's Encrypt cert if acme_email is set
    dns_servers = optional(list(string))     # overrides var.dns_servers (e.g. for a host running Pi-hole)
    guest_agent = optional(bool, false)      # set true after the first apply
    settings    = optional(map(string), {})  # extra values for the host's settings.json
    secrets     = optional(list(string), []) # extra files for /var/lib/secrets (names from scripts/lib/secrets.sh)
  }))
  default = {}

  validation {
    # {lan} is filled in from .env later (private.tf); check the shape with a stand-in.
    condition     = alltrue([for vm in values(var.nixos_vms) : can(cidrhost(replace(vm.ipv4_cidr, "{lan}", "10.0.0"), 0))])
    error_message = "ipv4_cidr must look like 192.0.2.50/24 or {lan}.50/24."
  }
}

variable "haos_vms" {
  description = "Home Assistant OS VMs (official appliance image, DHCP), keyed by name."
  type = map(object({
    haos_version = string # release with a haos_ova-<ver>.qcow2.xz asset
    vm_id        = optional(number)
    cores        = optional(number, 2)
    memory_mb    = optional(number, 4096)
    disk_gb      = optional(number, 32)
    mac_address  = optional(string)          # for a DHCP reservation
    ipv4_cidr    = optional(string)          # static IP set via the guest agent; null = DHCP
    dns_servers  = optional(list(string))    # overrides var.dns_servers
    ipv4_gateway = optional(string)          # overrides var.ipv4_gateway
    vlan_id      = optional(number)          # overrides var.vlan_id
    usb_devices  = optional(map(string), {}) # { label = "vendor:product" }
  }))
  default = {}

  validation {
    condition = alltrue(flatten([
      for vm in values(var.haos_vms) : [for id in values(vm.usb_devices) : can(regex("^[0-9a-f]{4}:[0-9a-f]{4}$", id))]
    ]))
    error_message = "USB device IDs must look like 10c4:8a2a (see `lsusb` on the PVE host)."
  }
}

# ======================================================= Proxmox VM backups ===
variable "pve_backup" {
  description = <<-EOT
    Nightly Proxmox backup job (vzdump). Includes every VM managed here plus
    extra_vmids (VMs not managed by tofu). Retention is per VM on the storage.
  EOT
  type = object({
    enabled       = optional(bool, true)
    schedule      = optional(string, "01:00") # systemd calendar format, PVE host time zone
    storage       = optional(string, "local")
    mode          = optional(string, "snapshot")
    compress      = optional(string, "zstd")
    prune_backups = optional(map(string), { "keep-daily" = "3", "keep-weekly" = "2" })
    extra_vmids   = optional(list(number), [])
  })
  default = {}
}

# ============================================== Proxmox web UI certificate ===
variable "pve_domain" {
  description = "FQDN for the Proxmox host (e.g. pve.example.com). Gets a Let's Encrypt certificate via the Cloudflare DNS-01 challenge (uses acme_email / cloudflare_dns_api_token). Empty = keep the self-signed cert."
  type        = string
  default     = ""
}

variable "pve_acme_tos" {
  description = "Let's Encrypt Terms of Service URL; setting it indicates agreement (see `pvesh get /cluster/acme/tos`)."
  type        = string
  default     = "https://letsencrypt.org/documents/LE-SA-v1.8-July-06-2026.pdf"
}
