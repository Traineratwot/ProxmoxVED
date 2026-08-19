#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

# LXC Disk Resize — shrink LXC container disks safely via dd copy + checksum
# verification for LVM/LVM-thin storage, or refquota adjustment for ZFS
# subvolumes.  Supports both interactive (whiptail) and non-interactive (CLI)
# modes.

# =============================================================================
# 1. INITIALIZATION & IMPORTS
# =============================================================================

if command -v curl >/dev/null 2>&1; then
  source <(curl -fsSL ${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/core.func)
  source <(curl -fsSL ${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/lib/tools.func)
  source <(curl -fsSL ${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/error_handler.func)
elif command -v wget >/dev/null 2>&1; then
  source <(wget -qO- ${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/core.func)
  source <(wget -qO- ${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/lib/tools.func)
  source <(wget -qO- ${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/error_handler.func)
else
  echo "curl or wget is required" >&2
  exit 1
fi
load_functions
catch_errors

# Override community error_handler — resize tool should not offer container removal
error_handler() {
  local exit_code=${1:-$?}
  local cmd=${2:-${BASH_COMMAND:-unknown}}
  local line=${BASH_LINENO[0]:-unknown}
  stop_spinner 2>/dev/null || true
  msg_error "in line ${line}: exit code ${exit_code} — ${cmd}"
  log "ERROR exit=$exit_code line=$line cmd=$cmd"
  allow_interrupts 2>/dev/null || true
  exit "$exit_code"
}
trap error_handler ERR

set -Eeuo pipefail
export PERL_BADLANG=0

# =============================================================================
# 2. GLOBAL VARIABLES
# =============================================================================

LOGFILE="/var/log/lxc-resize.log"
META_DIR="/opt/lxc-resize-meta"
INTERRUPT_BLOCKED=0

# Storage types that have been tested and confirmed to work with resize.
# ZFS: refquota adjustment (fast, no data copy).
# LVM/LVM-thin: dd copy + config swap.
# dir/nfs/cifs: dd copy + config swap (may be slow on network storage).
SUPPORTED_STORAGE_TYPES="zfspool lvm lvmthin dir nfs cifs"

# =============================================================================
# 3. LOGGING
# =============================================================================

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >>"$LOGFILE"
}

# =============================================================================
# 4. INTERRUPT HANDLING
# =============================================================================

trap_exit() {
  if [[ "$INTERRUPT_BLOCKED" -eq 1 ]]; then
    echo -e "\n${RD}Cannot interrupt — critical operation in progress. Wait for it to finish.${CL}"
    log "INTERRUPT_BLOCKED"
    return
  fi
  echo -e "\n${RD}Interrupted by user.${CL}"
  log "INTERRUPTED by user"
  exit 130
}

block_interrupts() { INTERRUPT_BLOCKED=1; }
allow_interrupts() { INTERRUPT_BLOCKED=0; }

trap trap_exit INT TERM

# =============================================================================
# 5. UI HELPERS
# =============================================================================

# Override community header_info — don't require TERM or header file
function header_info {
  clear
  cat <<"EOF"
______          _           _     __   _______
| ___ \        (_)         | |    \ \ / /  __ \
| |_/ /___  ___ _ _______  | |     \ V /| /  \/
|    // _ \/ __| |_  / _ \ | |     /   \| |
| |\ \  __/\__ \ |/ /  __/ | |____/ /^\ \ \__/\
\_| \_\___||___/_/___\___| \_____/\/   \/\____/

EOF
}

spin_wait() {
  local pid=$1
  local msg=${2:-"Working"}
  color_spinner
  SPINNER_MSG="$msg"
  spinner &
  local spid=$!
  SPINNER_PID=$spid
  wait "$pid"
  stop_spinner
}

unlock_ct() {
  local ctid=$1
  local attempt=0
  local max_attempts=5
  while ((attempt < max_attempts)); do
    if pct unlock "$ctid" 2>/dev/null; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  return 1
}

# =============================================================================
# 6. PVE COMMAND WRAPPERS
# =============================================================================

_pct() {
  LC_ALL=C "$@" 2>/dev/null | tr -d '\r' | sed 's/[[:space:]]*$//'
}

pct_cfg()  { _pct pct config "$@"; }
pct_st()   { _pct pct status "$@"; }
pct_ls()   { _pct pct list; }
pct_dsk()  { _pct pct df "$@"; }

# =============================================================================
# 7. CONTAINER LIFECYCLE HELPERS
# =============================================================================

stop_ct() {
  local ctid=$1
  if [[ "$(pct_st "$ctid")" == "status: running" ]]; then
    pct stop "$ctid" &
    spin_wait $! "Stopping container"
  fi
  local wait_sec=0
  while [[ "$(pct_st "$ctid")" == "status: running" ]]; do
    sleep 1
    wait_sec=$((wait_sec + 1))
    if ((wait_sec >= 60)); then
      msg_error "Container did not stop within 60 seconds"
      return 1
    fi
  done
  sleep 3
}

start_ct() {
  local ctid=$1
  pct start "$ctid" &
  spin_wait $! "Starting container"
  local wait_sec=0
  while [[ "$(pct_st "$ctid")" != "status: running" ]]; do
    sleep 2
    wait_sec=$((wait_sec + 2))
    if ((wait_sec >= 30)); then
      break
    fi
  done
}

get_disk_config_line() {
  local ctid=$1
  local disk_key=$2
  disk_key=$(printf '%s' "$disk_key" | tr -d "'\"[:space:]")
  pct_cfg "$ctid" | awk -v dk="$disk_key" '$0 ~ "^"dk":" {print}'
}

resolve_storage_path() {
  local storage="$1"
  awk -v st="$storage" '
    /^(dir|nfs|cifs):/ { match_name = ($2 == st) }
    match_name && /^[\t ]+path / { print $2; exit }
  ' /etc/pve/storage.cfg 2>/dev/null
}

# =============================================================================
# 8. SIZE CONVERSION HELPERS
# =============================================================================

parse_size_to_bytes() {
  local size="$1"
  local num="${size%%[KMGTPkmgtp]*}"
  local unit="${size##*[0-9]}"
  unit="${unit^^}"
  case "$unit" in
    T) awk "BEGIN { printf \"%.0f\", $num * 1024 * 1024 * 1024 * 1024 }" ;;
    G) awk "BEGIN { printf \"%.0f\", $num * 1024 * 1024 * 1024 }" ;;
    M) awk "BEGIN { printf \"%.0f\", $num * 1024 * 1024 }" ;;
    K) awk "BEGIN { printf \"%.0f\", $num * 1024 }" ;;
    B|"") echo "$num" ;;
    *) echo "0" ;;
  esac
}

