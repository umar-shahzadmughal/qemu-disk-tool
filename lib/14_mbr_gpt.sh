# ============================================================
# Option 14: MBR/GPT Conversion
# Uses sgdisk to convert partition tables between MBR and GPT
# WARNING: This modifies the partition table structure
# ============================================================
mbr_gpt_convert() {
  hr
  echo "🔄 MBR/GPT Partition Table Conversion"
  hr

  if ! command -v sgdisk >/dev/null 2>&1; then
    die "sgdisk not found. Install: sudo apt install gdisk"
  fi

  local disk
  disk="$(pick_block_device disk)"
  maybe_unmount "$disk"

  local current_type
  current_type="$(lsblk -no PTTYPE "$disk" 2>/dev/null | head -n1)"

  echo
  log "Current partition table: ${current_type:-none}"
  echo

  # ── No partition table ──
  if [[ -z "$current_type" ]]; then
    warn "No partition table detected on $disk."
    local create_ans
    create_ans="$(ask_yesno "Create a new GPT partition table?" "N")"
    [[ "$create_ans" == "true" ]] || die "Cancelled."
    sgdisk --zap-all "$disk"
    success "GPT partition table created (empty)."
    pause
    return
  fi

  # ── Ask which format ──
  echo "  Which format do you want?"
  echo
  echo "  [1] 📋 GPT  (Modern, supports >2TB, UEFI boot)"
  echo "  [2] 📋 MBR  (Legacy, max 2TB, BIOS boot)"
  echo
  local target_fmt
  read -rp "➡️  Enter choice (1-2): " target_fmt <"$TTY"

  local target_type
  case "$target_fmt" in
    1) target_type="gpt" ;;
    2) target_type="dos" ;;
    *) die "Invalid choice." ;;
  esac

  # ── Already in target format ──
  if [[ "$current_type" == "$target_type" ]]; then
    echo
    if [[ "$target_type" == "gpt" ]]; then
      success "This disk is ALREADY GPT."
      echo
      echo "  💡 Tip: If the GPT backup header is damaged, run Option 15 (Repair)."
      echo "     Or use: sudo sgdisk -e $disk  (relocates backup to end of disk)"
    else
      success "This disk is ALREADY MBR."
    fi
    echo
    pause
    return
  fi

  # ── Show conversion direction ──
  echo
  if [[ "$target_type" == "gpt" ]]; then
    warn "You are converting MBR → GPT."
    warn "This is generally safe but changes the partition table format."

    # ── Pre-check: GPT needs 33 sectors (16.5KB) at end of disk ──
    local disk_bytes last_part
    disk_bytes="$(blockdev --getsize64 "$disk" 2>/dev/null || echo 0)"
    last_part="$(lsblk -nrpo NAME,TYPE "$disk" | awk '$2=="part"{print $1}' | tail -n1)"

    if [[ -b "$last_part" && "$disk_bytes" -gt 0 ]]; then
      local part_start_sectors part_size_bytes part_end_bytes
      part_start_sectors="$(lsblk -nrno START "$last_part" | tail -n1)"
      part_size_bytes="$(lsblk -bno SIZE "$last_part" | tail -n1)"
      part_end_bytes=$(( (part_start_sectors * 512) + part_size_bytes ))
      local gap_bytes=$((disk_bytes - part_end_bytes))

      if (( gap_bytes < 2097152 )); then
        echo
        warn "The last partition ($last_part) touches the end of the disk."
        warn "GPT requires empty space at the end for its backup header."
        echo
        local shrink_ans
        read -rp "🔧 Shrink $last_part by 2MB to make room? (Y/n): " shrink_ans <"$TTY"
        shrink_ans="${shrink_ans:-Y}"
        if [[ "${shrink_ans,,}" != "y" && "${shrink_ans,,}" != "yes" ]]; then
          die "Cannot convert to GPT without free space at the end of the disk."
        fi

        local fstype new_part_bytes part_num
        fstype="$(lsblk -no FSTYPE "$last_part" 2>/dev/null | head -n1)"
        new_part_bytes=$((part_size_bytes - 2097152))
        part_num="$(echo "$last_part" | grep -o '[0-9]*$')"

        maybe_unmount "$last_part"

        log "Shrinking filesystem on $last_part …"
        if [[ "$fstype" =~ ^(ext2|ext3|ext4)$ ]]; then
          local new_fs_blocks=$((new_part_bytes / 4096))
          e2fsck -f -y "$last_part" 2>&1 || true
          resize2fs "$last_part" "${new_fs_blocks}" 2>&1 || true
        elif [[ "$fstype" == "ntfs" ]]; then
          ntfsresize --size "$new_part_bytes" "$last_part" 2>&1 || true
        fi

        log "Shrinking partition table entry…"
        parted -s "$disk" resizepart "$part_num" "${new_part_bytes}B" 2>&1 || true
        partprobe "$disk" 2>/dev/null || true
        sleep 1
        success "Last partition shrunk by 2MB."
        echo
      fi
    fi

  else
    warn "You are converting GPT → MBR."
    warn "⚠️  This may fail if you have more than 4 primary partitions"
    warn "   or partitions larger than 2TB."

    # ── Pre-check: MBR max 4 primary partitions ──
    local part_count
    part_count="$(lsblk -nrpo NAME,TYPE "$disk" | awk '$2=="part"' | wc -l)"
    if (( part_count > 4 )); then
      echo
      err "This disk has $part_count partitions. MBR supports max 4 primary."
      die "Cannot convert to MBR. Remove partitions or use GPT."
    fi
  fi

  # ── Show layout ──
  echo
  echo "📌 Current partition layout:"
  lsblk -o NAME,TYPE,SIZE,FSTYPE "$disk" 2>/dev/null | sed 's/\\x20/ /g' || true
  echo

  # ── Confirmation ──
  hr
  echo "🔥 WARNING: Partition Table Conversion"
  echo "   Disk:    $disk"
  echo "   Current: $current_type"
  echo "   Target:  $target_type"
  echo
  warn "This operation modifies the partition table."
  warn "While it attempts to preserve partitions, BACKUP YOUR DATA FIRST."
  hr

  echo "To continue, type the target EXACTLY:"
  echo "   (type 'cancel' or press Enter with no input to abort)"
  echo "   $disk"
  while true; do
    read -rp "✍️  Type target path: " confirm1 <"$TTY"
    if [[ "$confirm1" == "$disk" ]]; then
      break
    elif [[ "${confirm1,,}" == "cancel" || "${confirm1,,}" == "q" || "${confirm1,,}" == "c" || -z "$confirm1" ]]; then
      die "Aborted by user."
    else
      warn "Mismatch! Please type exactly: $disk"
    fi
  done

  echo
  echo "Final confirmation. Type CONVERT:"
  echo "   (type 'cancel' or press Enter with no input to abort)"
  while true; do
    read -rp "✍️  Type CONVERT: " confirm2 <"$TTY"
    if [[ "$confirm2" == "CONVERT" ]]; then
      break
    elif [[ "${confirm2,,}" == "cancel" || "${confirm2,,}" == "q" || "${confirm2,,}" == "c" || -z "$confirm2" ]]; then
      die "Aborted by user."
    else
      warn "Mismatch! You must type exactly: CONVERT"
    fi
  done

  # ── Convert ──
  log "Converting partition table…"

  if [[ "$target_type" == "dos" ]]; then
    sgdisk --gpttombr "$disk" || {
      err "Conversion failed."
      warn "Try running Option 15 (Repair) to fix any issues."
      die "MBR conversion failed."
    }
    success "Converted GPT → MBR"
  else
    sgdisk --mbrtogpt "$disk" || {
      err "Conversion failed."
      warn "Try running Option 15 (Repair) to fix any issues."
      die "GPT conversion failed."
    }
    success "Converted MBR → GPT"
  fi

  partprobe "$disk" 2>/dev/null || true
  sleep 1

  echo
  log "New partition layout:"
  lsblk -o NAME,TYPE,SIZE,FSTYPE "$disk" 2>/dev/null | sed 's/\\x20/ /g' || true
  echo
  info "💡 Tip: Run Option 15 (Repair) to verify filesystem integrity after conversion."
  _write_log "CONVERT" "$disk: $current_type → $target_type"
  pause
}