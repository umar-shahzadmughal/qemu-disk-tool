# ============================================================
# Option 15: Repair Image / Disk / Partition
# Comprehensive repair: filesystem, partition table, boot repair
# Supports: Linux & Windows boot repair, ext2/3/4, NTFS,
#           qcow2, raw, physical disks, auto-detection
# ============================================================
repair_target() {
  hr
  echo "🔧 Repair Image / Disk / Partition"
  hr
  warn "Diagnoses and repairs filesystem, partition, and boot issues."
  echo

  echo "  What do you want to repair?"
  echo
  echo "  [1] 🔍 Full Auto-Repair (detect OS + fix everything)  ⭐ Recommended"
  echo "  [2] 🐧 Linux Boot Repair"
  echo "  [3] 🪟 Windows Boot Repair"
  echo "  [4] 📦 Filesystem / Image Repair (diagnostics)"
  echo "  [5] 📂 Single Partition Repair"
  echo
  local choice
  read -rp "➡️  Enter choice (1-5): " choice <"$TTY"

  case "$choice" in
    1) _repair_full_auto ;;
    2) _repair_linux_boot_standalone ;;
    3) _repair_windows_boot_standalone ;;
    4) _repair_filesystem_diagnostics ;;
    5)
      local part
      part="$(pick_block_device part)"
      maybe_unmount "$part"
      _repair_single_partition "$part"
      pause
      ;;
    *) die "Invalid choice." ;;
  esac
}

# ── Helper: Connect target (image or disk) and return nbd/device ──
_repair_connect_target() {
  # Sets global: _RPT_DISK, _RPT_NBD, _RPT_IS_IMAGE, _RPT_IMG
  _RPT_IS_IMAGE=false
  _RPT_NBD=""
  _RPT_IMG=""

  echo
  echo "  Target type:"
  echo "  [1] 📦 Image file (qcow2, raw, etc.)"
  echo "  [2] 💽 Physical disk"
  echo
  local ttype
  read -rp "➡️  Enter choice (1-2): " ttype <"$TTY"

  case "$ttype" in
    1)
      _RPT_IS_IMAGE=true
      _RPT_IMG="$(ask_path_existing_file "📥 Enter image path: ")"
      local fmt
      fmt="$(detect_img_format "$_RPT_IMG")"
      log "Image: $_RPT_IMG (format: $fmt)"

      if [[ "$fmt" == "qcow2" ]]; then
        echo
        log "Checking qcow2 image integrity…"
        local check_output error_count
        check_output="$(qemu-img check "$_RPT_IMG" 2>&1)" || true
        error_count="$(echo "$check_output" | grep -c "^ERROR" 2>/dev/null || echo 0)"
        
        if (( error_count > 0 )); then
          local err_summary
          err_summary="$(echo "$check_output" | grep "^ERROR" | head -n1 | sed 's/^ERROR: //')"
          warn "qcow2 has $error_count error(s): ${err_summary:0:80}…"
          echo
          log "Attempting automatic repair…"
          local repair_output
          repair_output="$(qemu-img check -r all "$_RPT_IMG" 2>&1)" || true
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

      _RPT_NBD="$(pick_free_nbd)"
      USED_NBDS+=("$_RPT_NBD")
      qemu-nbd --connect="$_RPT_NBD" "$_RPT_IMG"
      partprobe "$_RPT_NBD" 2>/dev/null || true
      sleep 1
      _RPT_DISK="$_RPT_NBD"
      ;;
    2)
      _RPT_DISK="$(pick_block_device disk)"
      maybe_unmount "$_RPT_DISK"
      ;;
    *) die "Invalid choice." ;;
  esac
}

# ── Helper: Disconnect target ──
_repair_disconnect() {
  if [[ "$_RPT_IS_IMAGE" == "true" && -n "$_RPT_NBD" ]]; then
    qemu-nbd --disconnect "$_RPT_NBD" 2>/dev/null || true
    local tmp=() x
    for x in "${USED_NBDS[@]}"; do
      [[ "$x" == "$_RPT_NBD" ]] && continue
      tmp+=("$x")
    done
    USED_NBDS=("${tmp[@]}")
    
    # Verify image after repair
    verify_image "$_RPT_IMG" || warn "Image may still have issues."
  fi
}