bytes_to_human() {
  local bytes=$1
  if ((bytes >= 1073741824)); then
    echo "$((bytes / 1073741824))G"
  elif ((bytes >= 1048576)); then
    echo "$((bytes / 1048576))M"
  elif ((bytes >= 1024)); then
    echo "$((bytes / 1024))K"
  else
    echo "${bytes}B"
  fi
}

# =============================================================================
# 9. STORAGE QUERY HELPERS
# =============================================================================

get_storage_type() {
  local storage="$1"
  pvesm status | awk -v st="$storage" '$1 == st {print $2}'
}

get_zfs_pool() {
  local storage="$1"
  awk -v st="$storage" '
    /^zfspool:/ { match_name = ($2 == st) }
    match_name && /^[\t ]+pool / { print $2; exit }
  ' /etc/pve/storage.cfg 2>/dev/null
}

get_zfs_dataset() {
  local storage="$1"
  local vol_name="$2"
  local pool
  pool=$(get_zfs_pool "$storage")
  [[ -n "$pool" ]] && echo "${pool}/${vol_name}" || echo ""
}

resolve_vg_name() {
  local vol_name="$1"
  local vg_name
  vg_name=$(lvs --noheadings -o vg_name 2>/dev/null | awk -v lv="$vol_name" '$1 == lv {print $1}')
  if [[ -z "$vg_name" ]]; then
    vg_name=$(lvs --noheadings -o vg_name 2>/dev/null | head -1 | tr -d ' ')
  fi
  echo "$vg_name"
}

# =============================================================================
# 10. CONTAINER CONFIG QUERY HELPERS
# =============================================================================

get_volume_name() {
  local ctid=$1
  local disk_key=$2
  get_disk_config_line "$ctid" "$disk_key" | cut -d: -f3 | cut -d, -f1
}

get_storage_for_disk() {
  local ctid=$1
  local disk_key=$2
  get_disk_config_line "$ctid" "$disk_key" | awk -F": " '{print $2}' | cut -d: -f1
}

get_size_from_config() {
  local ctid=$1
  local disk_key=$2
  get_disk_config_line "$ctid" "$disk_key" | grep -oP 'size=\K[^ ,]+'
}

get_used_bytes() {
  local ctid=$1
  local disk_key=$2
  local used
  used=$(pct_dsk "$ctid" 2>/dev/null | awk -v dk="$disk_key" '$1 == dk {print $4}' || true)
  if [[ -n "$used" ]]; then
    parse_size_to_bytes "$used"
  else
    echo "0"
  fi
}

get_max_bytes() {
  local ctid=$1
  local disk_key=$2
  local size_str
  size_str=$(get_size_from_config "$ctid" "$disk_key")
  if [[ -n "$size_str" ]]; then
    parse_size_to_bytes "$size_str"
  else
    echo "0"
  fi
}

# =============================================================================
# 11. DEVICE PATH RESOLUTION
# =============================================================================

get_device_path() {
  local vol="$1"
  local storage="${vol%%:*}"
  local vol_name="${vol#*:}"
  local storage_type
  storage_type=$(get_storage_type "$storage")

  case $storage_type in
    lvmthin|lvm)
      local vg_name
      vg_name=$(resolve_vg_name "$vol_name")
      echo "/dev/${vg_name}/${vol_name}"
      ;;
    zfs)
      local zfs_pool
      zfs_pool=$(get_zfs_pool "$storage")
      echo "/dev/zvol/${zfs_pool}/${vol_name}"
      ;;
    dir|nfs|cifs)
      local vol_path
      vol_path=$(pvesm path "$vol" 2>/dev/null) || true
      if [[ -z "$vol_path" ]]; then
        local vol_name_path="${vol#*:}"
        local ctid_num="${ctid:-0}"
        local mount_point
        mount_point=$(resolve_storage_path "$storage")
        if [[ -n "$mount_point" ]]; then
          if [[ "$vol_name_path" == "${ctid_num}/"* ]]; then
            vol_path="${mount_point}/images/${vol_name_path}"
          else
            vol_path="${mount_point}/images/${ctid_num}/${vol_name_path}"
          fi
        fi
      fi
      echo "$vol_path"
      ;;
    *)
      echo ""
      ;;
  esac
}

# =============================================================================
# 12. VOLUME LIFECYCLE (CREATE / REMOVE)
# =============================================================================

get_next_disk_number() {
  local ctid=$1
  local max_disk=-1
  local vol
  for vol in $(pct_cfg "$ctid" | awk -F'[: ,]' '/^(rootfs|mp[0-9]+)/ {print $4}'); do
    local disk_num
    disk_num=$(echo "$vol" | grep -oP 'disk-\K[0-9]+' || echo "-1")
    if [[ "$disk_num" =~ ^[0-9]+$ ]] && ((disk_num > max_disk)); then
      max_disk=$disk_num
    fi
  done
  echo $((max_disk + 1))
}

create_new_volume() {
  local ctid=$1
  local disk_key=$2
  local new_size=$3
  local storage
  storage=$(get_storage_for_disk "$ctid" "$disk_key")
  local storage_type
  storage_type=$(get_storage_type "$storage")
  local next_disk
  next_disk=$(get_next_disk_number "$ctid")

  case $storage_type in
    lvmthin|lvm)
      local vg_name
      vg_name=$(lvs --noheadings -o vg_name 2>/dev/null | head -1 | tr -d ' ')
      local new_vol="vm-${ctid}-disk-${next_disk}"
      lvcreate -L "${new_size}" -n "$new_vol" "$vg_name"
      echo "${storage}:${new_vol}"
      ;;
    zfs)
      local new_vol="subvol-${ctid}-disk-${next_disk}"
      local zfs_ds
      zfs_ds=$(get_zfs_dataset "$storage" "$new_vol")
      zfs create -V "${new_size}" "$zfs_ds"
      echo "${storage}:${new_vol}"
      ;;
    dir|nfs|cifs)
      local new_vol="${ctid}/vm-${ctid}-disk-${next_disk}.raw"
      local storage_path=""
      storage_path=$(pvesm path "${storage}:${new_vol}" 2>/dev/null) || true
      if [[ -z "$storage_path" ]]; then
        local mount_point
        mount_point=$(resolve_storage_path "$storage")
        if [[ -n "$mount_point" ]]; then
          storage_path="${mount_point}/images/${ctid}/${new_vol}"
        fi
      fi
      if [[ -z "$storage_path" ]]; then
        msg_error "Failed to resolve path for new volume"
        log "ERROR pvesm_path storage=$storage vol=$new_vol"
        return 1
      fi
      mkdir -p "$(dirname "$storage_path")"
      truncate -s "${new_size}" "$storage_path"
      echo "${storage}:${new_vol}"
      ;;
    *)
      echo ""
      return 1
      ;;
  esac
}

