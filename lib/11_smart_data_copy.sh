# ============================================================
# Option 11: Smart Data-Level Copy (used blocks only)
# Uses partclone to copy only used filesystem blocks
# Creates much smaller images than block-level copies
# Falls back to rsync if partclone is unavailable
# ============================================================
smart_data_copy() {
  hr
  echo "📦 Smart Data-Level Copy (used blocks only)"
  hr
  warn "Copies ONLY used blocks using partclone, creating smaller images."
  warn "Requires partclone to be installed for the filesystem type."
  echo

  # ── Select source partition ──
  local src
  src="$(pick_block_device part)"
  maybe_unmount "$src"

  # ── Detect filesystem ──
  local fstype
  fstype="$(lsblk -no FSTYPE "$src" 2>/dev/null | head -n1)"
  [[ -n "$fstype" ]] || die "Cannot detect filesystem type on $src"
  log "Detected filesystem: $fstype"

  # ── Check partclone availability ──
  local pc_tool
  pc_tool="$(get_partclone_tool "$fstype")"

  if [[ -z "$pc_tool" ]]; then
    die "Filesystem '$fstype' is not supported by partclone."
  fi

  if ! command -v "$pc_tool" >/dev/null 2>&1; then
    warn "partclone tool not found: $pc_tool"
    echo
    echo "Install with: sudo apt install partclone"
    echo
    local fb_ans
    fb_ans="$(ask_yesno "Fall back to rsync copy?" "Y")"
    [[ "$fb_ans" == "true" ]] || die "Cancelled. Install partclone and try again."
    smart_data_copy_rsync "$src" "$fstype"
    return
  fi

  # ── Ask output format ──
  local dstfmt
  dstfmt="$(ask_format_out)"

  local ext
  case "$dstfmt" in
    qcow2) ext="qcow2" ;; raw) ext="img" ;; vmdk) ext="vmdk" ;;
    vhdx) ext="vhdx" ;; vpc) ext="vhd" ;; *) ext="img" ;;
  esac

  # ── Output path ──
  local dst=""
  local outdir
  outdir="$(suggest_out_dir)"
  local default_path="$outdir/data-copy.$ext"

  if has_gui; then
    local gui_path
    gui_path="$(gui_pick_save_file "Save data copy as" "$default_path")"
    [[ -n "$gui_path" ]] && dst="$gui_path"
  fi

  if [[ -z "$dst" ]]; then
    echo
    echo "   Default: $default_path"
    while true; do
      read -rp "📁 Save as (full path or just filename): " tmp <"$TTY"
      if [[ -z "$tmp" ]]; then dst="$default_path"; break; fi
      if [[ "$tmp" != */* ]]; then dst="$outdir/$tmp"; else dst="$tmp"; fi
      local parent_dir
      parent_dir="$(dirname "$dst")"
      if [[ -d "$parent_dir" ]]; then break; else warn "Directory not found: $parent_dir — try again."; fi
    done
  fi

  if [[ -e "$dst" ]]; then
    warn "File exists: $dst"
    local ow_ans
    ow_ans="$(ask_yesno "Overwrite it?" "N")"
    [[ "$ow_ans" == "true" ]] || die "Cancelled."
    rm -f "$dst"
  fi

  # ── Calculate size from used space ──
  local src_mnt_tmp used_bytes
  src_mnt_tmp="$(mktemp -d)"
  if mount -o ro "$src" "$src_mnt_tmp" 2>/dev/null; then
    used_bytes="$(df -B1 "$src_mnt_tmp" 2>/dev/null | awk 'NR==2 {print $3}')"
    umount "$src_mnt_tmp"
  fi
  rmdir "$src_mnt_tmp" 2>/dev/null || true

  local img_size
  if [[ -n "${used_bytes:-}" && "$used_bytes" =~ ^[0-9]+$ && "$used_bytes" -gt 0 ]]; then
    img_size=$((used_bytes + 512 * 1024 * 1024))
  else
    img_size="$(bytes_of_src "$src")"
  fi

  log "Used data: $(numfmt --to=iec "${used_bytes:-0}")"

  # ── Create image directly if format supports nbd write ──
  local work_img=""
  local need_convert=false

  if [[ "$dstfmt" == "qcow2" || "$dstfmt" == "raw" ]]; then
    work_img="$dst"
    log "Creating $dstfmt image (virtual size: $(numfmt --to=iec "$img_size"))…"
    qemu-img create -f "$dstfmt" "$work_img" "$img_size" >/dev/null
  else
    work_img="${dst}.tmp.qcow2"
    need_convert=true
    log "Creating temporary qcow2 (will convert to $dstfmt after)…"
    qemu-img create -f qcow2 "$work_img" "$img_size" >/dev/null
  fi

  # ── Connect, format, restore via partclone ──
  local nbd
  nbd="$(pick_free_nbd)"
  USED_NBDS+=("$nbd")
  qemu-nbd --connect="$nbd" "$work_img"
  partprobe "$nbd" 2>/dev/null || true
  sleep 1

  parted -s "$nbd" mklabel msdos >/dev/null
  parted -s "$nbd" mkpart primary ext4 1MiB 100% >/dev/null
  partprobe "$nbd" 2>/dev/null || true
  sleep 1

  local root_uuid
  root_uuid="$(blkid -s UUID -o value "$src" 2>/dev/null)"
  mkfs.ext4 -q -F -U "${root_uuid}" "${nbd}p1"

  log "Copying used blocks via $pc_tool (this may take a while)…"
  "$pc_tool" -b -s "$src" -o "${nbd}p1" --nocheck 2>&1 | tee -a "$LOG_FILE" || {
    err "partclone copy failed."
    qemu-nbd --disconnect "$nbd" 2>/dev/null || true
    rm -f "$work_img"
    die "Smart data copy failed. Try Option 15 (Repair) on the source."
  }

  # Disconnect
  qemu-nbd --disconnect "$nbd" 2>/dev/null || true
  local tmp_nbds=() x
  for x in "${USED_NBDS[@]}"; do
    [[ "$x" == "$nbd" ]] && continue
    tmp_nbds+=("$x")
  done
  USED_NBDS=("${tmp_nbds[@]}")

  # ── Convert only if needed (vmdk/vhdx/vhd) ──
  if [[ "$need_convert" == "true" ]]; then
    log "Converting to $dstfmt…"
    qemu-img convert -p -O "$dstfmt" "$work_img" "$dst" || {
      warn "Conversion to $dstfmt failed. Keeping as qcow2."
      mv "$work_img" "$dst"
      dstfmt="qcow2"
    }
    rm -f "$work_img"
  fi

  # ── Verify and report ──
  verify_image "$dst" || warn "Image may have issues. Try Option 15 (Repair)."
  write_image_metadata "$dst" "$src" "Smart data-level copy via partclone ($pc_tool)"

  echo
  success "Smart Data-Level Copy complete!"
  echo "   📦 Output: $dst"
  echo "   🧩 Format: $dstfmt"
  qemu-img info "$dst" 2>/dev/null || true
  echo
  info "💡 Tip: Use Option 6 (Write) to restore this image to a disk."
  pause
}

# ── Fallback rsync-based data copy ──
smart_data_copy_rsync() {
  local src="$1" fstype="$2"

  local dstfmt
  dstfmt="$(ask_format_out)"

  local ext
  case "$dstfmt" in
    qcow2) ext="qcow2" ;; raw) ext="img" ;; vmdk) ext="vmdk" ;;
    vhdx) ext="vhdx" ;; vpc) ext="vhd" ;; *) ext="img" ;;
  esac

  local dst=""
  local outdir
  outdir="$(suggest_out_dir)"
  local default_path="$outdir/data-copy.$ext"

  echo
  echo "   Default: $default_path"
  while true; do
    read -rp "📁 Save as (full path or just filename): " tmp <"$TTY"
    if [[ -z "$tmp" ]]; then dst="$default_path"; break; fi
    if [[ "$tmp" != */* ]]; then dst="$outdir/$tmp"; else dst="$tmp"; fi
    local parent_dir
    parent_dir="$(dirname "$dst")"
    if [[ -d "$parent_dir" ]]; then break; else warn "Directory not found: $parent_dir — try again."; fi
  done

  if [[ -e "$dst" ]]; then
    warn "File exists: $dst"
    local ow_ans
    ow_ans="$(ask_yesno "Overwrite it?" "N")"
    [[ "$ow_ans" == "true" ]] || die "Cancelled."
    rm -f "$dst"
  fi

  # Mount source read-only
  local src_mnt
  src_mnt="$(mktemp -d)"
  mount -o ro "$src" "$src_mnt" || { rmdir "$src_mnt"; die "Cannot mount $src"; }

  local used_bytes
  used_bytes="$(df -B1 "$src_mnt" | awk 'NR==2 {print $3}')"
  local img_size=$((used_bytes + 256 * 1024 * 1024))

  log "Used data: $(numfmt --to=iec "$used_bytes")"

  local work_img="" need_convert=false
  if [[ "$dstfmt" == "qcow2" || "$dstfmt" == "raw" ]]; then
    work_img="$dst"
    qemu-img create -f "$dstfmt" "$work_img" "$img_size" >/dev/null
  else
    work_img="${dst}.tmp.qcow2"
    need_convert=true
    qemu-img create -f qcow2 "$work_img" "$img_size" >/dev/null
  fi

  local nbd
  nbd="$(pick_free_nbd)"
  USED_NBDS+=("$nbd")
  qemu-nbd --connect="$nbd" "$work_img"
  partprobe "$nbd" 2>/dev/null || true
  sleep 1

  parted -s "$nbd" mklabel msdos >/dev/null
  parted -s "$nbd" mkpart primary ext4 1MiB 100% >/dev/null
  partprobe "$nbd" 2>/dev/null || true
  sleep 1

  local root_uuid
  root_uuid="$(blkid -s UUID -o value "$src" 2>/dev/null)"
  mkfs.ext4 -q -F -U "${root_uuid}" "${nbd}p1"

  local dst_mnt
  dst_mnt="$(mktemp -d)"
  mount "${nbd}p1" "$dst_mnt"

  log "Copying files via rsync…"
  rsync -aHAXS --numeric-ids --info=progress2 \
    --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' \
    --exclude='/run/*' --exclude='/tmp/*' --exclude='/mnt/*' \
    --exclude='/media/*' --exclude='/lost+found' \
    "$src_mnt/" "$dst_mnt/"

  umount "$dst_mnt"
  rmdir "$dst_mnt"
  umount "$src_mnt"
  rmdir "$src_mnt"

  qemu-nbd --disconnect "$nbd" 2>/dev/null || true
  local tmp_nbds=() x
  for x in "${USED_NBDS[@]}"; do
    [[ "$x" == "$nbd" ]] && continue
    tmp_nbds+=("$x")
  done
  USED_NBDS=("${tmp_nbds[@]}")

  if [[ "$need_convert" == "true" ]]; then
    log "Converting to $dstfmt…"
    qemu-img convert -p -O "$dstfmt" "$work_img" "$dst" || {
      warn "Conversion failed. Keeping as qcow2."
      mv "$work_img" "$dst"
      dstfmt="qcow2"
    }
    rm -f "$work_img"
  fi

  verify_image "$dst" || warn "Image may have issues. Try Option 15 (Repair)."
  write_image_metadata "$dst" "$src" "Smart data-level copy via rsync fallback"

  echo
  success "Smart Data-Level Copy (rsync fallback) complete!"
  echo "   📦 Output: $dst"
  echo "   🧩 Format: $dstfmt"
  qemu-img info "$dst" 2>/dev/null || true
  pause
}