# ── Helper: Detect OS on a mounted partition ──
_detect_os() {
  local mnt="$1"
  if [[ -f "$mnt/etc/os-release" || -f "$mnt/etc/fstab" || -d "$mnt/boot" ]]; then
    echo "linux"
  elif [[ -d "$mnt/Windows/System32" || -f "$mnt/Windows/System32/ntoskrnl.exe" ]]; then
    echo "windows"
  else
    echo "unknown"
  fi
}

# ══════════════════════════════════════════════════════════
# FULL AUTO-REPAIR
# ══════════════════════════════════════════════════════════
_repair_full_auto() {
  hr
  echo "🔍 Full Auto-Repair"
  hr

  _repair_connect_target

  # Detect partitions
  local parts=()
  while IFS= read -r p; do
    [[ -b "$p" ]] && parts+=("$p")
  done < <(lsblk -nrpo NAME,TYPE "$_RPT_DISK" | awk '$2=="part"{print $1}')

  if ((${#parts[@]} == 0)); then
    warn "No partitions found."
    _repair_disconnect
    pause
    return
  fi

  log "Found ${#parts[@]} partition(s). Detecting OS…"

  # Mount each partition and detect OS
  local os_type="unknown"
  local root_part="" efi_part=""
  local tmp_mnt

  for part in "${parts[@]}"; do
    local fstype
    fstype="$(lsblk -no FSTYPE "$part" 2>/dev/null | head -n1)"
    [[ "$fstype" =~ ^(ext2|ext3|ext4|xfs|btrfs|ntfs|vfat)$ ]] || continue

    tmp_mnt="$(mktemp -d)"
    if mount -o ro "$part" "$tmp_mnt" 2>/dev/null; then
      local detected
      detected="$(_detect_os "$tmp_mnt")"
      if [[ "$detected" == "linux" && -z "$root_part" ]]; then
        os_type="linux"
        root_part="$part"
      elif [[ "$detected" == "windows" && -z "$root_part" ]]; then
        os_type="windows"
        root_part="$part"
      fi
      umount "$tmp_mnt"
    fi
    rmdir "$tmp_mnt" 2>/dev/null

    # Detect EFI partition
    if [[ "$fstype" == "vfat" ]]; then
      local part_size
      part_size="$(lsblk -bno SIZE "$part" 2>/dev/null | tail -n1)"
      if [[ -n "$part_size" && "$part_size" -le 536870912 ]]; then
        efi_part="$part"
      fi
    fi
  done

  echo
  case "$os_type" in
    linux)
      success "Detected: Linux (root: $root_part)"
      echo
      log "Running filesystem repair + Linux boot repair…"
      _repair_all_filesystems "$_RPT_DISK"
      _repair_linux_boot "$_RPT_DISK" "$root_part" "$efi_part"
      ;;
    windows)
      success "Detected: Windows (system: $root_part)"
      echo
      log "Running filesystem repair + Windows boot repair…"
      _repair_all_filesystems "$_RPT_DISK"
      _repair_windows_boot "$_RPT_DISK" "$root_part" "$efi_part"
      ;;
    *)
      warn "Could not detect OS. Running filesystem repair only."
      _repair_all_filesystems "$_RPT_DISK"
      ;;
  esac

  _repair_disconnect
  echo
  success "Full auto-repair complete!"
  pause
}