remove_volume() {
  local vol="$1"
  local storage="${vol%%:*}"
  local vol_name="${vol#*:}"
  local storage_type
  storage_type=$(get_storage_type "$storage")

  case $storage_type in
    lvmthin|lvm)
      local vg_name
      vg_name=$(resolve_vg_name "$vol_name")
      lvremove -f "/dev/${vg_name}/${vol_name}" 2>/dev/null || true
      ;;
    zfs)
      local zfs_ds
      zfs_ds=$(get_zfs_dataset "$storage" "$vol_name")
      zfs destroy "$zfs_ds" 2>/dev/null || true
      ;;
    dir|nfs|cifs)
      local vol_path
      vol_path=$(pvesm path "$vol" 2>/dev/null) || true
      rm -f "$vol_path" 2>/dev/null || true
      ;;
  esac
}

# =============================================================================
# 13. DATA COPY & VERIFICATION
# =============================================================================

get_dd_params() {
  local source_size=$1
  local bs=1M
  local count=$((source_size / 1048576))
  ((count < 1)) && count=1
  echo "$bs" "$count"
}

copy_data() {
  local source_dev="$1"
  local dest_dev="$2"
  local source_size=$3

  local bs count
  read -r bs count <<< "$(get_dd_params "$source_size")"
  local dd_errors
  dd_errors=$(mktemp)
  dd if="$source_dev" of="$dest_dev" bs="$bs" count="$count" status=progress 2>"$dd_errors"
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    cat "$dd_errors" >&2
    rm -f "$dd_errors"
    return $rc
  fi
  rm -f "$dd_errors"
  return 0
}

verify_checksum() {
  local source_dev="$1"
  local dest_dev="$2"
  local source_size=$3

  local bs count
  read -r bs count <<< "$(get_dd_params "$source_size")"

  local source_hash dest_hash
  source_hash=$(dd if="$source_dev" bs="$bs" count="$count" 2>/dev/null | md5sum | awk '{print $1}')
  dest_hash=$(dd if="$dest_dev" bs="$bs" count="$count" 2>/dev/null | md5sum | awk '{print $1}')

  if [[ "$source_hash" == "$dest_hash" ]]; then
    return 0
  else
    msg_error "Source hash: ${source_hash}"
    msg_error "Dest hash:   ${dest_hash}"
    log "CHECKSUM_MISMATCH src=$source_hash dst=$dest_hash"
    return 1
  fi
}

# =============================================================================
# 14. CONTAINER CONFIG MANIPULATION
# =============================================================================

replace_volume_in_config() {
  local ctid=$1
  local disk_key=$2
  local new_vol=$3
  local new_size=${4:-}

  local storage="${new_vol%%:*}"
  local vol_name="${new_vol#*:}"
  local vol_value="${storage}:${vol_name}"
  [[ -n "$new_size" ]] && vol_value="${vol_value},size=${new_size}"

  unlock_ct "$ctid" 2>/dev/null || true
  local attempt=0
  local max_attempts=10
  local pvesm_ok=false
  while ((attempt < max_attempts)); do
    case $disk_key in
      rootfs)
        if pct set "$ctid" --rootfs "${vol_value}" 2>/dev/null; then
          pvesm_ok=true
          break
        fi
        ;;
      mp[0-9]*)
        local old_mp_opts
        old_mp_opts=$(pct_cfg "$ctid" | awk -v dk="$disk_key" '$0 ~ "^"dk":" {sub(/^[^ ]+ [^ ]+ [^ ]+ /, ""); print}' || true)
        if [[ -n "$old_mp_opts" ]]; then
          pct set "$ctid" -"${disk_key}" "${vol_value},${old_mp_opts}" 2>/dev/null && { pvesm_ok=true; break; }
        else
          pct set "$ctid" -"${disk_key}" "${vol_value}" 2>/dev/null && { pvesm_ok=true; break; }
        fi
        ;;
    esac
    attempt=$((attempt + 1))
    unlock_ct "$ctid" 2>/dev/null || true
    sleep 1
  done

  if [[ "$pvesm_ok" == "false" ]]; then
    local conf="/etc/pve/lxc/${ctid}.conf"
    if [[ -f "$conf" ]]; then
      local old_line
      old_line=$(grep "^${disk_key}:" "$conf" 2>/dev/null || true)
      if [[ -n "$old_line" ]]; then
        sed -i "s|^${disk_key}:.*|${disk_key}: ${vol_value}|" "$conf"
        msg_warn "Used direct config edit (pct locked)"
        log "WARN direct_config_edit ctid=$ctid disk=$disk_key"
      else
        echo "${disk_key}: ${vol_value}" >>"$conf"
      fi
    else
      msg_error "Config file not found: ${conf}"
      return 1
    fi
  fi
}

# =============================================================================
# 15. ROLLBACK — THE MOST CRITICAL COMPONENT
# =============================================================================

save_rollback_metadata() {
  local ctid=$1
  local disk_key=$2
  local old_vol=$3
  local new_vol=$4
  local old_size=${5:-}

  mkdir -p "$META_DIR"
  cat >"${META_DIR}/${ctid}.meta" <<EOF
CTID=$ctid
DISK_KEY=$disk_key
OLD_VOL=$old_vol
NEW_VOL=$new_vol
OLD_SIZE=${old_size}
TIMESTAMP=$(date +%s)
EOF
}

