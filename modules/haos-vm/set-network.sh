#!/usr/bin/env bash
# Give a Home Assistant OS VM a static IPv4 address. HAOS has no cloud-init, so
# this runs `ha network update` inside the VM through the QEMU guest agent
# (Proxmox API: agent/exec), using the Supervisor's supported network API.
#
# Env: PVE_API (https://host:8006/api2/json), NODE, VMID, CIDR, GATEWAY,
#      DNS (space-separated), PROXMOX_VE_API_TOKEN (inherited from tofu).
set -euo pipefail
: "${PVE_API:?}" "${NODE:?}" "${VMID:?}" "${CIDR:?}" "${GATEWAY:?}" "${PROXMOX_VE_API_TOKEN:?}"

agent="$PVE_API/nodes/$NODE/qemu/$VMID/agent"
auth="Authorization: PVEAPIToken=$PROXMOX_VE_API_TOKEN"

# Run a command in the guest; prints its stdout, returns its exit code.
guest() {
  local args=() pid status
  for a in "$@"; do args+=(--data-urlencode "command=$a"); done
  pid=$(curl -fsSk -X POST -H "$auth" "$agent/exec" "${args[@]}" | jq -r .data.pid) || return 1
  for _ in $(seq 1 120); do
    status=$(curl -fsSk -H "$auth" "$agent/exec-status?pid=$pid") || return 1
    [[ $(jq -r .data.exited <<<"$status") == 1 ]] && break
    sleep 1
  done
  jq -r '.data["out-data"] // ""' <<<"$status"
  return "$(jq -r '.data.exitcode // 1' <<<"$status")"
}

echo ">> waiting for the HAOS Supervisor in VM $VMID"
for i in $(seq 1 60); do
  info=$(guest docker exec hassio_cli ha network info --raw-json 2>/dev/null) && break
  [[ $i -eq 60 ]] && { echo "!! Supervisor did not become ready" >&2; exit 1; }
  sleep 10
done

iface=$(jq -r '[.data.interfaces[] | select(.primary)][0].interface' <<<"$info")
current=$(jq -r '[.data.interfaces[] | select(.primary)][0].ipv4 | "\(.method) \(.address|join(","))"' <<<"$info")
if [[ $current == "static $CIDR" ]]; then
  echo ">> $iface already static $CIDR"
  exit 0
fi

args=(docker exec hassio_cli ha network update "$iface"
      --ipv4-method static --ipv4-address "$CIDR" --ipv4-gateway "$GATEWAY")
for ns in $DNS; do args+=(--ipv4-nameserver "$ns"); done
echo ">> $iface: $current -> static $CIDR"
guest "${args[@]}"
