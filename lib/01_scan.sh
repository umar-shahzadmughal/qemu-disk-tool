human_lsblk() {
  hr
  echo "🔍 Storage Inventory"
  hr

  local lsblk_data
  lsblk_data="$(lsblk -pbPo NAME,TYPE,SIZE,MODEL,SERIAL,PTTYPE,FSTYPE,MOUNTPOINTS,LABEL,PKNAME 2>/dev/null)" || {
    warn "Failed to query block devices."
    return 1
  }

  declare -A dev_type dev_size dev_model dev_serial dev_pttype dev_fstype dev_mount dev_label
  declare -a disk_list=()
  declare -A disk_parts=()

  local line rest key val name
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    name=""; local type="" size="" model="" serial="" pttype="" fstype="" mount="" label="" pkname=""
    rest="$line"
    while [[ "$rest" =~ ^([A-Z]+)=\"([^\"]*)\"[[:space:]]*(.*)$ ]]; do
      key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"; rest="${BASH_REMATCH[3]}"
      val="${val//\\\"/\"}"; val="${val//\\\\/\\}"
      case "$key" in
        NAME)  name="$val" ;;   TYPE)  type="$val" ;;   SIZE)  size="$val" ;;
        MODEL) model="$val" ;;  SERIAL) serial="$val" ;; PTTYPE) pttype="$val" ;;
        FSTYPE) fstype="$val" ;; MOUNTPOINTS) mount="$val" ;; LABEL) label="$val" ;;
        PKNAME) pkname="$val" ;;
      esac
    done
    [[ -n "$name" ]] || continue

    dev_type["$name"]="$type";  dev_size["$name"]="$size"
    dev_model["$name"]="$model"; dev_serial["$name"]="$serial"
    dev_pttype["$name"]="$pttype"; dev_fstype["$name"]="$fstype"
    dev_mount["$name"]="$mount";  dev_label["$name"]="$label"

    if [[ "$type" == "disk" && ! "$name" =~ ^/dev/(loop|nbd|sr[0-9]|zram|ram|nullb) ]]; then
      disk_list+=("$name")
    elif [[ -n "$pkname" ]]; then
      disk_parts["/dev/${pkname#/dev/}"]+="$name "
    fi
  done <<< "$lsblk_data"

  ((${#disk_list[@]} == 0)) && { warn "No physical disks found."; return; }

  # Collect unique mount points → single df call
  local -a mount_list=()
  for dev_name in "${!dev_mount[@]}"; do
    local -a mm=()
    read -ra mm <<< "${dev_mount[$dev_name]}"
    for mnt in "${mm[@]}"; do
      [[ " ${mount_list[@]} " =~ " $mnt " ]] || mount_list+=("$mnt")
    done
  done
  
  # Get df stats — use awk for reliable field extraction
  declare -A df_used_k df_avail_k df_pct_num
  if ((${#mount_list[@]} > 0)); then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local used_k avail_k pct_num mnt
      read -r used_k avail_k pct_num mnt <<< "$(echo "$line" | awk '{
        gsub(/%/,"",$5);
        mnt=""; for(i=6;i<=NF;i++) mnt=(mnt=="" ? $i : mnt " " $i);
        print $3, $4, $5, mnt
      }')"
      [[ "$pct_num" =~ ^[0-9]+$ ]] || continue
      [[ -n "$mnt" ]] && {
        df_used_k["$mnt"]="$used_k"
        df_avail_k["$mnt"]="$avail_k"
        df_pct_num["$mnt"]="$pct_num"
      }
    done < <(df -k -- "${mount_list[@]}" 2>/dev/null | tail -n +2)
  fi

  # First pass: calculate max widths (auto-fit ANY drive set + terminal)
  local cols="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  local max_part_w=0 max_size_w=0 max_fs_w=0 max_mount_w=0 max_label_w=0
  local all_parts=()

  for disk in "${disk_list[@]}"; do
    local -a parts=()
    read -ra parts <<< "${disk_parts[$disk]:-}"
    IFS=$'\n' parts=($(sort -V <<< "${parts[*]}")); unset IFS
    local p
    for p in "${parts[@]}"; do
      [[ -n "$p" ]] && all_parts+=("$p")
    done
  done

  for part in "${all_parts[@]}"; do
    local pname="${part##*/}"
    local psize_hr; psize_hr="$(numfmt --to=iec --format=%.1f "${dev_size[$part]}" 2>/dev/null || echo "${dev_size[$part]}")"
    local pfstype="${dev_fstype[$part]:--}"
    local pfstype_upper="${pfstype^^}"
    local primary_mount; read -r primary_mount _ <<< "${dev_mount[$part]}"
    local plabel="${dev_label[$part]}"

    (( ${#pname} > max_part_w )) && max_part_w=${#pname}
    (( ${#psize_hr} > max_size_w )) && max_size_w=${#psize_hr}
    (( ${#pfstype_upper} > max_fs_w )) && max_fs_w=${#pfstype_upper}
    (( ${#primary_mount} > max_mount_w )) && max_mount_w=${#primary_mount}
    (( ${#plabel} > max_label_w )) && max_label_w=${#plabel}
  done

  # Padding
  (( max_part_w += 1 )); (( max_size_w += 1 )); (( max_fs_w += 1 ))
  (( max_mount_w += 1 )); (( max_label_w += 2 ))

  # Auto-fit: if the full line would overflow, shrink mount/label
  local usage_w=36
  local fixed=$(( 5 + 3 + usage_w + max_part_w + max_size_w + max_fs_w + 3 ))
  local room=$(( cols - fixed ))
  (( room < 16 )) && room=16
  if (( max_mount_w + max_label_w > room )); then
    local lbl_w=$(( max_label_w < room / 3 ? max_label_w : room / 3 ))
    (( lbl_w < 4 )) && lbl_w=4
    max_mount_w=$(( room - lbl_w ))
    max_label_w=$lbl_w
  fi

  local GRN=$'\033[0;32m' RST=$'\033[0m'

  local total_size=0
  for disk in "${disk_list[@]}"; do
    local model="${dev_model[$disk]}" serial="${dev_serial[$disk]}"
    local size="${dev_size[$disk]}"  pt_type="${dev_pttype[$disk]}"

    local size_hr; size_hr="$(numfmt --to=iec --format=%.1f "$size" 2>/dev/null || echo "$size")"
    (( total_size += size ))

    local pt_label
    case "$pt_type" in
      gpt) pt_label="GPT" ;; dos) pt_label="MBR" ;; "") pt_label="Raw" ;; *) pt_label="$pt_type" ;;
    esac

    model="${model#"${model%%[![:space:]]*}"}"; model="${model%"${model##*[![:space:]]}"}"
    serial="${serial#"${serial%%[![:space:]]*}"}"; serial="${serial%"${serial##*[![:space:]]}"}"

    echo
    echo "  💽 ${disk##*/}  │  $size_hr  │  $pt_label  │  ${model:-Unknown}"
    [[ -n "$serial" ]] && echo "     └─ S/N: $serial"

    local -a parts=()
    read -ra parts <<< "${disk_parts[$disk]:-}"
    if ((${#parts[@]} == 0)); then
      echo "     └─ (no partitions)"
      continue
    fi
    IFS=$'\n' parts=($(sort -V <<< "${parts[*]}")); unset IFS

    local idx=0 total=${#parts[@]} part
    for part in "${parts[@]}"; do
      [[ -z "$part" ]] && continue
      idx=$((idx + 1))
      local connector="├─"; [[ $idx -eq $total ]] && connector="└─"

      local pname="${part##*/}"
      local psize_hr; psize_hr="$(numfmt --to=iec --format=%.1f "${dev_size[$part]}" 2>/dev/null || echo "${dev_size[$part]}")"
      local pfstype="${dev_fstype[$part]:--}" plabel="${dev_label[$part]}"
      local pfstype_disp="${pfstype^^}"
      local primary_mount; read -r primary_mount _ <<< "${dev_mount[$part]}"

      # Truncate long values so columns never overflow
      local mount_disp="${primary_mount:--}"
      (( ${#mount_disp} > max_mount_w )) && mount_disp="${mount_disp:0:$((max_mount_w-1))}…"

      # Usage bar + green free space (pure $'...' variables, no %b needed)
      local usage=""
      if [[ -n "$primary_mount" && -n "${df_pct_num[$primary_mount]:-}" ]]; then
        local pct_num="${df_pct_num[$primary_mount]}"
        local avail_k="${df_avail_k[$primary_mount]}"

        local avail_hr
        avail_hr="$(numfmt --to=iec --from-unit=1024 "$avail_k" 2>/dev/null || echo "${avail_k}K")"

        local bw=10
        local filled=$((pct_num * bw / 100))
        local empty=$((bw - filled))
        local bar_fill="" bar_empty="" i
        for ((i=0; i<filled; i++)); do bar_fill+="█"; done
        for ((i=0; i<empty; i++)); do bar_empty+="░"; done

        usage="[${bar_fill}${bar_empty}] ${pct_num}% used, ${GRN}${avail_hr} free${RST}"
      fi

      local fs_icon
      case "$pfstype" in
        ext4|ext3|ext2) fs_icon="🐧" ;; ntfs) fs_icon="🪟" ;; vfat|fat32) fs_icon="⚙️" ;;
        swap) fs_icon="🔄" ;; crypto_LUKS) fs_icon="🔒" ;; LVM2_member) fs_icon="📦" ;;
        zfs_member) fs_icon="🗄️" ;; btrfs) fs_icon="🌳" ;; xfs) fs_icon="⚡" ;;
        *) fs_icon="  " ;;
      esac

      local label_str="-"
      [[ -n "$plabel" ]] && label_str="\"$plabel\""
      (( ${#label_str} > max_label_w )) && label_str="${label_str:0:$((max_label_w-1))}…"

      # Icon LAST → emoji cell-width can't shift the bar column
      printf "     %s %-${max_part_w}s %-${max_size_w}s %-${max_fs_w}s %-${max_mount_w}s %-${max_label_w}s %s %s\n" \
        "$connector" "$pname" "$psize_hr" "$pfstype_disp" "$mount_disp" "$label_str" "$usage" "$fs_icon"
    done
  done

  echo
  hr
  local total_hr; total_hr="$(numfmt --to=iec --format=%.1f "$total_size" 2>/dev/null || echo "$total_size")"
  echo "  📊 ${#disk_list[@]} disk(s) detected │ Total: $total_hr"
  hr
}