rollback_operation() {
  local ctid=$1
  local disk_key=$2
  local old_vol=$3
  local new_vol=$4

  msg_info "Rolling back operation..."
  log "ROLLBACK CTID=$ctid DISK_KEY=$disk_key OLD_VOL=$old_vol NEW_VOL=$new_vol"

  local old_size=""
  if [[ -f "${META_DIR}/${ctid}.meta" ]]; then
    # shellcheck source=/dev/null
    source "${META_DIR}/${ctid}.meta"
    old_size="${OLD_SIZE:-}"
  fi

  stop_ct "$ctid" || {
    msg_error "CRITICAL: Could not stop container for rollback"
    log "ROLLBACK_FAIL cannot_stop ctid=$ctid"
    return 1
  }

  local storage="${old_vol%%:*}"
  local vol_name="${old_vol#*:}"
  local stype
  stype=$(get_storage_type "$storage")

  # ZFS subvol rollback: restore refquota
  if [[ "$stype" == "zfspool" ]]; then
    local zfs_ds ds_type
    zfs_ds=$(get_zfs_dataset "$storage" "$vol_name")
    ds_type=$(zfs get -H -o value type "$zfs_ds" 2>/dev/null || echo "")
    if [[ "$ds_type" == "filesystem" && -n "$old_size" ]]; then
      msg_info "Restoring refquota to ${old_size}..."
      zfs set refquota="${old_size}" "$zfs_ds"
      msg_ok "refquota restored"
      log "ROLLBACK_REFQUOTA old_size=$old_size"
      start_ct "$ctid"
      msg_ok "Rollback completed"
      log "ROLLBACK_OK CTID=$ctid"
      return 0
    fi
  fi

  # LVM / zvol / directory rollback: remove new volume, restore old config
  remove_volume "$new_vol"
  replace_volume_in_config "$ctid" "$disk_key" "$old_vol" "$old_size"

  start_ct "$ctid"
  msg_ok "Rollback completed"
  log "ROLLBACK_OK CTID=$ctid"
}

# =============================================================================
# 16. INPUT VALIDATION
# =============================================================================

validate_inputs() {
  local ctid=$1
  local disk_key=$2
  local target_size=$3

  if ! pct status "$ctid" >/dev/null 2>&1; then
    msg_error "Container $ctid does not exist."
    return 1
  fi

  local config_line
  config_line=$(get_disk_config_line "$ctid" "$disk_key")
  if [[ -z "$config_line" ]]; then
    msg_error "Disk '$disk_key' not found in container $ctid."
    return 1
  fi

  # Check storage type is supported
  local storage stype
  storage=$(get_storage_for_disk "$ctid" "$disk_key")
  stype=$(get_storage_type "$storage")
  if ! echo "$SUPPORTED_STORAGE_TYPES" | grep -qw "$stype"; then
    msg_error "Storage type '${stype}' is not supported for resize."
    msg_error "Supported types: ${SUPPORTED_STORAGE_TYPES}"
    return 1
  fi

  if ! [[ "$target_size" =~ ^[0-9]+(\.[0-9]+)?[KMGTPkmgtp]?$ ]]; then
    msg_error "Invalid size format '$target_size'. Use e.g. 3G, 500M, 1500MB, or a bare number for GB."
    return 1
  fi

  local used_bytes max_bytes new_bytes
  used_bytes=$(get_used_bytes "$ctid" "$disk_key")
  max_bytes=$(get_max_bytes "$ctid" "$disk_key")
  new_bytes=$(parse_size_to_bytes "$target_size")

  if ((new_bytes == 0)); then
    msg_error "Target size resolves to 0 bytes."
    return 1
  fi

  if ((new_bytes >= max_bytes)) && ((max_bytes > 0)); then
    msg_error "Target size ($(bytes_to_human "$new_bytes")) must be less than current size ($(bytes_to_human "$max_bytes"))."
    return 1
  fi

  if ((new_bytes <= used_bytes)) && ((used_bytes > 0)); then
    msg_error "Target size ($(bytes_to_human "$new_bytes")) must be greater than used space ($(bytes_to_human "$used_bytes"))."
    return 1
  fi

  return 0
}

# =============================================================================
# 17. INTERACTIVE UI (WHIPTAIL MENUS)
# =============================================================================

select_container() {
  mapfile -t containers < <(pct_ls | tail -n +2)

  if [[ ${#containers[@]} -eq 0 ]]; then
    whiptail --title "LXC Disk Resize" --msgbox "No LXC containers found!" 8 50
    exit 1
  fi

  local menu_items=()
  for line in "${containers[@]}"; do
    local cid cname cstatus cos
    cid=$(echo "$line" | awk '{print $1}')
    cname=$(echo "$line" | awk '{print $2}')
    cstatus=$(echo "$line" | awk '{print $3}')
    cos=$(echo "$line" | awk '{print $4}')
    local desc
    desc=$(printf "%-20s %-10s %-15s" "$cname" "$cstatus" "$cos")
    menu_items+=("$cid" "$desc" "OFF")
  done

  msg_info "Loading containers..."
  stop_spinner
  local selected
  selected=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
    --title "Select Container" \
    --radiolist "\nSelect an LXC container to resize:" \
    22 78 12 "${menu_items[@]}" 3>&1 1>&2 2>&3) || exit 0

  echo "$selected"
}

select_disk() {
  local ctid=$1
  local config_lines
  config_lines=$(pct_cfg "$ctid" | awk '/^(rootfs|mp[0-9]+):/ {print}')

  if [[ -z "$config_lines" ]]; then
    whiptail --title "LXC Disk Resize" --msgbox "No disks found in container $ctid!" 8 50
    exit 1
  fi

  msg_info "Loading disks..."
  stop_spinner
  local menu_items=()
  while IFS= read -r line; do
    local key
    key=$(echo "$line" | awk -F'[: ,]' '{print $1}' | tr -d "'\"[:space:]")
    local storage
    storage=$(echo "$line" | awk -F'[: ,]' '{print $2}')
    local size_str
    size_str=$(echo "$line" | grep -oP 'size=\K[^ ,]+' || echo "N/A")
    local stype
    stype=$(get_storage_type "$storage")
    local desc="${key}  |  ${storage} (${stype})  |  ${size_str}"
    menu_items+=("$key" "$desc" "OFF")
  done <<<"$config_lines"

  local selected
  selected=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
    --title "Select Disk" \
    --radiolist "\nSelect disk to resize:" \
    20 78 10 "${menu_items[@]}" 3>&1 1>&2 2>&3) || exit 0

  echo "$selected"
}

get_target_size() {
  local ctid=$1
  local disk_key=$2

  local used_bytes max_bytes
  used_bytes=$(get_used_bytes "$ctid" "$disk_key")
  max_bytes=$(get_max_bytes "$ctid" "$disk_key")

  local used_gb max_gb default_size
  used_gb=$((used_bytes / 1073741824))
  max_gb=$((max_bytes / 1073741824))

  if ((used_gb > 0)); then
    default_size=$((used_gb + used_gb / 5 + 1))
  else
    default_size=2
  fi
  if ((default_size >= max_gb)) && ((max_gb > 0)); then
    default_size=$((max_gb - 1))
  fi
  if ((default_size < 1)); then
    default_size=1
  fi

  msg_info "Calculating disk usage..."
  stop_spinner
  local hint=""
  if ((used_bytes > 0)); then
    hint="Current: $(bytes_to_human "$max_bytes") | Used: $(bytes_to_human "$used_bytes")\nMust be > $(bytes_to_human "$used_bytes") and < $(bytes_to_human "$max_bytes")"
  else
    hint="Current: $(bytes_to_human "$max_bytes")\nMust be < $(bytes_to_human "$max_bytes")"
  fi

  while true; do
    local target_size
    target_size=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
      --title "Target Size" \
      --inputbox "\n${hint}\n\nExamples: 3G, 500M, 1500MB, 2 (defaults to GB)" \
      14 60 "$default_size" 3>&1 1>&2 2>&3) || exit 0

    [[ -z "$target_size" ]] && continue

    target_size="${target_size// /}"
    [[ "$target_size" =~ ^[0-9]+(\.[0-9]+)?$ ]] && target_size="${target_size}G"

    local validation_error
    if validation_error=$(validate_inputs "$ctid" "$disk_key" "$target_size" 2>&1); then
      echo "$target_size"
      return 0
    else
      log "VALIDATION_FAIL size=$target_size error=$validation_error"
      msg_error "${TAB}✘ ${validation_error}" >&2
      whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "Error" --msgbox "\n${validation_error}" 10 60 2>/dev/null || true
    fi
  done
}

