#!/bin/bash
# Off-site VM backups to B2, run nightly on the PVE host by pve-backup-b2.timer.
#
# Every VM is backed up with vzdump (snapshot mode, zstd) and streamed,
# encrypted with gpg, straight to B2: nothing is written to the host's disk.
# Each file is a complete backup that restores on its own (no increments):
#
#   <bucket>/proxmox/vm-<id>/daily/vzdump-qemu-<id>-<date>.vma.zst.gpg    last KEEP_DAILY
#   <bucket>/proxmox/vm-<id>/weekly/vzdump-qemu-<id>-<date>.vma.zst.gpg   last KEEP_WEEKLY (Sundays)
#
# The passphrase is B2_BACKUP_RESTIC_PASSWORD from .env (keep it safe: without
# it the backups can't be decrypted).
#
#   pve-backup-b2 [run [vmid...]]       back up all (or the given) VMs now; the timer runs this
#   pve-backup-b2 list                  list the backups in B2
#   pve-backup-b2 restore <file> <vmid> [qmrestore options]
#                                       restore one into a VM ID that isn't in use;
#                                       add --unique 1 for a test copy next to the
#                                       original (new MAC addresses)
#
# Installed by tofu (pve-backup-b2.tf, pve/install-backup-b2.sh) as
# /usr/local/sbin/pve-backup-b2. Settings: /etc/pve-backup-b2/config.
set -uo pipefail

# shellcheck source=/dev/null
source /etc/pve-backup-b2/config # BUCKET, VMIDS, KEEP_DAILY, KEEP_WEEKLY
set -a
# shellcheck source=/dev/null
source /etc/pve-backup-b2/b2.env # RCLONE_CONFIG_B2_ACCOUNT, RCLONE_CONFIG_B2_KEY
set +a
export RCLONE_CONFIG=/etc/pve-backup-b2/rclone.conf # empty: the remote comes from the variables here
export RCLONE_CONFIG_B2_TYPE=b2
export RCLONE_CONFIG_B2_HARD_DELETE=true # pruned files are really deleted, not kept as old versions
passphrase=/etc/pve-backup-b2/passphrase
dest="b2:$BUCKET/proxmox"

# Delete all but the newest $2 files in folder $1 (names sort by date).
prune() {
  local dir=$1 keep=$2 old
  ((keep >= 1)) || keep=1
  rclone lsf --files-only "$dest/$dir" 2>/dev/null | grep '\.vma\.zst\.gpg$' | sort | head -n -"$keep" |
    while read -r old; do
      echo "deleting $dir/$old"
      rclone deletefile "$dest/$dir/$old"
    done
}

backup_all() {
  local stamp failed=() id name file tmp
  stamp=$(date +%Y_%m_%d-%H_%M_%S)
  # shellcheck disable=SC2086
  for id in ${*:-$VMIDS}; do
    name=$(qm config "$id" 2>/dev/null | sed -n 's/^name: //p')
    file="vzdump-qemu-$id-$stamp.vma.zst.gpg"
    tmp="vm-$id/.partial-$file"
    echo "=== VM $id (${name:-?}) -> vm-$id/daily/$file"
    # Uploaded under a temporary name; renamed only if every step succeeded,
    # so a failed run never replaces a good backup.
    if vzdump "$id" --mode snapshot --stdout 1 --compress zstd --lockwait 180 |
        gpg --batch --quiet --symmetric --cipher-algo AES256 --compress-algo none \
          --passphrase-file "$passphrase" --output - |
        rclone rcat "$dest/$tmp" &&
        rclone moveto "$dest/$tmp" "$dest/vm-$id/daily/$file"; then
      if [ "$(date +%u)" = 7 ]; then
        rclone copyto "$dest/vm-$id/daily/$file" "$dest/vm-$id/weekly/$file" || failed+=("$id-weekly")
      fi
      prune "vm-$id/daily" "$KEEP_DAILY"
      prune "vm-$id/weekly" "$KEEP_WEEKLY"
    else
      echo "VM $id FAILED, previous backups kept" >&2
      rclone deletefile "$dest/$tmp" 2>/dev/null
      failed+=("$id")
    fi
  done
  if ((${#failed[@]})); then
    echo "FAILED: ${failed[*]}" >&2
    return 1
  fi
  echo "all VMs backed up"
}

case "${1:-run}" in
  run) shift; backup_all "$@" ;;
  list) rclone lsl --include '/vm-*/daily/*.gpg' --include '/vm-*/weekly/*.gpg' "$dest" | sort -k4 ;;
  restore)
    file=${2:?usage: pve-backup-b2 restore <vm-ID/daily/file> <vmid> [qmrestore options]}
    vmid=${3:?usage: pve-backup-b2 restore <vm-ID/daily/file> <vmid> [qmrestore options]}
    if qm status "$vmid" >/dev/null 2>&1; then
      echo "VM $vmid exists - restore into a free ID (or remove it first)" >&2
      exit 1
    fi
    rclone cat "$dest/$file" |
      gpg --batch --quiet --decrypt --passphrase-file "$passphrase" |
      zstd -dc |
      qmrestore - "$vmid" "${@:4}"
    ;;
  *) echo "usage: pve-backup-b2 [run [vmid...] | list | restore <file> <vmid> [qmrestore options]]" >&2; exit 2 ;;
esac
