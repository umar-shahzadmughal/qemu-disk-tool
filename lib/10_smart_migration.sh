# ============================================================
# Option 10: Smart OS Migration (bootable VM from real drive)
# Detects: root, boot, EFI partitions automatically
# Copies: data via rsync (preserving UUIDs and permissions)
# Installs: GRUB (BIOS or UEFI), virtio drivers
# Fixes: /etc/fstab for VM compatibility
# Result: A fully bootable qcow2 image
# ============================================================
smart_os_migration() {
  hr
  echo "🚀 Smart OS Migration — Bootable VM from Real Drive"
  hr
  warn "This creates a BOOTABLE qcow2 by copying files (not raw blocks)."
  warn "It detects root/boot/EFI, installs GRUB, and fixes fstab."
  echo

  # ── Check rsync dependency ──
  if ! have rsync; then
    die "rsync is required for Smart OS Migration. Install: sudo apt install rsync"
  fi

  # ── Select source disk ──
  local src_disk
  src_disk="$(pick_block_device disk)"
  maybe_unmount "$src_disk"

  # ── Scan partitions ──
  echo
  log "Scanning partitions on $src_disk …"
  local parts=() fstypes=() sizes=()
  while IFS= read -r line; do
    local p s f
    p="$(echo "$line" | awk '{print $1}')"
    s="$(echo "$line" | awk '{print $2}')"
    f="$(echo "$line" | awk '{print $3}')"
    [[ -b "$p" ]] || continue
    parts+=("$p")
    sizes+=("$s")
    fstypes+=("$f")
  done < <(lsblk -nrpo NAME,SIZE,FSTYPE "$src_disk" | awk '$1 ~ /part/')

  ((${#parts[@]} == 0)) && die "No partitions found on $src_disk"

  # ── Display partitions ──
  echo
  echo "📦 Partitions found on $src_disk:"
  for i in "${!parts[@]}"; do
    printf "  [%d] %-12s %-10s %s\n" "$((i+1))" "${parts[$i]}" "${sizes[$i]}" "${fstypes[$i]}"
  done
  echo

  # ── Detect root partition ──
  local root_part="" root_idx=-1
  echo "🔍 Detecting root partition…"
  for i in "${!parts[@]}"; do
    if [[ "${fstypes[$i]}" == "ext4" || "${fstypes[$i]}" == "btrfs" || "${fstypes[$i]}" == "xfs" ]]; then
      # Try to detect if this partition has /etc/fstab (likely root)
      local tmp_mnt
      tmp_mnt="$(mktemp -d)"
      if mount -o ro "${parts[$i]}" "$tmp_mnt" 2>/dev/null; then
        if [[ -f "$tmp_mnt/etc/fstab" ]]; then
          root_part="${parts[$i]}"
          root_idx=$i
          umount "$tmp_mnt"
          rmdir "$tmp_mnt"
          break
        fi
        umount "$tmp_mnt"
      fi
      rmdir "$tmp_mnt" 2>/dev/null
    fi
  done

  if [[ -z "$root_part" ]]; then
    warn "Could not auto-detect root partition."
    read -rp "➡️  Enter partition number for root (1-${#parts[@]}): " root_idx <"$TTY"
    root_idx=$((root_idx - 1))
    [[ $root_idx -ge 0 && $root_idx -lt ${#parts[@]} ]] || die "Invalid selection."
    root_part="${parts[$root_idx]}"
  fi

  log "Root partition detected: $root_part (${fstypes[$root_idx]})"

  # ── Detect boot/EFI partition ──
  local boot_part="" boot_idx=-1
  for i in "${!parts[@]}"; do
    [[ $i -eq $root_idx ]] && continue
    if [[ "${fstypes[$i]}" == "vfat" ]]; then
      boot_part="${parts[$i]}"
      boot_idx=$i
      log "EFI partition detected: $boot_part (vfat)"
      break
    fi
  done

  # ── Output setup ──
  local dst=""
  local outdir
  outdir="$(suggest_out_dir)"
  local default_path="$outdir/migrated-os.qcow2"

  if has_gui; then
    local gui_path
    gui_path="$(gui_pick_save_file "Save migrated OS image as" "$default_path")"
    if [[ -n "$gui_path" ]]; then
      dst="$gui_path"
    fi
  fi

  if [[ -z "$dst" ]]; then
    echo
    echo "   Default: $default_path"
    while true; do
      read -rp "📁 Save as (full path or just filename): " tmp <"$TTY"
      if [[ -z "$tmp" ]]; then
        dst="$default_path"
        break
      fi
      if [[ "$tmp" != */* ]]; then
        dst="$outdir/$tmp"
      else
        dst="$tmp"
      fi
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

  # ── Calculate size ──
  # Use actual used space, not partition size
  local root_used root_size
  root_size="$(bytes_of_src "$root_part")"
  
  # Try to get actual used space via df
  local src_mnt_tmp
  src_mnt_tmp="$(mktemp -d)"
  if mount -o ro "$root_part" "$src_mnt_tmp" 2>/dev/null; then
    root_used="$(df -B1 "$src_mnt_tmp" 2>/dev/null | awk 'NR==2 {print $3}')"
    umount "$src_mnt_tmp"
  fi
  rmdir "$src_mnt_tmp" 2>/dev/null
  
  # If we got used space, use it + 2GB overhead. Otherwise use partition size + 512MB
  if [[ -n "$root_used" && "$root_used" =~ ^[0-9]+$ && "$root_used" -gt 0 ]]; then
    local img_size=$((root_used + 2 * 1024 * 1024 * 1024))
    log "Root used space: $(numfmt --to=iec "$root_used")"
  else
    local img_size=$((root_size + 512 * 1024 * 1024))
  fi

  echo
  log "Creating qcow2: $dst (virtual size: $(numfmt --to=iec "$img_size"))"
  qemu-img create -f qcow2 "$dst" "$img_size" >/dev/null

  # ── Attach via nbd ──
  local nbd
  nbd="$(pick_free_nbd)"
  log "Using $nbd"
  USED_NBDS+=("$nbd")

  qemu-nbd --connect="$nbd" "$dst"
  partprobe "$nbd" 2>/dev/null || true
  sleep 1

  # ── Partition the virtual disk ──
  log "Creating partition table…"
  if [[ -n "$boot_part" ]]; then
    # UEFI layout: EFI + root
    parted -s "$nbd" mklabel gpt
    parted -s "$nbd" mkpart "EFI" fat32 1MiB 513MiB
    parted -s "$nbd" set 1 esp on
    parted -s "$nbd" mkpart "ROOT" ext4 513MiB 100%
  else
    # BIOS layout: root only
    parted -s "$nbd" mklabel msdos
    parted -s "$nbd" mkpart primary ext4 1MiB 100%
    parted -s "$nbd" set 1 boot on
  fi

  partprobe "$nbd" 2>/dev/null || true
  sleep 1

  # ── Format and copy ──
  local root_uuid
  root_uuid="$(blkid -s UUID -o value "$root_part" 2>/dev/null)"

  if [[ -n "$boot_part" ]]; then
    # UEFI: format EFI + root
    mkfs.vfat -F 32 -n EFI "${nbd}p1" >/dev/null
    mkfs.ext4 -q -F -U "$root_uuid" "${nbd}p2"

    local mnt_root mnt_boot
    mnt_root="$(mktemp -d)"
    mnt_boot="$(mktemp -d)"
    mount "${nbd}p2" "$mnt_root"
    mkdir -p "$mnt_root/boot/efi"
    mount "${nbd}p1" "$mnt_root/boot/efi"

    # Mount source root partition
    local src_mnt
    src_mnt="$(mktemp -d)"
    mount -o ro "$root_part" "$src_mnt"

    log "Copying root filesystem (this may take a while)…"
    rsync -aHAXS --numeric-ids --info=progress2 \
      --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' \
      --exclude='/run/*' --exclude='/tmp/*' --exclude='/mnt/*' \
      --exclude='/media/*' --exclude='/lost+found' \
      "$src_mnt/" "$mnt_root/"
    umount "$src_mnt"
    rmdir "$src_mnt"

    # Copy EFI partition
    local efi_src_mnt
    efi_src_mnt="$(mktemp -d)"
    mount -o ro "$boot_part" "$efi_src_mnt"
    rsync -aAX --numeric-ids "$efi_src_mnt/" "$mnt_root/boot/efi/"
    umount "$efi_src_mnt"
    rmdir "$efi_src_mnt"

  else
    # BIOS: format root only
    mkfs.ext4 -q -F -U "$root_uuid" "${nbd}p1"

    local mnt_root
    mnt_root="$(mktemp -d)"
    mount "${nbd}p1" "$mnt_root"

    log "Copying root filesystem (this may take a while)…"
    local src_mnt
    src_mnt="$(mktemp -d)"
    mount -o ro "$root_part" "$src_mnt"
    rsync -aHAXS --numeric-ids --info=progress2 \
      --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' \
      --exclude='/run/*' --exclude='/tmp/*' --exclude='/mnt/*' \
      --exclude='/media/*' --exclude='/lost+found' \
      "$src_mnt/" "$mnt_root/"
    umount "$src_mnt"
    rmdir "$src_mnt"
  fi

  # ── Fix fstab ──
  log "Fixing /etc/fstab…"
  awk -v u="$root_uuid" '
  /^[[:space:]]*#/ { print; next }
  NF >= 3 {
    if ($2 == "/") { $1 = "UUID=" u; print; next }
    if ($3 ~ /^(swap|ext2|ext3|ext4|xfs|btrfs|ntfs|vfat|exfat)$/) {
      print "#" $0; next
    }
  }
  { print }
  ' "$mnt_root/etc/fstab" > "$mnt_root/etc/fstab.new"
  mv "$mnt_root/etc/fstab.new" "$mnt_root/etc/fstab"

  # ── Add virtio drivers ──
  log "Adding virtio drivers…"
  mkdir -p "$mnt_root/etc/initramfs-tools"
  for m in virtio_pci virtio_blk virtio_net virtio_scsi; do
    grep -qx "$m" "$mnt_root/etc/initramfs-tools/modules" 2>/dev/null || echo "$m" >> "$mnt_root/etc/initramfs-tools/modules"
  done
  rm -f "$mnt_root/etc/initramfs-tools/conf.d/resume"

  # ── Install GRUB ──
  log "Installing GRUB bootloader…"
  for d in dev dev/pts proc sys run; do
    mkdir -p "$mnt_root/$d"
    mount --bind "/$d" "$mnt_root/$d"
  done

  if [[ -n "$boot_part" ]]; then
    # UEFI GRUB
    chroot "$mnt_root" /bin/bash -c "
      set -e
      export DEBIAN_FRONTEND=noninteractive
      update-initramfs -u -k all || update-initramfs -u
      grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck --force
      update-grub
    "
  else
    # BIOS GRUB
    chroot "$mnt_root" /bin/bash -c "
      set -e
      export DEBIAN_FRONTEND=noninteractive
      update-initramfs -u -k all || update-initramfs -u
      grub-install --target=i386-pc --recheck --force $nbd
      update-grub
    "
  fi

  # ── Cleanup ──
  log "Cleaning up…"
  for d in run sys proc dev/pts dev; do
    umount "$mnt_root/$d" 2>/dev/null || true
  done

  if [[ -n "$boot_part" ]]; then
    umount "$mnt_root/boot/efi" 2>/dev/null || true
  fi
  umount "$mnt_root" 2>/dev/null || true
  rmdir "$mnt_root" 2>/dev/null || true
  if [[ -n "$mnt_boot" ]]; then
    rmdir "$mnt_boot" 2>/dev/null || true
  fi

  qemu-nbd --disconnect "$nbd" 2>/dev/null || true
  # Remove from USED_NBDS
  local tmp_nbds=() x
  for x in "${USED_NBDS[@]}"; do
    [[ "$x" == "$nbd" ]] && continue
    tmp_nbds+=("$x")
  done
  USED_NBDS=("${tmp_nbds[@]}")

  # ── Verify ──
  verify_image "$dst" || warn "Image may have issues."

  echo
  log "🎉 Smart OS Migration complete!"
  echo "   📦 Output: $dst"
  qemu-img info "$dst" || true
  pause
}