confirm_operation() {
  local ctid=$1
  local disk_key=$2
  local target_size=$3

  local container_name
  container_name=$(pct_cfg "$ctid" | awk '/^hostname:/ {print $2}')
  local current_size
  current_size=$(get_size_from_config "$ctid" "$disk_key")
  local storage
  storage=$(get_storage_for_disk "$ctid" "$disk_key")
  local stype
  stype=$(get_storage_type "$storage")

  local msg="Container: ${ctid} (${container_name})\n"
  msg+="Disk: ${disk_key}\n"
  msg+="Storage: ${storage} (${stype})\n"
  msg+="Current size: ${current_size}\n"
  msg+="New size: ${target_size}\n\n"
  msg+="The container will be stopped during the operation.\n"
  msg+="Proceed?"

  whiptail --backtitle "Proxmox VE Helper Scripts" \
    --title "Confirm Resize" \
    --yesno "$msg" 16 60 || exit 0
}

post_operation() {
  local ctid=$1
  local disk_key=$2
  local old_vol=$3
  local new_vol=$4

  local choice
  choice=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
    --title "Post-Operation" \
    --menu "\nResize complete. What to do with the old volume?\n\nOld: ${old_vol}\nNew: ${new_vol}" \
    14 70 3 \
    "1" "Delete old volume" \
    "2" "Keep old volume (do nothing)" \
    "3" "Rollback to original" \
    3>&1 1>&2 2>&3) || choice="2"

  case "$choice" in
    1)
      msg_info "Deleting old volume..."
      remove_volume "$old_vol"
      msg_ok "Old volume deleted"
      log "POST_DELETE old_vol=$old_vol"
      ;;
    3)
      rollback_operation "$ctid" "$disk_key" "$old_vol" "$new_vol"
      ;;
    *)
      msg_info "Old volume kept"
      log "POST_KEEP old_vol=$old_vol"
      ;;
  esac
}

# =============================================================================
# 18. RESIZE STRATEGIES
# =============================================================================

resize_zfs_subvol() {
  local ctid=$1
  local disk_key=$2
  local target_size=$3
  local storage=$4
  local vol_name=$5
  local current_size=$6

  local zfs_ds ds_type
  zfs_ds=$(get_zfs_dataset "$storage" "$vol_name")
  ds_type=$(zfs get -H -o value type "$zfs_ds" 2>/dev/null || echo "")
  [[ "$ds_type" != "filesystem" ]] && return 1

  msg_info "ZFS subvol — shrinking via refquota"
  log "MODE=refquota zfs_ds=$zfs_ds"

  local used_bytes target_bytes
  used_bytes=$(zfs get -H -o value used "$zfs_ds" 2>/dev/null || echo "0")
  used_bytes=$(parse_size_to_bytes "$used_bytes")
  target_bytes=$(parse_size_to_bytes "$target_size")

  if ((used_bytes >= target_bytes)); then
    msg_error "Error: Used space ($(bytes_to_human "$used_bytes")) >= target size (${target_size})"
    log "ERROR used_space_exceeds_target"
    return 1
  fi

  msg_info "Step 1/4: Stopping container..."
  log "STEP1_STOPPING ctid=$ctid"
  stop_ct "$ctid" || return 1
  msg_ok "Container stopped"
  log "STEP1_OK"

  msg_info "Step 2/4: Setting refquota to ${target_size}..."
  log "STEP2_REFQUOTA ds=$zfs_ds size=$target_size"
  zfs set refquota="${target_size}" "$zfs_ds" &
  spin_wait $! "Setting refquota"
  msg_ok "refquota updated"
  log "STEP2_OK refquota=$target_size"

  msg_info "Step 3/4: Starting container..."
  log "STEP3_STARTING ctid=$ctid"
  start_ct "$ctid"
  msg_ok "Container started"
  log "STEP3_OK"

  msg_info "Step 4/4: Verifying resize..."
  sleep 2
  local actual_size
  actual_size=$(pct_dsk "$ctid" | awk '$1 == "rootfs" {print $3}')
  local actual_status
  actual_status=$(pct_st "$ctid")

  if [[ "$actual_status" == "status: running" ]]; then
    msg_ok "Container is running"
    log "VERIFY_OK status=running"
  else
    msg_error "Container is not running!"
    log "VERIFY_FAIL status=$actual_status"
  fi

  if [[ -n "$actual_size" ]]; then
    msg_ok "Disk size: ${actual_size}"
    log "VERIFY_OK size=$actual_size expected=$target_size"

    local actual_bytes expected_bytes diff pct_diff
    actual_bytes=$(parse_size_to_bytes "$actual_size")
    expected_bytes=$(parse_size_to_bytes "$target_size")
    if ((actual_bytes > expected_bytes)); then
      diff=$((actual_bytes - expected_bytes))
    else
      diff=$((expected_bytes - actual_bytes))
    fi
    pct_diff=$((diff * 100 / expected_bytes))
    if ((pct_diff > 5)); then
      msg_error "Size mismatch: expected ${target_size}, got ${actual_size}"
      log "VERIFY_FAIL size_mismatch expected=$target_size actual=$actual_size"
      if prompt_confirm "Would you like to retry with dd copy instead?" "n" 60; then
        log "FALLBACK_DD"
        return 1
      else
        log "FALLBACK_DECLINED"
        return 1
      fi
    else
      log "SUCCESS CTID=$ctid DISK_KEY=$disk_key OLD=$current_size NEW=$target_size MODE=refquota"
      return 0
    fi
  else
    msg_error "Could not read disk size"
    log "VERIFY_FAIL size_unknown"
    return 1
  fi
}

