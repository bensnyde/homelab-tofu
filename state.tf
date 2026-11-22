# OpenTofu state: encrypted on this machine (AES-GCM, key derived from
# TF_VAR_state_passphrase via PBKDF2) before it is written anywhere.
# Without the passphrase the state can't be read: keep it in your password manager.
#
# Stored in Backblaze B2 (bucket TF_VAR_state_bucket in .env, which keeps every
# version, so each apply leaves a restorable history). Credentials: AWS_ACCESS_KEY_ID /
# AWS_SECRET_ACCESS_KEY in .env, a B2 key limited to that bucket - deliberately
# not the VM backup key, which lives on every VM.
terraform {
  backend "s3" {
    bucket = var.state_bucket
    key    = "homelab/terraform.tfstate"
    region = "us-east-005"
    endpoints = {
      s3 = "https://s3.us-east-005.backblazeb2.com"
    }
    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }

  encryption {
    key_provider "pbkdf2" "main" {
      passphrase = var.state_passphrase
    }
    method "aes_gcm" "main" {
      keys = key_provider.pbkdf2.main
    }

    state {
      method = method.aes_gcm.main
      # Refuse to read or write unencrypted state.
      enforced = true
    }
    plan {
      method = method.aes_gcm.main
    }
  }
}

variable "state_bucket" {
  description = "B2 bucket holding the state (TF_VAR_state_bucket in .env)."
  type        = string
}

variable "state_passphrase" {
  description = "Passphrase for state encryption (TF_VAR_state_passphrase in .env). At least 16 characters."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.state_passphrase) >= 16
    error_message = "state_passphrase must be at least 16 characters."
  }
}