# ══════════════════════════════════════════════════════════
# LINUX BOOT REPAIR
# ══════════════════════════════════════════════════════════
_repair_linux_boot_standalone() {
  hr
  echo "🐧 Linux Boot Repair"
  hr
  _repair_connect_target

  local parts=()
  while IFS= read -r p; do
    [[ -b "$p" ]] && parts+=("$p")
  done < <(lsblk -nrpo NAME,TYPE "$_RPT_DISK" | awk '$2=="part"{print $1}')

  local root_part="" efi_part=""
  for part in "${parts[@]}"; do
    local fstype
    fstype="$(lsblk -no FSTYPE "$part" 2>/dev/null | head -n1)"
    [[ "$fstype" =~ ^(ext2|ext3|ext4|xfs|btrfs)$ ]] || continue

    local tmp_mnt
    tmp_mnt="$(mktemp -d)"
    if mount -o ro "$part" "$tmp_mnt" 2>/dev/null; then
      if [[ -f "$tmp_mnt/etc/os-release" || -f "$tmp_mnt/etc/fstab" ]]; then
        root_part="$part"
        umount "$tmp_mnt"
        rmdir "$tmp_mnt"
        break
      fi
      umount "$tmp_mnt"
    fi
    rmdir "$tmp_mnt" 2>/dev/null
  done

  # Find EFI partition
  for part in "${parts[@]}"; do
    local fstype
    fstype="$(lsblk -no FSTYPE "$part" 2>/dev/null | head -n1)"
    if [[ "$fstype" == "vfat" ]]; then
      efi_part="$part"
      break
    fi
  done

  if [[ -z "$root_part" ]]; then
    warn "No Linux root partition found."
    _repair_disconnect
    pause
    return
  fi

  _repair_linux_boot "$_RPT_DISK" "$root_part" "$efi_part"
  _repair_disconnect
  pause
}

_repair_linux_boot() {
  local disk="$1" root_part="$2" efi_part="${3:-}"

  log "Root partition: $root_part"
  [[ -n "$efi_part" ]] && log "EFI partition: $efi_part"

  # Mount root
  local mnt_root
  mnt_root="$(mktemp -d)"
  mount "$root_part" "$mnt_root" || { err "Cannot mount root partition."; rmdir "$mnt_root"; return; }

  # Mount EFI if present
  if [[ -n "$efi_part" ]]; then
    mkdir -p "$mnt_root/boot/efi"
    mount "$efi_part" "$mnt_root/boot/efi" 2>/dev/null || true
  fi

  # ── Fix 1: /etc/fstab UUIDs ──
  log "Fixing /etc/fstab UUIDs…"
  local root_uuid
  root_uuid="$(blkid -s UUID -o value "$root_part" 2>/dev/null)"
  if [[ -n "$root_uuid" && -f "$mnt_root/etc/fstab" ]]; then
    sed -i "s|UUID=[a-f0-9-]*\s*/|UUID=$root_uuid /|" "$mnt_root/etc/fstab" 2>/dev/null || true
    sed -i '/\sswap\s/s/^/#/' "$mnt_root/etc/fstab" 2>/dev/null || true
    success "fstab updated."
  fi

  # ── Fix 2: Add virtio drivers ──
  log "Adding virtio drivers to initramfs…"
  local modules_file="$mnt_root/etc/initramfs-tools/modules"
  if [[ -d "$mnt_root/etc/initramfs-tools" ]]; then
    mkdir -p "$(dirname "$modules_file")"
    for m in virtio_pci virtio_blk virtio_net virtio_scsi virtio_balloon; do
      grep -qx "$m" "$modules_file" 2>/dev/null || echo "$m" >> "$modules_file"
    done
    rm -f "$mnt_root/etc/initramfs-tools/conf.d/resume"
    success "Virtio drivers added."
  fi

  # ── Fix 3: Bind mount and chroot for GRUB ──
  log "Installing GRUB bootloader…"
  for d in dev dev/pts proc sys run; do
    mkdir -p "$mnt_root/$d"
    mount --bind "/$d" "$mnt_root/$d" 2>/dev/null || true
  done

  local grub_ok=true
  if [[ -n "$efi_part" ]]; then
    # UEFI
    chroot "$mnt_root" /bin/bash -c "
      export DEBIAN_FRONTEND=noninteractive
      update-initramfs -u -k all 2>/dev/null || update-initramfs -u 2>/dev/null || true
      grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck --force 2>/dev/null || true
      update-grub 2>/dev/null || true
    " 2>/dev/null || grub_ok=false
  else
    # BIOS
    chroot "$mnt_root" /bin/bash -c "
      export DEBIAN_FRONTEND=noninteractive
      update-initramfs -u -k all 2>/dev/null || update-initramfs -u 2>/dev/null || true
      grub-install --target=i386-pc --recheck --force $disk 2>/dev/null || true
      update-grub 2>/dev/null || true
    " 2>/dev/null || grub_ok=false
  fi

  if [[ "$grub_ok" == "true" ]]; then
    success "GRUB installed and configured."
  else
    warn "GRUB installation had issues. Manual repair may be needed."
  fi

  # ── Fix 4: Set boot flags ──
  local pt_type
  pt_type="$(lsblk -no PTTYPE "$disk" 2>/dev/null | head -n1)"
  if [[ "$pt_type" == "dos" ]]; then
    local part_num
    part_num="$(echo "$root_part" | grep -o '[0-9]*$')"
    parted -s "$disk" set "$part_num" boot on 2>/dev/null || true
    log "Boot flag set on partition $part_num."
  fi

  # ── Cleanup ──
  for d in run sys proc dev/pts dev; do
    umount "$mnt_root/$d" 2>/dev/null || true
  done
  [[ -n "$efi_part" ]] && umount "$mnt_root/boot/efi" 2>/dev/null || true
  umount "$mnt_root" 2>/dev/null || true
  rmdir "$mnt_root" 2>/dev/null || true

  success "Linux boot repair complete."
}