# Resize ext4 by creating a fresh filesystem and copying files.
# This avoids ext4 metadata mismatch issues with dd.
# Returns 0 on success, 1 on failure.
resize_via_copy() {
  local ctid=$1
  local disk_key=$2
  local target_size=$3
  local storage=$4
  local vol_name=$5
  local current_size=$6
  local old_vol="${storage}:${vol_name}"

  msg_info "Using file copy approach (ext4)"
  log "MODE=copy old_vol=$old_vol"

  local dest_bytes
  dest_bytes=$(parse_size_to_bytes "$target_size")

  # Step 1: Create new volume of TARGET size
  msg_info "Step 1/7: Creating new volume..."
  log "STEP1_CREATE_VOL ctid=$ctid disk=$disk_key target=$target_size"
  local new_vol
  new_vol=$(create_new_volume "$ctid" "$disk_key" "$target_size")
  if [[ -z "$new_vol" ]]; then
    msg_error "Error: Failed to create new volume"
    log "ERROR create_new_volume failed"
    return 1
  fi
  msg_ok "New volume created: ${new_vol}"
  log "STEP1_OK new_vol=$new_vol"

  # Step 2: Stop the container
  msg_info "Step 2/7: Stopping container..."
  log "STEP2_STOPPING ctid=$ctid"
  stop_ct "$ctid" || {
    rollback_operation "$ctid" "$disk_key" "$old_vol" "$new_vol"
    return 1
  }
  msg_ok "Container stopped"
  log "STEP2_OK"

  # Step 3: Format new volume and copy files
  msg_info "Step 3/7: Formatting and copying data..."
  local source_dev dest_dev
  source_dev=$(get_device_path "$old_vol")
  dest_dev=$(get_device_path "$new_vol")

  if [[ -z "$source_dev" || -z "$dest_dev" ]]; then
    msg_error "Error: Could not resolve device paths"
    log "ERROR device_path source=$source_dev dest=$dest_dev"
    rollback_operation "$ctid" "$disk_key" "$old_vol" "$new_vol"
    return 1
  fi

  # Pre-copy check: verify used data fits in destination
  local used_bytes
  used_bytes=$(get_used_bytes "$ctid" "$disk_key")
  if ((used_bytes > dest_bytes)); then
    msg_error "Used data ($(bytes_to_human "$used_bytes")) exceeds target size ($(bytes_to_human "$dest_bytes"))"
    log "ERROR used_exceeds_target used=$used_bytes target=$dest_bytes"
    rollback_operation "$ctid" "$disk_key" "$old_vol" "$new_vol"
    return 1
  fi

  # Create ext4 filesystem on destination
  mkfs.ext4 -F -q "$dest_dev" >/dev/null 2>&1
  log "STEP3_MKFS dst=$dest_dev"

  # Mount both and copy
  local src_mnt="/mnt/.resize_src_$$"
  local dst_mnt="/mnt/.resize_dst_$$"
  mkdir -p "$src_mnt" "$dst_mnt"

  if ! mount -o ro "$source_dev" "$src_mnt" 2>/dev/null; then
    msg_error "Error: Failed to mount source filesystem"
    log "ERROR mount_source src=$source_dev"
    rmdir "$src_mnt" "$dst_mnt" 2>/dev/null || true
    rollback_operation "$ctid" "$disk_key" "$old_vol" "$new_vol"
    return 1
  fi

  if ! mount "$dest_dev" "$dst_mnt" 2>/dev/null; then
    msg_error "Error: Failed to mount destination filesystem"
    log "ERROR mount_dest dst=$dest_dev"
    umount "$src_mnt" 2>/dev/null || true
    rmdir "$src_mnt" "$dst_mnt" 2>/dev/null || true
    rollback_operation "$ctid" "$disk_key" "$old_vol" "$new_vol"
    return 1
  fi

  log "STEP3_MOUNT src=$src_mnt dst=$dst_mnt"

  # Copy files preserving permissions, ownership, timestamps
  if ! cp -a "$src_mnt"/. "$dst_mnt"/ 2>/dev/null; then
    msg_error "Error: File copy failed"
    log "ERROR cp_failed"
    umount "$dst_mnt" 2>/dev/null || true
    umount "$src_mnt" 2>/dev/null || true
    rmdir "$src_mnt" "$dst_mnt" 2>/dev/null || true
    rollback_operation "$ctid" "$disk_key" "$old_vol" "$new_vol"
    return 1
  fi

  umount "$dst_mnt" 2>/dev/null || true
  umount "$src_mnt" 2>/dev/null || true
  rmdir "$src_mnt" "$dst_mnt" 2>/dev/null || true

  msg_ok "Data copied"
  log "STEP3_OK"

  # Step 4: Verify — check file count matches
  msg_info "Step 4/7: Verifying data..."
  log "STEP4_VERIFY"
  mkdir -p "$src_mnt" "$dst_mnt"
  mount -o ro "$source_dev" "$src_mnt" 2>/dev/null
  mount "$dest_dev" "$dst_mnt" 2>/dev/null

  local src_files dst_files
  src_files=$(find "$src_mnt" -type f 2>/dev/null | wc -l)
  dst_files=$(find "$dst_mnt" -type f 2>/dev/null | wc -l)

  umount "$dst_mnt" 2>/dev/null || true
  umount "$src_mnt" 2>/dev/null || true
  rmdir "$src_mnt" "$dst_mnt" 2>/dev/null || true

  if [[ "$src_files" -ne "$dst_files" ]]; then
    msg_error "Error: File count mismatch — source: ${src_files}, dest: ${dst_files}"
    log "ERROR file_count_mismatch src=$src_files dst=$dst_files"
    rollback_operation "$ctid" "$disk_key" "$old_vol" "$new_vol"
    return 1
  fi
  msg_ok "Verified: ${dst_files} files"
  log "STEP4_OK files=$dst_files"

  # Step 5: Replace volume in config
  msg_info "Step 5/7: Replacing volume in config..."
  log "STEP5_REPLACE ctid=$ctid disk=$disk_key new=$new_vol size=$target_size"
  save_rollback_metadata "$ctid" "$disk_key" "$old_vol" "$new_vol" "$current_size"
  replace_volume_in_config "$ctid" "$disk_key" "$new_vol" "$target_size"
  msg_ok "Volume replaced"
  log "STEP5_OK"

  # Step 6: Start container
  msg_info "Step 6/7: Starting container..."
  log "STEP6_STARTING ctid=$ctid"
  start_ct "$ctid"
  msg_ok "Container started"
  log "STEP6_OK"

  # Step 7: Verify health
  msg_info "Step 7/7: Verifying container health..."
  if [[ "$(pct_st "$ctid")" == "status: running" ]]; then
    msg_ok "Container is running"
    log "STEP7_OK status=running"
  else
    msg_error "Warning: Container is not running after start"
    log "STEP7_WARN status=$(pct_st "$ctid")"
  fi

  log "SUCCESS CTID=$ctid DISK_KEY=$disk_key OLD=$current_size NEW=$target_size OLD_VOL=$old_vol NEW_VOL=$new_vol MODE=copy"

  if [[ "${AUTO_ROLLBACK:-0}" -eq 1 ]]; then
    msg_info "Auto-rollback requested, reverting to original..."
    rollback_operation "$ctid" "$disk_key" "$old_vol" "$new_vol"
  else
    post_operation "$ctid" "$disk_key" "$old_vol" "$new_vol"
  fi

  return 0
}

