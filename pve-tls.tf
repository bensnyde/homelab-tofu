# Let's Encrypt certificate for the Proxmox web UI/API (port 8006), using
# Proxmox's built-in ACME client with the Cloudflare DNS-01 plugin: no ports
# are exposed, and Proxmox renews the certificate itself (pve-daily-update).
#
# Once issued, point the provider at the name and turn TLS verification on:
#   proxmox_endpoint = "https://<pve_domain>:8006/"
#   proxmox_insecure = false

locals {
  pve_tls = local.pve_domain != "" && var.acme_email != ""
}

# Proxmox only lets root@pam itself (not API tokens, even root's) register ACME
# accounts, so this one step runs `pvesh` over SSH as root, the same SSH access
# the provider uses for disk imports. Idempotent: skipped if the account exists.
resource "terraform_data" "pve_acme_account" {
  count = local.pve_tls ? 1 : 0

  input = {
    ssh  = "${var.proxmox_ssh_user}@${local.pve_ssh_host}"
    name = "homelab"
  }
  triggers_replace = [var.acme_email, var.pve_acme_tos]

  provisioner "local-exec" {
    command = <<-EOT
      ssh -o BatchMode=yes ${self.input.ssh} '
        if pvesh get /cluster/acme/account --output-format json | grep -q "\"${self.input.name}\""; then
          echo "ACME account ${self.input.name} already registered"
        else
          pvesh create /cluster/acme/account --name ${self.input.name} \
            --contact "${var.acme_email}" \
            --directory https://acme-v02.api.letsencrypt.org/directory \
            --tos_url "${var.pve_acme_tos}"
        fi'
    EOT
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = "ssh -o BatchMode=yes ${self.input.ssh} 'pvesh delete /cluster/acme/account/${self.input.name}'"
  }
}

resource "proxmox_acme_dns_plugin" "cloudflare" {
  count = local.pve_tls ? 1 : 0

  plugin = "cloudflare"
  api    = "cf"
  # Write-only: the token is sent to Proxmox but never stored in tofu state.
  # Bump data_wo_version after rotating CLOUDFLARE_DNS_API_TOKEN in .env.
  data_wo = {
    CF_Token = var.cloudflare_dns_api_token
  }
  data_wo_version = 1

  lifecycle {
    precondition {
      condition     = var.acme_dns_provider == "cloudflare"
      error_message = "pve_domain currently supports the Cloudflare DNS plugin only."
    }
    precondition {
      condition     = var.cloudflare_dns_api_token != ""
      error_message = "pve_domain needs TF_VAR_cloudflare_dns_api_token (set it from CLOUDFLARE_DNS_API_TOKEN in .env)."
    }
  }
}

resource "proxmox_acme_certificate" "pve" {
  count = local.pve_tls ? 1 : 0

  node_name = var.proxmox_node
  account   = terraform_data.pve_acme_account[0].output.name
  domains = [{
    domain = local.pve_domain
    plugin = proxmox_acme_dns_plugin.cloudflare[0].plugin
  }]
}
