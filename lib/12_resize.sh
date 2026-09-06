# ============================================================
# Option 12: Resize/Shrink Image
# Supports: Virtual shrink, Actual file compaction, or Both
# Uses: Square Root + User Profile strategy for size recommendation
# Supports: ext2/3/4 (resize2fs), NTFS (ntfsresize)
# ============================================================
resize_image() {
  hr
  echo "📏 Resize / Shrink Image"
  hr

  local img block_size=""
  img="$(ask_path_existing_file "📥 Enter image path to resize: ")"

  # ── Show current info ──
  local fmt vsize old_file_size
  fmt="$(detect_img_format "$img")"
  vsize="$(img_virtual_bytes "$img")"
  old_file_size="$(stat -c '%s' "$img" 2>/dev/null || echo 0)"

  echo
  log "Current image info:"
  echo "   Format:          $fmt"
  echo "   Virtual size:    $(numfmt --to=iec "$vsize")"
  echo "   Actual file size: $(numfmt --to=iec "$old_file_size")"
  echo

  if [[ "$fmt" != "qcow2" && "$fmt" != "raw" ]]; then
    die "Only qcow2 and raw images can be resized. Current format: $fmt"
  fi

  # ── Ask: Virtual / Actual / Both ──
  echo "📏 What kind of shrink do you want to perform?"
  echo
  echo "  [1] 📉 Shrink VIRTUAL Size (Internal Partitions)"
  echo "      Benefit: Allows restore to a physically smaller drive (Option 6)."
  echo "      Action:  Shrinks filesystem and partition table inside the image."
  echo
  echo "  [2] 🗜️  Shrink ACTUAL File Size (Host Disk Space)"
  echo "      Benefit: Frees up space on your physical hard drive."
  echo "      Action:  Zeroes out empty space and compacts the file."
  echo
  echo "  [3] 🔄 Do BOTH (Virtual first, then Actual)"
  echo
  read -rp "➡️  Enter choice (1-3): " mode <"$TTY"

  local do_virtual=false do_actual=false
  case "$mode" in
    1) do_virtual=true ;;
    2)
      if [[ "$fmt" == "raw" ]]; then
        die "Actual-only compaction is not supported for raw images. Use Option 1 (Virtual) instead."
      fi
      do_actual=true
      ;;
    3)
      do_virtual=true
      do_actual=true
      ;;
    *) die "Invalid choice." ;;
  esac

  local nbd new_vsize="$vsize"

  # ══════════════════════════════════════════════════════════
  # PHASE 1: VIRTUAL SHRINK
  # ══════════════════════════════════════════════════════════
  if [[ "$do_virtual" == "true" ]]; then
    echo
    hr
    echo "📉 Phase 1: Virtual Shrink"
    hr

    # Connect image via nbd
    nbd="$(pick_free_nbd)"
    log "Using $nbd"
    USED_NBDS+=("$nbd")
    qemu-nbd --connect="$nbd" "$img"
    partprobe "$nbd" 2>/dev/null || true
    sleep 1

    # Detect partitions
    local parts=()
    while IFS= read -r p; do
      [[ -b "$p" ]] && parts+=("$p")
    done < <(lsblk -nrpo NAME,TYPE "$nbd" | awk '$2=="part"{print $1}')

    if ((${#parts[@]} == 0)); then
      qemu-nbd --disconnect "$nbd" 2>/dev/null || true
      die "No partitions found in image. Cannot resize."
    fi

    echo "📦 Partitions found:"
    for i in "${!parts[@]}"; do
      local info
      info="$(lsblk -no SIZE,FSTYPE "${parts[$i]}" 2>/dev/null | sed 's/[[:space:]]\+/ /g')"
      echo "  [$((i+1))] ${parts[$i]} ($info)"
    done
    echo

    # User selects partition
    local sel
    read -rp "➡️  Select partition to shrink (1-${#parts[@]}): " sel <"$TTY"
    [[ "$sel" =~ ^[0-9]+$ ]] || { qemu-nbd --disconnect "$nbd"; die "Invalid selection."; }
    (( sel>=1 && sel<=${#parts[@]} )) || { qemu-nbd --disconnect "$nbd"; die "Out of range."; }

    local target_part="${parts[$((sel-1))]}"
    local part_num
    part_num="$(echo "$target_part" | grep -o '[0-9]*$')"
    local fstype
    fstype="$(lsblk -no FSTYPE "$target_part" 2>/dev/null | head -n1)"
    log "Selected: $target_part (filesystem: $fstype)"

    # Check filesystem support
    case "$fstype" in
      ext4|ext3|ext2)
        command -v resize2fs >/dev/null 2>&1 || { qemu-nbd --disconnect "$nbd"; die "resize2fs not found. Install: sudo apt install e2fsprogs"; }
        ;;
      ntfs)
        command -v ntfsresize >/dev/null 2>&1 || { qemu-nbd --disconnect "$nbd"; die "ntfsresize not found. Install: sudo apt install ntfs-3g"; }
        warn "⚠️  Shrinking NTFS from Linux is risky. Backup your data first!"
        local ntfs_ans
        ntfs_ans="$(ask_yesno "Continue with NTFS shrink?" "N")"
        [[ "$ntfs_ans" == "true" ]] || { qemu-nbd --disconnect "$nbd"; die "Cancelled."; }
        ;;
      *)
        qemu-nbd --disconnect "$nbd" 2>/dev/null || true
        die "Filesystem '$fstype' cannot be shrunk. Supported: ext2/3/4, ntfs."
        ;;
    esac

    # ── Scan filesystem → calculate used data ──
    echo
    log "📊 Scanning filesystem to calculate used data…"

    local min_bytes=0
    local part_total_bytes
    part_total_bytes="$(blockdev --getsize64 "$target_part" 2>/dev/null || echo 0)"

    case "$fstype" in
      ext4|ext3|ext2)
        local min_blocks
        block_size="$(dumpe2fs -h "$target_part" 2>/dev/null | grep "Block size" | awk '{print $3}')"
        min_blocks="$(resize2fs -P "$target_part" 2>/dev/null | awk '{print $NF}')"
        [[ -z "$min_blocks" || -z "$block_size" ]] && { qemu-nbd --disconnect "$nbd"; die "Cannot read filesystem info."; }
        min_bytes=$((min_blocks * block_size))
        ;;
      ntfs)
        local ntfs_used
        ntfs_used="$(ntfsresize --info "$target_part" 2>/dev/null | grep -o 'at [0-9]* bytes' | grep -o '[0-9]*')"
        [[ -z "$ntfs_used" ]] && { qemu-nbd --disconnect "$nbd"; die "Cannot read NTFS info."; }
        min_bytes="$ntfs_used"
        ;;
    esac

    local min_display
    min_display="$(numfmt --to=iec "$min_bytes")"

    echo "   Total partition size:  $(numfmt --to=iec "$part_total_bytes")"
    echo "   Used data + metadata:  $(numfmt --to=iec "$min_bytes")"
    echo "   Minimum safe size:     $min_display"
    echo

    # ── Calculate recommended size (Square Root strategy) ──
    local used_gb=$((min_bytes / 1073741824))
    ((used_gb < 1)) && used_gb=1

    # Integer square root
    local sqrt_val=1
    while ((sqrt_val * sqrt_val <= used_gb)); do
      sqrt_val=$((sqrt_val + 1))
    done
    sqrt_val=$((sqrt_val - 1))
    ((sqrt_val < 1)) && sqrt_val=1

    local base_extra_gb=$sqrt_val

    # ── User Profile selection ──
    local minimal_bytes=$((min_bytes + base_extra_gb * 1073741824))
    local standard_bytes=$((min_bytes + base_extra_gb * 3 * 1073741824))
    local generous_bytes=$((min_bytes + base_extra_gb * 5 * 1073741824))

    echo "📏 Choose how much extra space the VM should have:"
    echo
    echo "  [1] 🔒 Minimal     → +${base_extra_gb} GB  (base × 1)  → Total: $(numfmt --to=iec "$minimal_bytes")"
    echo "      Best for: Read-only VMs, testing, archives"
    echo
    echo "  [2] 🖥️  Standard    → +$((base_extra_gb * 3)) GB  (base × 3)  → Total: $(numfmt --to=iec "$standard_bytes")  ⭐ Recommended"
    echo "      Best for: Normal desktop/server use"
    echo
    echo "  [3] 📈 Generous    → +$((base_extra_gb * 5)) GB  (base × 5)  → Total: $(numfmt --to=iec "$generous_bytes")"
    echo "      Best for: Databases, heavy growth, frequent updates"
    echo
    echo "  [4] ✏️  Custom      → Enter your own size (must be ≥ $min_display)"
    echo
    read -rp "➡️  Enter choice (1-4): " profile <"$TTY"

    local new_size_bytes=0
    case "$profile" in
      1) new_size_bytes="$minimal_bytes" ;;
      2) new_size_bytes="$standard_bytes" ;;
      3) new_size_bytes="$generous_bytes" ;;
      4)
        while true; do
          local custom_size
          read -rp "📏 Enter custom size (e.g., 30G, 50G): " custom_size <"$TTY"
          if [[ "$custom_size" =~ ^[0-9]+[bBkKmMgGtTpPeE]?$ ]]; then
            new_size_bytes="$(numfmt --from=iec "$custom_size" 2>/dev/null || echo 0)"
            if ((new_size_bytes < min_bytes)); then
              warn "Size too small. Minimum safe size is $min_display. Try again."
            else
              break
            fi
          else
            warn "Invalid format. Use numbers followed by K, M, G, or T."
          fi
        done
        ;;
      *) qemu-nbd --disconnect "$nbd" 2>/dev/null || true; die "Invalid choice." ;;
    esac

    local new_size_display
    new_size_display="$(numfmt --to=iec "$new_size_bytes")"
    log "New partition size: $new_size_display"

    # ── Shrink filesystem with progress ──
    echo
    log "Shrinking filesystem on $target_part to $new_size_display …"
    echo "   ⏳ This may take several minutes. Progress is shown below."
    echo

    case "$fstype" in
      ext4|ext3|ext2)
        local fs_block_size="${block_size:-4096}"
        local new_blocks=$((new_size_bytes / fs_block_size))

        # Check if filesystem is already at or below target size
        local current_fs_blocks
        current_fs_blocks="$(dumpe2fs -h "$target_part" 2>/dev/null | grep "Block count" | awk '{print $3}')" || true

        if [[ -n "$current_fs_blocks" ]] && ((current_fs_blocks <= new_blocks)); then
          log "Filesystem already at optimal size ($(numfmt --to=iec $((current_fs_blocks * fs_block_size)))). Skipping shrink."
        else
          # Fix inconsistencies first (-f force, -y yes-to-all; do NOT use -p with -y)
          e2fsck -f -y "$target_part" 2>/dev/null || true

          resize2fs -p "$target_part" "$new_blocks" || {
            qemu-nbd --disconnect "$nbd" 2>/dev/null || true
            die "resize2fs failed."
          }
          success "Filesystem shrunk successfully."
        fi
        ;;
      ntfs)
        ntfsresize --size "$new_size_bytes" "$target_part" || {
          qemu-nbd --disconnect "$nbd" 2>/dev/null || true
          die "ntfsresize failed."
        }
        success "Filesystem shrunk successfully."
        ;;
    esac

    # ── Shrink partition table (intelligent method) ──
    local pt_type resize_ok=false
    pt_type="$(lsblk -no PTTYPE "$nbd" 2>/dev/null | head -n1)"

    local current_part_bytes
    current_part_bytes="$(blockdev --getsize64 "$target_part" 2>/dev/null || echo 0)"

    if ((current_part_bytes <= new_size_bytes)); then
      log "Partition already at optimal size ($(numfmt --to=iec "$current_part_bytes")). Skipping shrink."
      resize_ok=true
    else
      log "Shrinking partition table…"

      if [[ "$pt_type" == "gpt" ]] && command -v sgdisk >/dev/null 2>&1; then
        # ── GPT: use sgdisk ──
        log "Using sgdisk for GPT partition resize…"
        local start_sector
        start_sector="$( (sgdisk -i "$part_num" "$nbd" 2>/dev/null || true) | grep "First sector" | awk '{print $3}')" || true

        if [[ -n "$start_sector" ]]; then
          sgdisk -d "$part_num" "$nbd" 2>/dev/null || true
          sgdisk -n "${part_num}:${start_sector}:+${new_size_bytes}" "$nbd" 2>/dev/null && resize_ok=true
        fi

      elif [[ "$pt_type" == "dos" ]]; then
        # ── MBR: use sfdisk ──
        log "Using sfdisk for MBR partition resize…"
        local part_basename start_sector
        part_basename="$(basename "$target_part")"
        start_sector="$(cat "/sys/class/block/${part_basename}/start" 2>/dev/null)" || true

        if [[ -n "$start_sector" ]]; then
          log "  Start sector: $start_sector"
          local new_size_sectors=$((new_size_bytes / 512))

          local boot_flag
          boot_flag="$( (parted -s "$nbd" print 2>/dev/null || true) | awk -v p="$part_num" '$1==p {for(i=1;i<=NF;i++) if($i=="boot") print "boot"}')" || true

          echo "start=${start_sector}, size=${new_size_sectors}, type=83" | sfdisk --force -N "$part_num" "$nbd" 2>/dev/null && resize_ok=true

          if [[ "$resize_ok" == "true" && "$boot_flag" == "boot" ]]; then
            parted -s "$nbd" set "$part_num" boot on 2>/dev/null || true
          fi
        else
          warn "  Could not detect start sector. Trying resizepart fallback…"
          parted -s "$nbd" resizepart "$part_num" "${new_size_bytes}B" 2>/dev/null && resize_ok=true || true
        fi

      else
        # ── Fallback: parted resizepart ──
        log "Using parted resizepart (fallback)…"
        parted -s "$nbd" resizepart "$part_num" "${new_size_bytes}B" 2>/dev/null && resize_ok=true || true
      fi
    fi

    if [[ "$resize_ok" == "true" ]]; then
      success "Partition table OK."
    else
      warn "Partition resize may have issues. Please verify manually."
    fi

    partprobe "$nbd" 2>/dev/null || true
    sleep 1

    # ── Zero out free space (if doing Both, do it now while connected) ──
    if [[ "$do_actual" == "true" ]]; then
      echo
      log "Zeroing out free space for file compaction…"
      for zp in "${parts[@]}"; do
        local zfstype
        zfstype="$(lsblk -no FSTYPE "$zp" 2>/dev/null | head -n1)"
        local zmnt
        zmnt="$(mktemp -d)"
        if mount -o rw "$zp" "$zmnt" 2>/dev/null; then
          log "  Zeroing free space on $zp (this may take a while)…"
          dd if=/dev/zero of="$zmnt/.zero_fill" bs=1M status=progress || true
          rm -f "$zmnt/.zero_fill"
          sync
          umount "$zmnt" 2>/dev/null || true
        fi
        rmdir "$zmnt" 2>/dev/null || true
      done
      success "Free space zeroed."
    fi

    # Disconnect nbd
    qemu-nbd --disconnect "$nbd" 2>/dev/null || true
    local tmp_nbds=() x
    for x in "${USED_NBDS[@]}"; do
      [[ "$x" == "$nbd" ]] && continue
      tmp_nbds+=("$x")
    done
    USED_NBDS=("${tmp_nbds[@]}")

    # Shrink qcow2 virtual size
    if [[ "$fmt" == "qcow2" ]]; then
      local current_vsize
      current_vsize="$(img_virtual_bytes "$img" 2>/dev/null || echo 0)"
      if ((current_vsize <= new_size_bytes)); then
        log "Virtual size already at optimal size ($(numfmt --to=iec "$current_vsize")). Skipping."
      else
        log "Shrinking qcow2 virtual size…"
        qemu-img resize --shrink "$img" "$new_size_bytes" || {
          warn "qcow2 virtual size shrink failed."
        }
      fi
    fi

    new_vsize="$new_size_bytes"
    success "Virtual shrink complete."
  fi

  # ══════════════════════════════════════════════════════════
  # PHASE 2: ACTUAL FILE SHRINK (Compaction)
  # ══════════════════════════════════════════════════════════
  if [[ "$do_actual" == "true" ]]; then
    echo
    hr
    echo "🗜️  Phase 2: Actual File Shrink (Compaction)"
    hr

    # If Actual Only (no virtual shrink was done), we need to zero out free space
    if [[ "$do_virtual" == "false" ]]; then
      nbd="$(pick_free_nbd)"
      log "Using $nbd"
      USED_NBDS+=("$nbd")
      qemu-nbd --connect="$nbd" "$img"
      partprobe "$nbd" 2>/dev/null || true
      sleep 1

      local parts=()
      while IFS= read -r p; do
        [[ -b "$p" ]] && parts+=("$p")
      done < <(lsblk -nrpo NAME,TYPE "$nbd" | awk '$2=="part"{print $1}')

      if ((${#parts[@]} > 0)); then
        log "Zeroing out free space in all partitions…"
        for zp in "${parts[@]}"; do
          local zmnt
          zmnt="$(mktemp -d)"
          if mount -o rw "$zp" "$zmnt" 2>/dev/null; then
            log "  Zeroing free space on $zp (this may take a while)…"
            dd if=/dev/zero of="$zmnt/.zero_fill" bs=1M status=progress || true
            rm -f "$zmnt/.zero_fill"
            sync
            umount "$zmnt" 2>/dev/null || true
          fi
          rmdir "$zmnt" 2>/dev/null || true
        done
        success "Free space zeroed."
      fi

      qemu-nbd --disconnect "$nbd" 2>/dev/null || true
      local tmp_nbds=() x
      for x in "${USED_NBDS[@]}"; do
        [[ "$x" == "$nbd" ]] && continue
        tmp_nbds+=("$x")
      done
      USED_NBDS=("${tmp_nbds[@]}")
    fi

    # Ask where to save the new compact file
    echo
    log "📦 Creating new compact image…"

    local dst=""
    local outdir
    outdir="$(dirname "$img")"
    local default_name
    default_name="$(basename "$img")"
    default_name="${default_name%.*}_resized.${default_name##*.}"
    local default_path="$outdir/$default_name"

    # Try GUI save dialog first (handles directory + filename in one step)
    if has_gui; then
      local gui_path
      gui_path="$(gui_pick_save_file "Save compact image as" "$default_path")"
      if [[ -n "$gui_path" ]]; then
        dst="$gui_path"
        log "Output: $dst"
      fi
    fi

    # Terminal fallback: single prompt for full path
    if [[ -z "$dst" ]]; then
      echo
      echo "   Default: $default_path"
      while true; do
        read -rp "📁 Save as (full path or just filename): " tmp <"$TTY"
        if [[ -z "$tmp" ]]; then
          dst="$default_path"
          break
        fi
        # If user typed just a filename (no /), use default directory
        if [[ "$tmp" != */* ]]; then
          dst="$outdir/$tmp"
        else
          dst="$tmp"
        fi
        # Verify parent directory exists
        local parent_dir
        parent_dir="$(dirname "$dst")"
        if [[ -d "$parent_dir" ]]; then
          break
        else
          warn "Directory not found: $parent_dir — try again."
        fi
      done
    fi

    if [[ -e "$dst" ]]; then
      warn "File exists: $dst"
      local ow_ans
      ow_ans="$(ask_yesno "Overwrite it?" "N")"
      [[ "$ow_ans" == "true" ]] || die "Cancelled."
      rm -f "$dst"
    fi

    # Convert to compact file
    log "Converting to compact image: $dst"
    echo "   ⏳ This may take several minutes…"

    local total_bytes
    total_bytes="$(img_virtual_bytes "$img" 2>/dev/null || echo 0)"
    local rc=0

    if [[ -t 2 && "$total_bytes" =~ ^[0-9]+$ && "$total_bytes" -gt 0 ]]; then
      qemu_img_convert_with_tty_progress "$total_bytes" "Compacting" \
        qemu-img convert -p -O "$fmt" "$img" "$dst" || rc=$?
    else
      qemu-img convert -p -O "$fmt" "$img" "$dst" || rc=$?
    fi

    if [[ $rc -ne 0 ]]; then
      err "Convert failed (rc=$rc)"
      [[ -f "$dst" ]] && rm -f "$dst"
      die "Image compaction failed."
    fi

    # Verify new file
    log "Verifying new compact image…"
    if ! verify_image "$dst"; then
      warn "⚠️  New image has issues. Keeping old file for safety."
      warn "   Old file: $img"
      warn "   New file: $dst"
      pause
      return
    fi

    # ── Show before/after comparison ──
    local new_file_size
    new_file_size="$(stat -c '%s' "$dst" 2>/dev/null || echo 0)"
    local saved_bytes=$((old_file_size - new_file_size))

    echo
    hr
    echo "📊 Space Comparison"
    hr
    echo "   Old file:     $(numfmt --to=iec "$old_file_size")  ($(basename "$img"))"
    echo "   New file:     $(numfmt --to=iec "$new_file_size")  ($(basename "$dst"))"
    if ((saved_bytes > 0)); then
      echo -e "   ${GREEN}Saved:        $(numfmt --to=iec "$saved_bytes")  ✅${NC}"
    else
      echo "   Saved:        0 (no space reclaimed)"
    fi
    echo
    echo "   Virtual size: $(numfmt --to=iec "$new_vsize")"
    echo "   Format:       $fmt"
    hr

    _write_log "RESIZE" "$img → $dst | old=$(numfmt --to=iec "$old_file_size") new=$(numfmt --to=iec "$new_file_size") saved=$(numfmt --to=iec "$saved_bytes")"

    # ── Ask to delete old file ──
    echo
    log "The new compact image has been verified successfully."
    echo "   Old file: $img ($(numfmt --to=iec "$old_file_size"))"
    echo "   New file: $dst ($(numfmt --to=iec "$new_file_size"))"
    echo

    local del_ans
    del_ans="$(ask_yesno "🗑️  Delete the old large file?" "N")"
    if [[ "$del_ans" == "true" ]]; then
      rm -f "$img"
      success "Old file deleted: $img"
    else
      log "Old file kept: $img"
    fi

    echo
    success "Image resize and compaction complete!"
    echo "   📦 New image: $dst"
    qemu-img info "$dst" 2>/dev/null || true

  else
    # Virtual Only — no compaction, just verify and show summary
    echo
    verify_image "$img" || warn "Image may have issues after resize."

    local new_file_size
    new_file_size="$(stat -c '%s' "$img" 2>/dev/null || echo 0)"

    echo
    hr
    echo "📊 Resize Summary"
    hr
    echo "   Old virtual size:  $(numfmt --to=iec "$vsize")"
    echo "   New virtual size:  $(numfmt --to=iec "$new_vsize")"
    echo "   File size:         $(numfmt --to=iec "$new_file_size")"
    echo "   Format:            $fmt"
    hr
    echo
    info "💡 Tip: Run Option 12 again and choose [2] Actual File Size"
    info "   to compact the file and reclaim disk space."
    echo
    success "Virtual resize complete!"
    echo "   📦 Image: $img"
    qemu-img info "$img" 2>/dev/null || true
  fi

  pause
}