resize_via_dd() {
  local ctid=$1
  local disk_key=$2
  local target_size=$3
  local storage=$4
  local vol_name=$5
  local current_size=$6
  local old_vol="${storage}:${vol_name}"

  msg_info "Using dd copy approach"
  log "MODE=dd old_vol=$old_vol"

  local dest_bytes
  dest_bytes=$(parse_size_to_bytes "$target_size")

  # Step 1: Create new volume of TARGET size
  msg_info "Step 1/7: Creating new volume..."
  log "STEP1_CREATE_VOL ctid=$ctid disk=$disk_key target=$target_size"
  local new_vol
  new_vol=$(create_new_volume "$ctid" "$disk_key" "$target_size")
  if [[ -z "$new_vol" ]]; then
    msg_error "Error: Failed to create new volume"
    log "ERROR create_new_volume failed"
    return 1
  fi
  msg_ok "New volume created: ${new_vol}"
  log "STEP1_OK new_vol=$new_vol"

  # Step 2: Stop the container
  msg_info "Step 2/7: Stopping container..."
  log "STEP2_STOPPING ctid=$ctid"
  stop_ct "$ctid" || {
    rollback_operation "$ctid" "$disk_key" "$old_vol" "$new_vol"
    return 1
  }
  msg_ok "Container stopped"
  log "STEP2_OK"

  # Step 3: Copy data
  msg_info "Step 3/7: Copying data..."
  local source_dev dest_dev
  source_dev=$(get_device_path "$old_vol")
  dest_dev=$(get_device_path "$new_vol")

  if [[ -z "$source_dev" || -z "$dest_dev" ]]; then
    msg_error "Error: Could not resolve device paths"
    msg_error "Source: ${source_dev:-<none>}, Dest: ${dest_dev:-<none>}"
    log "ERROR device_path source=$source_dev dest=$dest_dev"
    rollback_operation "$ctid" "$disk_key" "$old_vol" "$new_vol"
    return 1
  fi

  local source_bytes
  source_bytes=$(get_max_bytes "$ctid" "$disk_key")

  # Pre-dd check: verify used data fits in destination
  local used_bytes
  used_bytes=$(get_used_bytes "$ctid" "$disk_key")
  if ((used_bytes > dest_bytes)); then
    msg_error "Used data ($(bytes_to_human "$used_bytes")) exceeds target size ($(bytes_to_human "$dest_bytes"))"
    log "ERROR used_exceeds_target used=$used_bytes target=$dest_bytes"
    rollback_operation "$ctid" "$disk_key" "$old_vol" "$new_vol"
    return 1
  fi

  echo -e "${TAB}Source: ${source_dev} ($(bytes_to_human "$source_bytes"))"
  echo -e "${TAB}Dest:   ${dest_dev} (${target_size})"
  log "STEP3_COPY src=$source_dev dst=$dest_dev src_bytes=$source_bytes dst_bytes=$dest_bytes"

  # Copy only dest_bytes — dd stops at file boundary
  if ! copy_data "$source_dev" "$dest_dev" "$dest_bytes"; then
    local copy_rc=$?
    msg_error "Error: Data copy failed (exit code: ${copy_rc})"
    msg_error "Source: ${source_dev} ($(bytes_to_human "$source_bytes"))"
    msg_error "Dest: ${dest_dev} (${target_size})"
    log "ERROR copy_data failed src=$source_dev dst=$dest_dev rc=$copy_rc"
    rollback_operation "$ctid" "$disk_key" "$old_vol" "$new_vol"
    return 1
  fi
  msg_ok "Data copied"
  log "STEP3_OK"

  # Step 4: Verify checksum (compare only dest_bytes to avoid size mismatch)
  msg_info "Step 4/7: Verifying checksum..."
  log "STEP4_CHECKSUM src=$source_dev dst=$dest_dev"
  if ! verify_checksum "$source_dev" "$dest_dev" "$dest_bytes"; then
    msg_error "Error: Checksum mismatch — data corruption detected"
    log "ERROR checksum_mismatch"
    rollback_operation "$ctid" "$disk_key" "$old_vol" "$new_vol"
    return 1
  fi
  msg_ok "Checksum verified"
  log "STEP4_OK"

  # Step 5: Replace volume in config
  msg_info "Step 5/7: Replacing volume in config..."
  log "STEP5_REPLACE ctid=$ctid disk=$disk_key new=$new_vol size=$target_size"
  save_rollback_metadata "$ctid" "$disk_key" "$old_vol" "$new_vol" "$current_size"
  replace_volume_in_config "$ctid" "$disk_key" "$new_vol" "$target_size"
  msg_ok "Volume replaced"
  log "STEP5_OK"

  # Step 6: Start container
  msg_info "Step 6/7: Starting container..."
  log "STEP6_STARTING ctid=$ctid"
  start_ct "$ctid"
  msg_ok "Container started"
  log "STEP6_OK"

  # Step 7: Verify health
  msg_info "Step 7/7: Verifying container health..."
  if [[ "$(pct_st "$ctid")" == "status: running" ]]; then
    msg_ok "Container is running"
    log "STEP7_OK status=running"
  else
    msg_error "Warning: Container is not running after start"
    log "STEP7_WARN status=$(pct_st "$ctid")"
  fi

  log "SUCCESS CTID=$ctid DISK_KEY=$disk_key OLD=$current_size NEW=$target_size OLD_VOL=$old_vol NEW_VOL=$new_vol"

  if [[ "${AUTO_ROLLBACK:-0}" -eq 1 ]]; then
    msg_info "Auto-rollback requested, reverting to original..."
    rollback_operation "$ctid" "$disk_key" "$old_vol" "$new_vol"
  else
    post_operation "$ctid" "$disk_key" "$old_vol" "$new_vol"
  fi

  return 0
}