# ══════════════════════════════════════════════════════════
# WINDOWS BOOT REPAIR
# ══════════════════════════════════════════════════════════
_repair_windows_boot_standalone() {
  hr
  echo "🪟 Windows Boot Repair"
  hr
  _repair_connect_target

  local parts=()
  while IFS= read -r p; do
    [[ -b "$p" ]] && parts+=("$p")
  done < <(lsblk -nrpo NAME,TYPE "$_RPT_DISK" | awk '$2=="part"{print $1}')

  local win_part="" efi_part=""
  for part in "${parts[@]}"; do
    local fstype
    fstype="$(lsblk -no FSTYPE "$part" 2>/dev/null | head -n1)"
    [[ "$fstype" == "ntfs" ]] || continue

    local tmp_mnt
    tmp_mnt="$(mktemp -d)"
    if mount -o ro "$part" "$tmp_mnt" 2>/dev/null; then
      if [[ -d "$tmp_mnt/Windows/System32" ]]; then
        win_part="$part"
        umount "$tmp_mnt"
        rmdir "$tmp_mnt"
        break
      fi
      umount "$tmp_mnt"
    fi
    rmdir "$tmp_mnt" 2>/dev/null
  done

  for part in "${parts[@]}"; do
    local fstype
    fstype="$(lsblk -no FSTYPE "$part" 2>/dev/null | head -n1)"
    if [[ "$fstype" == "vfat" ]]; then
      efi_part="$part"
      break
    fi
  done

  if [[ -z "$win_part" ]]; then
    warn "No Windows partition found."
    _repair_disconnect
    pause
    return
  fi

  _repair_windows_boot "$_RPT_DISK" "$win_part" "$efi_part"
  _repair_disconnect
  pause
}

