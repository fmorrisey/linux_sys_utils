#!/usr/bin/env bash
# Inspect dual-bay JMicron USB enclosure drives:
#  - Detects bays (usbjmicron,0 / usbjmicron,1)
#  - Logs SMART before/after
#  - Runs extended SMART self-tests and polls progress (JSON)
#  - (Optional) Runs read-only badblocks per mapped block device
#  - Writes all logs to ~/logs/rosewill_drives
set -euo pipefail

LOGDIR="$HOME/logs/rosewill_drives"
RUN_BADBLOCKS="${RUN_BADBLOCKS:-0}"    # set RUN_BADBLOCKS=1 to run badblocks after SMART
POLL_SECS="${POLL_SECS:-60}"           # SMART progress poll interval (seconds)
MAP_TOL_BYTES=$((50 * 1024 * 1024))    # capacity matching tolerance for mapping (~50MiB)

mkdir -p "$LOGDIR"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: '$1' is required but not installed." >&2
    if [[ "$1" == "jq" ]]; then
      echo "       Install with: sudo apt install jq" >&2
    elif [[ "$1" == "smartctl" ]]; then
      echo "       Install with: sudo apt install smartmontools" >&2
    elif [[ "$1" == "badblocks" ]]; then
      echo "       Install with: sudo apt install e2fsprogs" >&2
    fi
    exit 1
  fi
}

require_cmd smartctl
require_cmd jq
# badblocks only required if RUN_BADBLOCKS=1 (checked later)

