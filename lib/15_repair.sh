# ============================================================
# Option 15: Repair Image / Disk / Partition
# Comprehensive diagnostic and repair tool.
# Handles: filesystem corruption, size mismatches,
#          partition table issues, qcow2 integrity,
#          boot flags, and filesystem expansion.
# Supports: ext2/3/4, NTFS, qcow2, raw, physical disks.
# ============================================================
repair_target() {
  hr
  echo "🔧 Repair Image / Disk / Partition"
  hr
  warn "Diagnoses and repairs filesystem, partition, and image issues."
  echo

  # ── Step 1: Ask what to repair ──
  echo "  What do you want to repair?"
  echo
  echo "  [1] 📦 Image file (qcow2, raw, etc.)"
  echo "  [2] 💽 Physical disk"
  echo "  [3] 📂 Physical partition"
  echo
  local target_type
  read -rp "➡️  Enter choice (1-3): " target_type <"$TTY"

  local img="" nbd="" target_disk="" is_image=false

  case "$target_type" in
    1)
      is_image=true
      img="$(ask_path_existing_file "📥 Enter image path to repair: ")"
      local fmt
      fmt="$(detect_img_format "$img")"
      log "Image: $img (format: $fmt)"

      # Check qcow2 integrity first
      if [[ "$fmt" == "qcow2" ]]; then
        echo
        log "Checking qcow2 image integrity…"
        local check_output error_count
        check_output="$(qemu-img check "$img" 2>&1)" || true

        # Count errors silently
        error_count="$(echo "$check_output" | grep -c "^ERROR" 2>/dev/null || echo 0)"

        if (( error_count > 0 )); then
          # Show short summary instead of thousands of lines
          local err_summary
          err_summary="$(echo "$check_output" | grep "^ERROR" | head -n1 | sed 's/^ERROR: //')"
          warn "qcow2 has $error_count error(s): ${err_summary:0:80}…"
          echo
          log "Attempting automatic repair…"
          local repair_output
          repair_output="$(qemu-img check -r all "$img" 2>&1)" || true
          local repair_errors
          repair_errors="$(echo "$repair_output" | grep -c "^ERROR" 2>/dev/null || echo 0)"
          if (( repair_errors > 0 )); then
            err "Repair reduced errors to $repair_errors, but some remain."
            warn "Image may still have issues. Consider re-imaging from source."
          else
            success "qcow2 repaired successfully. All errors resolved."
          fi
        else
          success "qcow2 image structure is healthy."
        fi
      fi

      # Connect via nbd
      nbd="$(pick_free_nbd)"
      log "Using $nbd"
      USED_NBDS+=("$nbd")
      qemu-nbd --connect="$nbd" "$img"
      partprobe "$nbd" 2>/dev/null || true
      sleep 1
      target_disk="$nbd"
      ;;
    2)
      target_disk="$(pick_block_device disk)"
      maybe_unmount "$target_disk"
      log "Physical disk: $target_disk"
      ;;
    3)
      local target_part_direct
      target_part_direct="$(pick_block_device part)"
      maybe_unmount "$target_part_direct"
      log "Physical partition: $target_part_direct"
      # For single partition repair, we handle it directly
      _repair_single_partition "$target_part_direct"
      pause
      return
      ;;
    *)
      die "Invalid choice."
      ;;
  esac

  # ── Step 2: Detect all partitions ──
  local parts=()
  while IFS= read -r p; do
    [[ -b "$p" ]] && parts+=("$p")
  done < <(lsblk -nrpo NAME,TYPE "$target_disk" | awk '$2=="part"{print $1}')

  if ((${#parts[@]} == 0)); then
    warn "No partitions found."
    if [[ "$is_image" == "true" ]]; then
      qemu-nbd --disconnect="$nbd" 2>/dev/null || true
      local tmp_nbds=() x
      for x in "${USED_NBDS[@]}"; do
        [[ "$x" == "$nbd" ]] && continue
        tmp_nbds+=("$x")
      done
      USED_NBDS=("${tmp_nbds[@]}")
    fi
    die "Cannot repair: no partitions found."
  fi

  echo
  echo "📦 Partitions found:"
  for i in "${!parts[@]}"; do
    local info
    info="$(lsblk -no SIZE,FSTYPE "${parts[$i]}" 2>/dev/null | sed 's/[[:space:]]\+/ /g')"
    echo "  [$((i+1))] ${parts[$i]} ($info)"
  done
  echo

  # ── Step 3: Run diagnostics on all partitions ──
  log "🔍 Running diagnostics on all partitions…"
  echo

  local issues_found=0
  local -a issue_list=()
  local -a fix_commands=()

  for i in "${!parts[@]}"; do
    local part="${parts[$i]}"
    local fstype
    fstype="$(lsblk -no FSTYPE "$part" 2>/dev/null | head -n1)"
    local part_size_bytes
    part_size_bytes="$(blockdev --getsize64 "$part" 2>/dev/null || echo 0)"

    echo "━━━ Partition $((i+1)): $part ($fstype) ━━━"

    case "$fstype" in
      ext4|ext3|ext2)
        local fs_block_size fs_blocks part_blocks
        fs_block_size="$(dumpe2fs -h "$part" 2>/dev/null | grep "Block size" | awk '{print $3}')" || true
        fs_blocks="$(dumpe2fs -h "$part" 2>/dev/null | grep "Block count" | awk '{print $3}')" || true
        fs_block_size="${fs_block_size:-4096}"
        part_blocks=$((part_size_bytes / fs_block_size))

        echo "   Filesystem blocks:  ${fs_blocks:-unknown}"
        echo "   Partition blocks:   $part_blocks"
        echo "   Filesystem size:    $(numfmt --to=iec $((${fs_blocks:-0} * fs_block_size)) 2>/dev/null || echo 'unknown')"
        echo "   Partition size:     $(numfmt --to=iec "$part_size_bytes")"

        # Check 1: Filesystem > Partition (corruption)
        if [[ -n "$fs_blocks" ]] && ((fs_blocks > part_blocks)); then
          echo -e "   ${RED}❌ ISSUE: Filesystem is LARGER than partition by $((fs_blocks - part_blocks)) blocks${NC}"
          issue_list+=("P$((i+1)): Filesystem larger than partition → will shrink filesystem to match")
          fix_commands+=("resize2fs -f '$part' '$part_blocks'")
          issues_found=$((issues_found + 1))
        # Check 2: Filesystem < Partition (unexpanded)
        elif [[ -n "$fs_blocks" ]] && ((fs_blocks < part_blocks - 1024)); then
          echo -e "   ${YELLOW}⚠️  NOTE: Filesystem is smaller than partition (may need expansion)${NC}"
          issue_list+=("P$((i+1)): Filesystem smaller than partition → can expand to fill")
          fix_commands+=("resize2fs '$part'")
          issues_found=$((issues_found + 1))
        else
          echo -e "   ${GREEN}✅ Filesystem size matches partition${NC}"
        fi

        # Check 3: Filesystem integrity (dry run)
        echo "   Running e2fsck dry-run check…"
        local e2fsck_output
        e2fsck_output="$(e2fsck -n -f "$part" 2>&1)" || true
        if echo "$e2fsck_output" | grep -qi "error\|corrupt\|invalid\|bad"; then
          echo -e "   ${RED}❌ ISSUE: Filesystem has errors${NC}"
          issue_list+=("P$((i+1)): Filesystem errors detected → will run e2fsck -f -y")
          fix_commands+=("e2fsck -f -y '$part'")
          issues_found=$((issues_found + 1))
        else
          echo -e "   ${GREEN}✅ Filesystem integrity: clean${NC}"
        fi
        ;;

      ntfs)
        echo "   Partition size: $(numfmt --to=iec "$part_size_bytes")"

        # Check NTFS integrity
        echo "   Running ntfsfix dry-run check…"
        local ntfsfix_output
        ntfsfix_output="$(ntfsfix -n "$part" 2>&1)" || true
        if echo "$ntfsfix_output" | grep -qi "error\|corrupt\|fail"; then
          echo -e "   ${RED}❌ ISSUE: NTFS has errors${NC}"
          issue_list+=("P$((i+1)): NTFS errors detected → will run ntfsfix")
          fix_commands+=("ntfsfix '$part'")
          issues_found=$((issues_found + 1))
        else
          echo -e "   ${GREEN}✅ NTFS integrity: clean${NC}"
        fi

        # Check NTFS size
        local ntfs_used
        ntfs_used="$(ntfsresize --info "$part" 2>/dev/null | grep -o 'at [0-9]* bytes' | grep -o '[0-9]*')" || true
        if [[ -n "$ntfs_used" ]]; then
          echo "   Used data: $(numfmt --to=iec "$ntfs_used")"
        fi
        ;;

      "")
        echo -e "   ${YELLOW}⚠️  No filesystem detected (may be swap, LVM, or unformatted)${NC}"
        ;;

      *)
        echo "   Filesystem type: $fstype (no repair support for this type)"
        ;;
    esac
    echo
  done

  # ── Step 4: Check partition table ──
  echo "━━━ Partition Table Check ━━━"
  local pt_type
  pt_type="$(lsblk -no PTTYPE "$target_disk" 2>/dev/null | head -n1)"
  echo "   Partition table type: ${pt_type:-none}"

  if [[ -z "$pt_type" ]]; then
    echo -e "   ${RED}❌ ISSUE: No partition table detected${NC}"
    issue_list+=("Disk: No partition table detected")
    issues_found=$((issues_found + 1))
  else
    echo -e "   ${GREEN}✅ Partition table present${NC}"
  fi
  echo

  # ── Step 5: Show summary and ask to fix ──
  if ((issues_found == 0)); then
    success "🎉 No issues found. Everything looks healthy!"
    if [[ "$is_image" == "true" ]]; then
      qemu-nbd --disconnect "$nbd" 2>/dev/null || true
      local tmp_nbds=() x
      for x in "${USED_NBDS[@]}"; do
        [[ "$x" == "$nbd" ]] && continue
        tmp_nbds+=("$x")
      done
      USED_NBDS=("${tmp_nbds[@]}")
    fi
    pause
    return
  fi

  hr
  echo "🔧 Issues Found: $issues_found"
  hr
  for i in "${!issue_list[@]}"; do
    echo "  [$((i+1))] ${issue_list[$i]}"
  done
  echo

  local fix_ans
  fix_ans="$(ask_yesno "🔧 Fix all detected issues?" "Y")"
  if [[ "$fix_ans" != "true" ]]; then
    log "Repair cancelled by user."
    if [[ "$is_image" == "true" ]]; then
      qemu-nbd --disconnect "$nbd" 2>/dev/null || true
      local tmp_nbds=() x
      for x in "${USED_NBDS[@]}"; do
        [[ "$x" == "$nbd" ]] && continue
        tmp_nbds+=("$x")
      done
      USED_NBDS=("${tmp_nbds[@]}")
    fi
    pause
    return
  fi

  # ── Step 6: Apply fixes ──
  echo
  log "Applying fixes…"
  local fix_success=0 fix_fail=0

  for i in "${!fix_commands[@]}"; do
    echo
    log "Fix $((i+1))/${#fix_commands[@]}: ${issue_list[$i]}"
    if eval "${fix_commands[$i]}" 2>&1; then
      success "Fix applied successfully."
      fix_success=$((fix_success + 1))
    else
      err "Fix failed: ${fix_commands[$i]}"
      fix_fail=$((fix_fail + 1))
    fi
  done

  # ── Step 7: Post-repair verification ──
  echo
  log "🔍 Running post-repair verification…"
  echo

  for i in "${!parts[@]}"; do
    local part="${parts[$i]}"
    local fstype
    fstype="$(lsblk -no FSTYPE "$part" 2>/dev/null | head -n1)"

    case "$fstype" in
      ext4|ext3|ext2)
        local verify_output
        verify_output="$(e2fsck -n -f "$part" 2>&1)" || true
        if echo "$verify_output" | grep -qi "error\|corrupt"; then
          echo -e "   ${RED}❌ $part still has issues${NC}"
        else
          echo -e "   ${GREEN}✅ $part is clean${NC}"
        fi
        ;;
      ntfs)
        echo -e "   ${GREEN}✅ $part (NTFS repair applied)${NC}"
        ;;
    esac
  done

  # ── Step 8: Cleanup ──
  if [[ "$is_image" == "true" ]]; then
    qemu-nbd --disconnect "$nbd" 2>/dev/null || true
    local tmp_nbds=() x
    for x in "${USED_NBDS[@]}"; do
      [[ "$x" == "$nbd" ]] && continue
      tmp_nbds+=("$x")
    done
    USED_NBDS=("${tmp_nbds[@]}")

    # Verify image after repair
    verify_image "$img" || warn "Image may still have issues."
  fi

  # ── Step 9: Summary ──
  echo
  hr
  echo "📊 Repair Summary"
  hr
  echo "   Issues found:    $issues_found"
  echo -e "   Fixes applied:   ${GREEN}$fix_success succeeded${NC}"
  if ((fix_fail > 0)); then
    echo -e "   Fixes failed:    ${RED}$fix_fail failed${NC}"
  fi
  hr

  _write_log "REPAIR" "Target: ${img:-$target_disk} | Issues: $issues_found | Fixed: $fix_success | Failed: $fix_fail"

  success "Repair complete!"
  pause
}

