#!/usr/bin/env bash
# Called by OpenTofu (modules/nixos-vm, terraform_data.install). Waits for the
# freshly cloned Debian VM to accept SSH, then runs nixos-anywhere against it.
#
# Env: TARGET_HOST, TARGET_USER, FLAKE, SECRETS (space-separated names of files
# for /var/lib/secrets, built from .env values; see scripts/lib/secrets.sh).
set -euo pipefail

: "${TARGET_HOST:?}" "${TARGET_USER:?}" "${FLAKE:?}"

# shellcheck source=../../scripts/lib/secrets.sh
source "$(dirname "$0")/../../scripts/lib/secrets.sh"
read -r -a secret_names <<< "${SECRETS:-}"
# Fail before waiting on the VM if a value is missing from the environment.
check_secret_env "${secret_names[@]}"

ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR)

echo ">> waiting for SSH on ${TARGET_USER}@${TARGET_HOST}"
for i in $(seq 1 90); do
  if ssh "${ssh_opts[@]}" "${TARGET_USER}@${TARGET_HOST}" \
       'sudo cloud-init status --wait >/dev/null 2>&1 || true'; then
    break
  fi
  if [[ $i -eq 90 ]]; then
    echo "!! SSH never came up on ${TARGET_HOST}" >&2
    exit 1
  fi
  sleep 5
done

# Ship secrets via --extra-files so they never hit the Nix store or tofu state.
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
extra_args=()
if (( ${#secret_names[@]} )); then
  render_secrets "$staging/var/lib/secrets" "${secret_names[@]}"
  extra_args+=(--extra-files "$staging" --chown /var/lib/secrets 0:0)
fi

echo ">> installing NixOS (${FLAKE}) on ${TARGET_HOST}"
nix --extra-experimental-features "nix-command flakes" \
  run github:nix-community/nixos-anywhere -- \
  --flake "${FLAKE}" \
  --target-host "${TARGET_USER}@${TARGET_HOST}" \
  --ssh-option StrictHostKeyChecking=no \
  --ssh-option UserKnownHostsFile=/dev/null \
  "${extra_args[@]}" \
  --option extra-substituters "https://nix-community.cachix.org" \
  --option extra-trusted-public-keys "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