echo "==> Scan for JMicron USB bridges..."
mapfile -t BRIDGE_DEVS < <(sudo smartctl --scan | awk '/usbjmicron/ {print $1}' | sort -u)
if [[ ${#BRIDGE_DEVS[@]} -eq 0 ]]; then
  echo "No usbjmicron devices found via 'smartctl --scan'. Is the enclosure connected and powered?"
  exit 1
fi

# Serial -> "DEV IDX MODEL CAP_BYTES"
declare -A SERIAL_MAP

for DEV in "${BRIDGE_DEVS[@]}"; do
  for IDX in 0 1; do
    # Query device identity in JSON (quietly ignore errors for empty bays)
    OUT_JSON="$(sudo smartctl -i -d "usbjmicron,${IDX}" --json "$DEV" 2>/dev/null || true)"
    [[ -n "$OUT_JSON" ]] || continue

    # Extract fields robustly (keys vary by device/bridge)
    SERIAL="$(jq -r '(.serial_number // .device.serial_number // .ata_device.serial_number // empty)' <<<"$OUT_JSON")"
    MODEL="$(jq -r '(.model_name // .device.model_name // .ata_device.model_name // .scsi_model_name // empty)' <<<"$OUT_JSON")"
    CAP_BYTES="$(jq -r '(.user_capacity.bytes // .device.user_capacity.bytes // 0)' <<<"$OUT_JSON")"

    # Filter out empties/non-existent bays
    if [[ -n "${SERIAL:-}" && "$CAP_BYTES" =~ ^[0-9]+$ && "$CAP_BYTES" -gt 0 ]]; then
      if [[ -z "${SERIAL_MAP[$SERIAL]:-}" ]]; then
        SERIAL_MAP["$SERIAL"]="$DEV $IDX ${MODEL:-Unknown} $CAP_BYTES"
        echo " -> Found: Serial=$SERIAL  Model=${MODEL:-Unknown}  Capacity=${CAP_BYTES} bytes via $DEV (bay $IDX)"
      else
        echo " -> Duplicate path for Serial=$SERIAL detected; keeping first occurrence."
      fi
    fi
  done
done

if [[ ${#SERIAL_MAP[@]} -eq 0 ]]; then
  echo "No addressable disks behind usbjmicron ports (0/1)."
  exit 1
fi

# Build /dev/sdX -> size (bytes) map
declare -A DEV_BYTES
while read -r NAME SIZE TYPE; do
  [[ "$TYPE" == "disk" ]] || continue
  [[ "$NAME" =~ ^sd[a-z]+$ ]] || continue
  DEV_BYTES["/dev/$NAME"]="$SIZE"
done < <(lsblk -b -dn -o NAME,SIZE,TYPE)

echo
echo "==> Disks to process:"
i=0
for S in "${!SERIAL_MAP[@]}"; do
  read -r DEV IDX MODEL CAP <<<"${SERIAL_MAP[$S]}"
  printf "   [%d] Serial=%s  Model=%s  Path=%s  Bay=%s  Capacity=%s bytes\n" "$((++i))" "$S" "$MODEL" "$DEV" "$IDX" "$CAP"
done
echo

smart_summary() {
  local dev="$1" idx="$2" serial="$3"
  local out="$LOGDIR/${serial}_smart_before.txt"
  echo "==> SMART summary (before): $serial [$dev bay $idx]"
  sudo smartctl -a -d "usbjmicron,${idx}" "$dev" | tee "$out" >/dev/null
}

smart_start_long() {
  local dev="$1" idx="$2" serial="$3"
  echo "==> Starting extended SMART self-test: $serial [$dev bay $idx]"
  # Append the command output to the same before-file for provenance
  sudo smartctl -t long -d "usbjmicron,${idx}" "$dev" | tee -a "$LOGDIR/${serial}_smart_before.txt" >/dev/null || true
}

smart_poll_until_done() {
  local dev="$1" idx="$2" serial="$3"
  local final="$LOGDIR/${serial}_smart_after.txt"

  echo "==> Polling SMART test progress for $serial ..."
  while true; do
    local status_json
    status_json="$(sudo smartctl -a -d "usbjmicron,${idx}" --json "$dev" 2>/dev/null || true)"
    # percent_remaining is nested in json output; grab the first one if present
    local percent
    percent="$(jq -r '..|.percent_remaining? // empty' <<<"$status_json" | head -n1)"
    if [[ -n "$percent" ]]; then
      echo "    $serial: still running (${percent}% remaining). Next check in ${POLL_SECS}s"
      sleep "$POLL_SECS"
      continue
    fi

    # If no percent, check for the "in progress" text as fallback
    local status_txt
    status_txt="$(sudo smartctl -a -d "usbjmicron,${idx}" "$dev" 2>/dev/null || true)"
    if grep -q "Self-test routine in progress" <<<"$status_txt"; then
      echo "    $serial: still running (progress unknown). Next check in ${POLL_SECS}s"
      sleep "$POLL_SECS"
      continue
    fi

    echo "    $serial: test appears complete. Writing final SMART report."
    sudo smartctl -a -d "usbjmicron,${idx}" "$dev" | tee "$final" >/dev/null
    # Show key lines
    grep -E "SMART overall|Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable" "$final" || true
    break
  done
}

# Map capacity -> /dev/sdX (best match within tolerance)
find_block_node_for_capacity() {
  local target="$1"
  local best_dev=""
  local best_diff=""
  for node in "${!DEV_BYTES[@]}"; do
    local sz="${DEV_BYTES[$node]}"
    local diff=$(( target > sz ? target - sz : sz - target ))
    if [[ -z "$best_diff" || "$diff" -lt "$best_diff" ]]; then
      best_diff="$diff"
      best_dev="$node"
    fi
  done
  # Require match within tolerance to avoid accidental system disk choice
  if [[ -n "$best_dev" && "$best_diff" -le "$MAP_TOL_BYTES" ]]; then
    echo "$best_dev"
  else
    echo ""
  fi
}

run_badblocks_ro() {
  local blockdev="$1" serial="$2"
  require_cmd badblocks
  echo "==> badblocks (read-only) on $serial at $blockdev  (this may take MANY hours over USB 2.0)"
  echo "    Logging to: ${LOGDIR}/${serial}_badblocks.log"
  sudo badblocks -sv "$blockdev" | tee "${LOGDIR}/${serial}_badblocks.log"
  echo "    badblocks finished for $serial"
}

echo "==> SMART: initial summaries and start long tests"
for S in "${!SERIAL_MAP[@]}"; do
  read -r DEV IDX MODEL CAP <<<"${SERIAL_MAP[$S]}"
  smart_summary   "$DEV" "$IDX" "$S"
  smart_start_long "$DEV" "$IDX" "$S"
done

echo
echo "==> SMART: polling until all long tests finish"
for S in "${!SERIAL_MAP[@]}"; do
  read -r DEV IDX MODEL CAP <<<"${SERIAL_MAP[$S]}"
  smart_poll_until_done "$DEV" "$IDX" "$S"
done

echo
echo "==> Mapping each disk to a block device for optional surface scan"
declare -A SERIAL_TO_BLOCK
for S in "${!SERIAL_MAP[@]}"; do
  read -r _ _ _ CAP <<<"${SERIAL_MAP[$S]}"
  blk="$(find_block_node_for_capacity "$CAP")"
  if [[ -n "$blk" ]]; then
    SERIAL_TO_BLOCK["$S"]="$blk"
    echo " -> $S mapped to $blk"
  else
    echo " -> $S: could not confidently map to a /dev/sdX (capacity mismatch > ${MAP_TOL_BYTES}B)."
  fi
done

if [[ "$RUN_BADBLOCKS" == "1" ]]; then
  echo
  echo "==> Running non-destructive badblocks read scan"
  for S in "${!SERIAL_TO_BLOCK[@]}"; do
    run_badblocks_ro "${SERIAL_TO_BLOCK[$S]}" "$S"
  done
else
  echo
  echo "==> Skipping badblocks (set RUN_BADBLOCKS=1 to enable)"
fi

echo
echo "✅ Done. Reports are in: $LOGDIR"
echo "   - *_smart_before.txt  (baseline + test kickoff)"
echo "   - *_smart_after.txt   (final results)"
echo "   - *_badblocks.log     (if enabled)"
