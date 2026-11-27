# Shared by modules/nixos-vm/install.sh and scripts/push-secrets.sh.
#
# Builds the files a VM gets in /var/lib/secrets/ from values in the
# environment (`set -a; source .env; set +a`), so .env is the only secrets
# file on the workstation. Nothing passes through tofu variables or state.
#
#   name               built from (.env)                            used by
#   acme-dns.env       CLOUDFLARE_DNS_API_TOKEN                     modules/acme.nix
#   restic.env         B2_BACKUP_KEY_ID, B2_BACKUP_TOKEN            modules/backup.nix
#   restic-password    B2_BACKUP_RESTIC_PASSWORD                    modules/backup.nix
#   tailscale-authkey  TAILSCALE_AUTHKEY                            hosts/gateway
#   audiobooks-b2.env  B2_AUDIOBOOKS_KEY_ID, B2_AUDIOBOOKS_TOKEN,   hosts/k3s/apps/audiobookshelf.nix
#                      B2_AUDIOBOOKS_BUCKET

# Env vars each secret needs (space-separated).
secret_vars() {
  case "$1" in
    acme-dns.env)      echo "CLOUDFLARE_DNS_API_TOKEN" ;;
    restic.env)        echo "B2_BACKUP_KEY_ID B2_BACKUP_TOKEN" ;;
    restic-password)   echo "B2_BACKUP_RESTIC_PASSWORD" ;;
    tailscale-authkey) echo "TAILSCALE_AUTHKEY" ;;
    audiobooks-b2.env) echo "B2_AUDIOBOOKS_KEY_ID B2_AUDIOBOOKS_TOKEN B2_AUDIOBOOKS_BUCKET" ;;
    *) echo "unknown secret '$1' (see scripts/lib/secrets.sh)" >&2; return 1 ;;
  esac
}

# Exit with a list of missing env vars, before anything touches a VM.
check_secret_env() {
  local name var missing=()
  for name in "$@"; do
    for var in $(secret_vars "$name") ; do
      [[ -n "${!var:-}" ]] || missing+=("$var (for $name)")
    done
  done
  if (( ${#missing[@]} )); then
    printf '!! missing in the environment - did you `set -a; source .env; set +a`?\n' >&2
    printf '   %s\n' "${missing[@]}" >&2
    return 1
  fi
}

# Print one secret file's contents (no trailing newline for single values).
render_secret() {
  case "$1" in
    acme-dns.env)
      printf 'CLOUDFLARE_DNS_API_TOKEN=%s\n' "$CLOUDFLARE_DNS_API_TOKEN" ;;
    restic.env)
      # restic's S3 backend reads the B2 key under the AWS names.
      printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\n' "$B2_BACKUP_KEY_ID" "$B2_BACKUP_TOKEN" ;;
    restic-password)
      printf '%s' "$B2_BACKUP_RESTIC_PASSWORD" ;;
    tailscale-authkey)
      printf '%s' "$TAILSCALE_AUTHKEY" ;;
    audiobooks-b2.env)
      # rclone remote "b2" (native B2 API) + the bucket, for the library mount.
      printf 'RCLONE_CONFIG_B2_TYPE=b2\nRCLONE_CONFIG_B2_ACCOUNT=%s\nRCLONE_CONFIG_B2_KEY=%s\nRCLONE_CONFIG_B2_HARD_DELETE=true\nAUDIOBOOKS_BUCKET=%s\n' \
        "$B2_AUDIOBOOKS_KEY_ID" "$B2_AUDIOBOOKS_TOKEN" "$B2_AUDIOBOOKS_BUCKET" ;;
    *) secret_vars "$1" ;;
  esac
}

# render_secrets <dir> <name>... : write <dir>/<name> (0600) for each name.
render_secrets() {
  local dir=$1 name; shift
  check_secret_env "$@"
  install -d -m 0700 "$dir"
  for name in "$@"; do
    ( umask 077; render_secret "$name" > "$dir/$name" )
  done
}
