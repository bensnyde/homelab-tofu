#!/usr/bin/env bash
# Installs the off-site VM backup on the PVE host (run by tofu, pve-backup-b2.tf).
#
#   /usr/local/sbin/pve-backup-b2     the nightly job (pve/backup-b2.sh)
#   /etc/pve-backup-b2/               config, b2.env and passphrase (root-only)
#   pve-backup-b2.service / .timer    systemd units
#
# The B2 key and the passphrase (B2_BACKUP_RESTIC_PASSWORD) come from this
# shell's environment (.env), the same ones the VMs use, and go to the host
# over SSH: never into tofu state.
#
# Needs: SSH_TARGET, BUCKET, VMIDS, SCHEDULE, KEEP_DAILY, KEEP_WEEKLY;
# B2_BACKUP_KEY_ID, B2_BACKUP_TOKEN and B2_BACKUP_RESTIC_PASSWORD
# (`set -a; source .env; set +a`).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
missing=()
for v in SSH_TARGET BUCKET VMIDS SCHEDULE KEEP_DAILY KEEP_WEEKLY \
  B2_BACKUP_KEY_ID B2_BACKUP_TOKEN B2_BACKUP_RESTIC_PASSWORD; do
  [[ -n "${!v:-}" ]] || missing+=("$v")
done
if ((${#missing[@]})); then
  echo "!! missing in the environment - did you \`set -a; source .env; set +a\`? ${missing[*]}" >&2
  exit 1
fi

staging=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/pve-backup-b2.XXXXXX")
trap 'rm -rf "$staging"' EXIT
umask 077
mkdir -p "$staging/etc/pve-backup-b2" "$staging/usr/local/sbin" "$staging/etc/systemd/system"

printf 'RCLONE_CONFIG_B2_ACCOUNT=%s\nRCLONE_CONFIG_B2_KEY=%s\n' "$B2_BACKUP_KEY_ID" "$B2_BACKUP_TOKEN" \
  > "$staging/etc/pve-backup-b2/b2.env"
printf '%s' "$B2_BACKUP_RESTIC_PASSWORD" > "$staging/etc/pve-backup-b2/passphrase"
: > "$staging/etc/pve-backup-b2/rclone.conf" # empty; the B2 remote is defined by environment variables
cat > "$staging/etc/pve-backup-b2/config" <<EOF
# Managed by tofu (pve-backup-b2.tf). Changes here are overwritten.
BUCKET="$BUCKET"
VMIDS="$VMIDS"
KEEP_DAILY=$KEEP_DAILY
KEEP_WEEKLY=$KEEP_WEEKLY
EOF

install -m 0755 "$here/backup-b2.sh" "$staging/usr/local/sbin/pve-backup-b2"

cat > "$staging/etc/systemd/system/pve-backup-b2.service" <<'EOF'
[Unit]
Description=Off-site VM backups to B2 (vzdump | gpg | rclone)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pve-backup-b2 run
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF
cat > "$staging/etc/systemd/system/pve-backup-b2.timer" <<EOF
[Unit]
Description=Nightly off-site VM backups to B2

[Timer]
OnCalendar=*-*-* $SCHEDULE
Persistent=true
RandomizedDelaySec=10m

[Install]
WantedBy=timers.target
EOF

ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10)
tar -C "$staging" -cf - . | ssh "${ssh_opts[@]}" "$SSH_TARGET" '
  set -eu
  command -v rclone >/dev/null || { apt-get -qq update; DEBIAN_FRONTEND=noninteractive apt-get -qq install -y rclone; }
  install -d -m 0700 /etc/pve-backup-b2
  # Left over from the earlier restic version of this job.
  rm -rf /usr/local/sbin/restic-b2 /etc/pve-backup-b2/password /var/cache/restic
  tar -C / -xf - --no-same-owner --no-overwrite-dir
  chmod 0600 /etc/pve-backup-b2/*
  systemctl daemon-reload
  # Fail now, not at 3am, if the B2 key or bucket is wrong.
  ( set -a; . /etc/pve-backup-b2/b2.env; . /etc/pve-backup-b2/config
    RCLONE_CONFIG=/etc/pve-backup-b2/rclone.conf RCLONE_CONFIG_B2_TYPE=b2 rclone lsf --max-depth 1 "b2:$BUCKET" >/dev/null ) \
    || { echo "!! cannot list the B2 bucket with this key" >&2; exit 1; }
  systemctl enable --now pve-backup-b2.timer
  systemctl list-timers pve-backup-b2.timer --no-pager | head -2'