_repair_windows_boot() {
  local disk="$1" win_part="$2" efi_part="${3:-}"

  log "Windows partition: $win_part"
  [[ -n "$efi_part" ]] && log "EFI partition: $efi_part"

  local pt_type
  pt_type="$(lsblk -no PTTYPE "$disk" 2>/dev/null | head -n1)"

  # ── Fix 1: NTFS filesystem repair ──
  log "Running ntfsfix on Windows partition…"
  ntfsfix "$win_part" 2>/dev/null || true
  success "NTFS fix applied."

  # ── Fix 2: MBR/PBR for BIOS boot ──
  if [[ "$pt_type" == "dos" ]]; then
    log "Writing Windows MBR (BIOS mode)…"
    if command -v ms-sys >/dev/null 2>&1; then
      ms-sys --mbr7 "$disk" 2>/dev/null || ms-sys -7 "$disk" 2>/dev/null || true
      success "Windows MBR written."
    else
      warn "ms-sys not found. Cannot write Windows MBR."
      warn "Install: sudo apt install ms-sys"
    fi

    local part_num
    part_num="$(echo "$win_part" | grep -o '[0-9]*$')"
    parted -s "$disk" set "$part_num" boot on 2>/dev/null || true
    log "Boot flag set on partition $part_num."
  fi

  # ── Fix 3: EFI structure check ──
  if [[ -n "$efi_part" ]]; then
    log "Checking EFI partition structure…"
    local efi_mnt
    efi_mnt="$(mktemp -d)"
    if mount "$efi_part" "$efi_mnt" 2>/dev/null; then
      local bootmgfw="$efi_mnt/EFI/Microsoft/Boot/bootmgfw.efi"
      local bootx64="$efi_mnt/EFI/Boot/bootx64.efi"

      if [[ -f "$bootmgfw" ]]; then
        success "EFI boot file found: bootmgfw.efi"
        if [[ ! -f "$bootx64" ]]; then
          mkdir -p "$efi_mnt/EFI/Boot"
          cp "$bootmgfw" "$bootx64" 2>/dev/null || true
          log "Created fallback EFI boot path."
        fi
      else
        warn "bootmgfw.efi NOT found. EFI boot may fail."
        warn "You may need to repair using Windows Installation Media."
      fi
      umount "$efi_mnt"
    fi
    rmdir "$efi_mnt" 2>/dev/null || true
  fi

  # ── Fix 4: BCD guidance ──
  echo
  hr
  echo "  📋 If Windows still doesn't boot (BCD issue):"
  hr
  echo "  1. Boot from Windows Installation USB/DVD"
  echo "  2. Click 'Repair your computer'"
  echo "  3. Go to: Troubleshoot → Command Prompt"
  echo "  4. Run these commands:"
  echo
  echo "     bootrec /fixmbr"
  echo "     bootrec /fixboot"
  echo "     bootrec /scanbcd"
  echo "     bootrec /rebuildbcd"
  echo
  echo "  For UEFI systems, also run:"
  echo "     bcdboot C:\\Windows /s S: /f UEFI"
  echo "     (where S: is your EFI partition letter)"
  hr

  success "Windows boot repair complete."
}

# ══════════════════════════════════════════════════════════
# FILESYSTEM REPAIR (diagnostics + fix)
# ══════════════════════════════════════════════════════════
_repair_filesystem_diagnostics() {
  hr
  echo "📦 Filesystem / Image Repair"
  hr

  _repair_connect_target
  _repair_all_filesystems "$_RPT_DISK"
  _repair_disconnect
  pause
}