# =============================================================================
# 19. MAIN RESIZE ORCHESTRATOR
# =============================================================================

do_resize() {
  local ctid=$1
  local disk_key=$2
  local target_size=$3

  block_interrupts
  log "START CTID=$ctid DISK_KEY=$disk_key TARGET=$target_size"
  msg_info "Detecting storage type..."

  local storage stype vol_name current_size
  storage=$(get_storage_for_disk "$ctid" "$disk_key")
  stype=$(get_storage_type "$storage")
  vol_name=$(get_volume_name "$ctid" "$disk_key")
  current_size=$(get_size_from_config "$ctid" "$disk_key")

  msg_info "Resizing ${disk_key} on container ${ctid} from ${current_size} to ${target_size}"
  log "INFO storage_type=$stype current_size=$current_size"

  local rc=0

  # Algorithm 1: ZFS refquota
  if [[ "$stype" == "zfspool" ]]; then
    msg_info "Probing ZFS dataset..."
    if resize_zfs_subvol "$ctid" "$disk_key" "$target_size" "$storage" "$vol_name" "$current_size"; then
      allow_interrupts
      return 0
    fi
    msg_info "ZFS zvol or refquota fallback — switching to file copy"
  fi

  # Algorithm 2: ext4 file copy (avoids metadata mismatch)
  local old_vol="${storage}:${vol_name}"
  local source_dev
  source_dev=$(get_device_path "$old_vol")
  if [[ -n "$source_dev" ]] && file "$source_dev" 2>/dev/null | grep -q "ext[234]"; then
    msg_info "Detected ext[234] filesystem — using file copy approach"
    resize_via_copy "$ctid" "$disk_key" "$target_size" "$storage" "$vol_name" "$current_size"
    rc=$?
    allow_interrupts
    return $rc
  fi

  # Algorithm 3: dd copy (fallback for everything else)
  resize_via_dd "$ctid" "$disk_key" "$target_size" "$storage" "$vol_name" "$current_size"
  rc=$?

  allow_interrupts
  return $rc
}

# =============================================================================
# 20. CLI HELP
# =============================================================================

show_help() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Shrink an LXC container disk by creating a smaller copy and swapping volumes.

Options:
  -d, --ctid ID        Container ID
  -k, --disk KEY       Disk key (rootfs, mp0, mp1, ...)
  -s, --size SIZE      Target size (e.g. 8G, 500M, 16)
  -y, --yes            Skip confirmation prompts
  -r, --rollback       Auto-rollback to original after success
  -h, --help           Show this help message

Supported storage: ${SUPPORTED_STORAGE_TYPES}

Examples:
  $(basename "$0")                                  # Interactive mode
  $(basename "$0") -d 900 -k rootfs -s 8G -y       # CLI: shrink rootfs to 8G
  $(basename "$0") -d 900 -k mp0 -s 2G -y -r       # CLI: shrink mp0, rollback after

Interactive mode guides you through container, disk, and size selection.
CLI mode requires --ctid, --disk, and --size.
EOF
}

# =============================================================================
# 21. ENTRY POINT
# =============================================================================

CTID=""
DISK_KEY=""
TARGET_SIZE=""
AUTO_YES=0
AUTO_ROLLBACK=0

while [[ $# -gt 0 ]]; do
  case $1 in
    -d | --ctid) CTID="$2"; shift 2 ;;
    -k | --disk) DISK_KEY="$2"; shift 2 ;;
    -s | --size) TARGET_SIZE="$2"; shift 2 ;;
    -y | --yes) AUTO_YES=1; shift ;;
    -r | --rollback) AUTO_ROLLBACK=1; shift ;;
    -h | --help) show_help; exit 0 ;;
    *) msg_error "Unknown option: $1"; exit 1 ;;
  esac
done

CLI_MODE=0
[[ -n "$CTID" && -n "$DISK_KEY" && -n "$TARGET_SIZE" ]] && CLI_MODE=1

header_info

if [[ $CLI_MODE -eq 1 ]]; then
  [[ "$TARGET_SIZE" =~ ^[0-9]+$ ]] && TARGET_SIZE="${TARGET_SIZE}G"

  if ! validate_inputs "$CTID" "$DISK_KEY" "$TARGET_SIZE"; then
    exit 1
  fi

  [[ $AUTO_YES -eq 0 ]] && confirm_operation "$CTID" "$DISK_KEY" "$TARGET_SIZE"

  do_resize "$CTID" "$DISK_KEY" "$TARGET_SIZE"
  exit $?
fi

# Interactive mode
CTID=$(select_container) || exit 0
[[ -z "$CTID" ]] && exit 0
DISK_KEY=$(select_disk "$CTID") || exit 0
DISK_KEY=$(printf '%s' "$DISK_KEY" | tr -d "'\"[:space:]")
[[ -z "$DISK_KEY" ]] && exit 0
TARGET_SIZE=$(get_target_size "$CTID" "$DISK_KEY") || exit 0
[[ -z "$TARGET_SIZE" ]] && exit 0
confirm_operation "$CTID" "$DISK_KEY" "$TARGET_SIZE" || exit 0
do_resize "$CTID" "$DISK_KEY" "$TARGET_SIZE"