# ── Helper: Repair a single partition directly ──
_repair_single_partition() {
  local part="$1"
  local fstype
  fstype="$(lsblk -no FSTYPE "$part" 2>/dev/null | head -n1)"

  echo
  log "Repairing partition: $part (filesystem: $fstype)"

  case "$fstype" in
    ext4|ext3|ext2)
      local fs_block_size fs_blocks part_size_bytes part_blocks
      fs_block_size="$(dumpe2fs -h "$part" 2>/dev/null | grep "Block size" | awk '{print $3}')" || true
      fs_blocks="$(dumpe2fs -h "$part" 2>/dev/null | grep "Block count" | awk '{print $3}')" || true
      fs_block_size="${fs_block_size:-4096}"
      part_size_bytes="$(blockdev --getsize64 "$part" 2>/dev/null || echo 0)"
      part_blocks=$((part_size_bytes / fs_block_size))

      echo "   Filesystem blocks: ${fs_blocks:-unknown}"
      echo "   Partition blocks:  $part_blocks"

      # Fix size mismatch
      if [[ -n "$fs_blocks" ]] && ((fs_blocks > part_blocks)); then
        warn "Filesystem larger than partition. Shrinking filesystem…"
        resize2fs -f "$part" "$part_blocks" || { err "Shrink failed."; return; }
        success "Filesystem shrunk to match partition."
      elif [[ -n "$fs_blocks" ]] && ((fs_blocks < part_blocks - 1024)); then
        log "Filesystem smaller than partition. Expanding…"
        resize2fs "$part" || { err "Expand failed."; return; }
        success "Filesystem expanded to fill partition."
      fi

      # Fix corruption
      log "Running e2fsck…"
      e2fsck -f -y "$part" 2>&1 || true
      success "Filesystem check complete."
      ;;
    ntfs)
      log "Running ntfsfix…"
      ntfsfix "$part" 2>&1 || { err "ntfsfix failed."; return; }
      success "NTFS fix complete."
      ;;
    *)
      warn "Filesystem '$fstype' is not supported for repair."
      ;;
  esac
}