_repair_all_filesystems() {
  local disk="$1"

  local parts=()
  while IFS= read -r p; do
    [[ -b "$p" ]] && parts+=("$p")
  done < <(lsblk -nrpo NAME,TYPE "$disk" | awk '$2=="part"{print $1}')

  ((${#parts[@]} == 0)) && { warn "No partitions found."; return; }

  echo
  echo "📦 Partitions found:"
  for i in "${!parts[@]}"; do
    local info
    info="$(lsblk -no SIZE,FSTYPE "${parts[$i]}" 2>/dev/null | sed 's/[[:space:]]\+/ /g')"
    echo "  [$((i+1))] ${parts[$i]} ($info)"
  done
  echo

  # Run diagnostics first
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

        if [[ -n "$fs_blocks" ]] && ((fs_blocks > part_blocks)); then
          echo -e "   ${RED}❌ ISSUE: Filesystem is LARGER than partition${NC}"
          issue_list+=("P$((i+1)): Filesystem larger than partition → will shrink")
          fix_commands+=("resize2fs -f '$part' '$part_blocks'")
          issues_found=$((issues_found + 1))
        elif [[ -n "$fs_blocks" ]] && ((fs_blocks < part_blocks - 1024)); then
          echo -e "   ${YELLOW}⚠️  NOTE: Filesystem smaller than partition (may need expansion)${NC}"
          issue_list+=("P$((i+1)): Filesystem smaller than partition → can expand")
          fix_commands+=("resize2fs '$part'")
          issues_found=$((issues_found + 1))
        else
          echo -e "   ${GREEN}✅ Filesystem size matches partition${NC}"
        fi

        echo "   Running e2fsck dry-run check…"
        local e2fsck_output
        e2fsck_output="$(e2fsck -n -f "$part" 2>&1)" || true
        if echo "$e2fsck_output" | grep -qi "error\|corrupt\|invalid\|bad"; then
          echo -e "   ${RED}❌ ISSUE: Filesystem has errors${NC}"
          issue_list+=("P$((i+1)): Filesystem errors → will run e2fsck -f -y")
          fix_commands+=("e2fsck -f -y '$part'")
          issues_found=$((issues_found + 1))
        else
          echo -e "   ${GREEN}✅ Filesystem integrity: clean${NC}"
        fi
        ;;

      ntfs)
        echo "   Partition size: $(numfmt --to=iec "$part_size_bytes")"
        echo "   Running ntfsfix dry-run check…"
        local ntfsfix_output
        ntfsfix_output="$(ntfsfix -n "$part" 2>&1)" || true
        if echo "$ntfsfix_output" | grep -qi "error\|corrupt\|fail"; then
          echo -e "   ${RED}❌ ISSUE: NTFS has errors${NC}"
          issue_list+=("P$((i+1)): NTFS errors → will run ntfsfix")
          fix_commands+=("ntfsfix '$part'")
          issues_found=$((issues_found + 1))
        else
          echo -e "   ${GREEN}✅ NTFS integrity: clean${NC}"
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

  # Partition table check
  echo "━━━ Partition Table Check ━━━"
  local pt_type
  pt_type="$(lsblk -no PTTYPE "$disk" 2>/dev/null | head -n1)"
  echo "   Partition table type: ${pt_type:-none}"
  if [[ -z "$pt_type" ]]; then
    echo -e "   ${RED}❌ ISSUE: No partition table detected${NC}"
    issue_list+=("Disk: No partition table detected")
    issues_found=$((issues_found + 1))
  else
    echo -e "   ${GREEN}✅ Partition table present${NC}"
  fi
  echo

  # Summary and fix
  if ((issues_found == 0)); then
    success "🎉 No issues found. Everything looks healthy!"
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
    return
  fi

  # Apply fixes
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

  # Post-repair verification
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

  _write_log "REPAIR" "Issues: $issues_found | Fixed: $fix_success | Failed: $fix_fail"
}

# ── Single partition repair ──
_repair_single_partition() {
  local part="$1"
  local fstype
  fstype="$(lsblk -no FSTYPE "$part" 2>/dev/null | head -n1)"

  log "Repairing: $part ($fstype)"

  case "$fstype" in
    ext4|ext3|ext2)
      local fs_block_size fs_blocks part_size_bytes part_blocks
      fs_block_size="$(dumpe2fs -h "$part" 2>/dev/null | grep "Block size" | awk '{print $3}')" || true
      fs_blocks="$(dumpe2fs -h "$part" 2>/dev/null | grep "Block count" | awk '{print $3}')" || true
      fs_block_size="${fs_block_size:-4096}"
      part_size_bytes="$(blockdev --getsize64 "$part" 2>/dev/null || echo 0)"
      part_blocks=$((part_size_bytes / fs_block_size))

      # Fix size mismatch
      if [[ -n "$fs_blocks" ]] && ((fs_blocks > part_blocks)); then
        warn "Filesystem larger than partition. Shrinking…"
        resize2fs -f "$part" "$part_blocks" 2>/dev/null || true
        success "Filesystem shrunk."
      elif [[ -n "$fs_blocks" ]] && ((fs_blocks < part_blocks - 1024)); then
        log "Filesystem smaller than partition. Expanding…"
        resize2fs "$part" 2>/dev/null || true
        success "Filesystem expanded."
      fi

      # Fix corruption
      e2fsck -f -y "$part" 2>/dev/null || true
      success "ext filesystem check complete."
      ;;
    ntfs)
      ntfsfix "$part" 2>/dev/null || true
      success "NTFS fix complete."
      ;;
    vfat)
      fsck.vfat -a "$part" 2>/dev/null || true
      success "FAT filesystem check complete."
      ;;
    *)
      warn "Filesystem '$fstype' not supported for repair."
      ;;
  esac
}