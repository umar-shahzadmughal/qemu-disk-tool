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
  warn "The source partition must be UNMOUNTED for a consistent copy."
  echo

  local tool missing_tool=""
  # mkfs.btrfs / mkfs.xfs are only needed for those source filesystems.
  # Their absence is caught at the point of use in the format case-block
  # below with a targeted error message, not as a blanket preflight failure.
  for tool in qemu-img qemu-nbd parted mkfs.ext4 e2fsck blkid; do
    have "$tool" || missing_tool+=" $tool"
  done
  if [[ -n "$missing_tool" ]]; then
    err "Missing required tools:$missing_tool"
    return 1
  fi

  # ── Cleanup state (globals for cleanup hook) ──
  _DLC_NBD="" _DLC_WORK_IMG="" _DLC_SRC_MNT="" _DLC_CLEANED=0 _DLC_FAST=0

  dlc_cleanup() {
    [[ "${_DLC_CLEANED:-0}" -eq 1 ]] && return 0
    _DLC_CLEANED=1
    local had_e=0; [[ $- == *e* ]] && had_e=1
    set +e
    if [[ -n "${_DLC_SRC_MNT:-}" ]]; then
      umount "${_DLC_SRC_MNT}" 2>/dev/null || true
      rmdir "${_DLC_SRC_MNT}" 2>/dev/null || true
    fi
    _DLC_SRC_MNT=""
    if [[ -n "${_DLC_NBD:-}" ]]; then
      if (( ${_DLC_FAST:-0} == 1 )); then
        nbd_kill "${_DLC_NBD}"
      else
        nbd_release "${_DLC_NBD}"
      fi
    fi
    _DLC_NBD=""

    # Auto-delete work image on fast cleanup (cancel/error).
    if (( ${_DLC_FAST:-0} == 1 )) && [[ -n "${_DLC_WORK_IMG:-}" ]]; then
      rm -f "${_DLC_WORK_IMG}" 2>/dev/null
    fi
    _DLC_WORK_IMG=""

    (( had_e )) && set -e
    return 0
  }
  cleanup_unregister dlc_cleanup 2>/dev/null
  register_cleanup dlc_cleanup

  # ── Step 1: Select source partition ──
  echo
  echo "💽 Step 1: Select the SOURCE partition"
  local src
  src="$(pick_block_device part)" || { cleanup_unregister dlc_cleanup; return 1; }

  # ── Step 2: Detect filesystem ──
  local fstype
  fstype="$(lsblk -no FSTYPE "$src" 2>/dev/null | head -n1)"
  if [[ -z "$fstype" ]]; then
    err "Cannot detect filesystem type on $src"
    cleanup_unregister dlc_cleanup
    return 1
  fi
  log "Detected filesystem: $fstype"

  local pc_tool
  pc_tool="$(get_partclone_tool "$fstype")"
  if [[ -z "$pc_tool" ]]; then
    err "Filesystem '$fstype' is not supported by partclone."
    cleanup_unregister dlc_cleanup
    return 1
  fi

  if ! command -v "$pc_tool" >/dev/null 2>&1; then
    warn "partclone tool not found: $pc_tool"
    echo
    echo "   Install with: sudo apt install partclone"
    echo
    local fb_ans
    fb_ans="$(ask_yesno "Fall back to rsync file-level copy?" "Y")"
    if [[ "$fb_ans" == "true" ]]; then
      cleanup_unregister dlc_cleanup
      smart_data_copy_rsync "$src"
      return $?
    fi
    user_cancel "Install partclone and try again."
    cleanup_unregister dlc_cleanup
    return 1
  fi

  # ── Step 3: Ensure source is unmounted ──
  if ! maybe_unmount "$src"; then
    err "Source partition $src is mounted and cannot be unmounted."
    err "partclone requires an unmounted source for a consistent copy."
    tip "Unmount it first, or boot from a Live USB, or use Option 10 for live file-level migration."
    cleanup_unregister dlc_cleanup
    return 1
  fi

  # ── Step 4: Measure used space and compute image size ──
  # partclone preserves the original filesystem geometry (block offsets, superblock,
  # inode tables, journal), so the VIRTUAL disk size MUST equal the source partition
  # size. The qcow2 file stays small on disk because only used blocks are written.
  # Add 4 MiB headroom so the partition (which starts at 1 MiB) is ≥ source size.
  local src_mnt_tmp used_bytes=""
  src_mnt_tmp="$(mktemp -d)"
  if mount_ro_fs "$src" "$src_mnt_tmp" true; then
    used_bytes="$(df -B1 "$src_mnt_tmp" 2>/dev/null | awk 'NR==2 {print $3}')"
    umount "$src_mnt_tmp" 2>/dev/null || true
  fi
  rmdir "$src_mnt_tmp" 2>/dev/null || true

  local img_size
  img_size=$(( $(bytes_of_src "$src") + 4*1024*1024 ))
  if [[ -n "$used_bytes" && "$used_bytes" =~ ^[0-9]+$ && "$used_bytes" -gt 0 ]]; then
    info "Used data: $(numfmt --to=iec "$used_bytes") of $(numfmt --to=iec "$img_size") total"
    info "Image virtual size: $(numfmt --to=iec "$img_size") (qcow2 will be sparse, ~$(numfmt --to=iec "$used_bytes") on disk)"
  else
    warn "Could not measure used space; using full partition size $(numfmt --to=iec "$img_size")."
  fi

  # ── Step 5: Output format + path ──
  local dstfmt
  dstfmt="$(ask_format_out)"
  local ext
  ext="$(fmt_to_ext "$dstfmt")"

  local dst=""
  local outdir default_path
  outdir="$(suggest_out_dir)"
  default_path="$outdir/data-copy.$ext"

  # On-disk size depends on format sparsity.
  local on_disk_estimate
  case "$dstfmt" in
    raw)
      on_disk_estimate="$img_size"                    # raw is 1:1
      ;;
    *)
      # Sparse formats: approximate on-disk bytes from used data + margin.
      local _u="${used_bytes:-$img_size}"
      on_disk_estimate=$(( _u * 110 / 100 + 512*1024*1024 ))
      # Never demand more than the virtual size.
      (( on_disk_estimate > img_size )) && on_disk_estimate="$img_size"
      ;;
  esac

  dst="$(ask_save_path "$default_path" "$ext" "$on_disk_estimate")" || { cleanup_unregister dlc_cleanup; return 1; }

  # ── Step 6: Create image ──
  echo
  echo "🏗️  Step 2: Building image and copying used blocks"
  local start_ts; start_ts="$(date +%s)"

  local work_img="" need_convert=false
  if [[ "$dstfmt" == "qcow2" || "$dstfmt" == "raw" ]]; then
    work_img="$dst"
    log "Creating $dstfmt image (virtual size: $(numfmt --to=iec "$img_size"))…"
    qemu-img create -f "$dstfmt" "$work_img" "$img_size" >&2 || {
      err "qemu-img create failed."
      cleanup_unregister dlc_cleanup
      rm -f "$dst"
      return 1
    }
  else
    work_img="${dst}.tmp.qcow2"
    need_convert=true
    _DLC_WORK_IMG="$work_img"
    log "Creating temporary qcow2 (will convert to $dstfmt after)…"
    qemu-img create -f qcow2 "$work_img" "$img_size" >&2 || {
      err "qemu-img create failed."
      cleanup_unregister dlc_cleanup
      rm -f "$work_img"
      return 1
    }
  fi

  # ── Step 7: Attach, partition, format ──
  _DLC_NBD="$(nbd_attach "$work_img" false)" || {
    err "Failed to attach image."
    cleanup_unregister dlc_cleanup
    rm -f "$work_img"
    return 1
  }
  USED_NBDS+=("$_DLC_NBD")
  local nbd="$_DLC_NBD"

  parted -s "$nbd" mklabel msdos >/dev/null 2>&1 || {
    err "Partitioning failed."
    _DLC_FAST=1
    dlc_cleanup
    cleanup_unregister dlc_cleanup
    rm -f "$work_img"
    return 1
  }
  parted -s "$nbd" mkpart primary ext4 1MiB 100% >/dev/null 2>&1
  partprobe "$nbd" 2>/dev/null || true
  sleep 1

  if [[ ! -b "${nbd}p1" ]]; then
    err "Partition ${nbd}p1 did not appear."
    _DLC_FAST=1
    dlc_cleanup
    cleanup_unregister dlc_cleanup
    rm -f "$work_img"
    return 1
  fi

  local root_uuid
  root_uuid="$(blkid -s UUID -o value "$src" 2>/dev/null || true)"

  # Format the target to match the source filesystem family.
  # partclone overwrites every used block, but a matching pre-format ensures
  # consistent superblocks and correct UUID handling.
  case "$fstype" in
    ext2|ext3|ext4)
      if [[ -n "$root_uuid" ]]; then
        mkfs.ext4 -q -F -U "$root_uuid" "${nbd}p1" >/dev/null 2>&1 || {
          err "mkfs.ext4 failed."
          _DLC_FAST=1; dlc_cleanup; cleanup_unregister dlc_cleanup
          rm -f "$work_img"; return 1
        }
      else
        mkfs.ext4 -q -F "${nbd}p1" >/dev/null 2>&1 || {
          err "mkfs.ext4 failed."
          _DLC_FAST=1; dlc_cleanup; cleanup_unregister dlc_cleanup
          rm -f "$work_img"; return 1
        }
      fi
      ;;
    btrfs)
      mkfs.btrfs -f "${nbd}p1" >/dev/null 2>&1 || {
        err "mkfs.btrfs failed."
        _DLC_FAST=1; dlc_cleanup; cleanup_unregister dlc_cleanup
        rm -f "$work_img"; return 1
      }
      ;;
    xfs)
      mkfs.xfs -f "${nbd}p1" >/dev/null 2>&1 || {
        err "mkfs.xfs failed."
        _DLC_FAST=1; dlc_cleanup; cleanup_unregister dlc_cleanup
        rm -f "$work_img"; return 1
      }
      ;;
    *)
      # Leave unformatted; partclone writes all used blocks including metadata.
      info "Skipping pre-format for $fstype (partclone will write filesystem structure)."
      ;;
  esac

  # ── Step 8: Copy used blocks with progress bar ──
  local copy_total="${used_bytes:-$img_size}" rc=0
  PB_EMOJI="📦"
  PB_DEV="$nbd"   # whole-disk: partition stats may not exist on older kernels
  PB_TOTAL="$copy_total"
  if [[ "$need_convert" == "true" ]]; then
    PB_HEADER="$(basename "$src") → $(basename "$work_img")"
  else
    PB_HEADER="$(basename "$src") → $(basename "$dst")"
  fi
  PB_SUBLINE="partclone used-block copy · $(numfmt --to=iec "$copy_total")"

  # Preflight: verify source filesystem integrity for ext-family sources only.
  # Other filesystems (btrfs/xfs/etc.) have their own checkers; partclone's
  # built-in check (enabled now that --nocheck was removed) covers them.
  case "$fstype" in
    ext2|ext3|ext4)
      log "Checking source filesystem integrity (e2fsck -fn)…"
      if ! e2fsck -fn "$src" >/dev/null 2>&1; then
        err "Source filesystem has errors. Run Option 15 (Repair) on $src first."
        _DLC_FAST=1
        dlc_cleanup
        cleanup_unregister dlc_cleanup
        rm -f "$work_img" 2>/dev/null
        return 1
      fi
      ;;
    *)
      info "Skipping ext-specific integrity preflight for $fstype (partclone will verify)."
      ;;
  esac

  log "Copying used blocks via $pc_tool…"
  run_with_progress_bar "Copying used blocks…" "$copy_total" \
    "$pc_tool" -c -s "$src" -o "${nbd}p1" --overwrite || rc=$?

  unset PB_DEV PB_TOTAL PB_HEADER PB_SUBLINE PB_EMOJI

  if (( rc == 130 )); then
    local keep
    keep="$(ask_yesno "Copy cancelled. Keep the partial image?" "N")"
    if [[ "$keep" == "true" ]]; then
      info "Partial image kept at: $work_img"
      dlc_cleanup
    else
      info "Removing incomplete image."
      _DLC_FAST=1
      dlc_cleanup
      rm -f "$work_img" 2>/dev/null
    fi
    cleanup_unregister dlc_cleanup
    return 1
  elif (( rc != 0 )); then
    err "partclone copy failed (exit $rc)."
    tip "Try Option 15 (Repair) on the source, or check the source filesystem health."
    _DLC_FAST=1
    dlc_cleanup
    cleanup_unregister dlc_cleanup
    rm -f "$work_img" 2>/dev/null
    return 1
  fi

  # ── Step 9: Disconnect + convert ──
  dlc_cleanup
  cleanup_unregister dlc_cleanup

  if [[ "$need_convert" == "true" ]]; then
    log "Converting to $dstfmt…"
    if ! qemu-img convert -p -O "$dstfmt" "$work_img" "$dst" 2>/dev/null; then
      warn "Conversion to $dstfmt failed. Keeping as qcow2."
      if ! mv "$work_img" "$dst" 2>/dev/null; then
        err "Failed to move $work_img to $dst"
        err "Your image is still available at: $work_img"
        return 1
      fi
      dstfmt="qcow2"
    else
      rm -f "$work_img" 2>/dev/null
    fi
  fi

  # ── Step 10: Verify + report (std_ending handles this) ──
  echo
  success "Smart Data-Level Copy complete!"
  std_ending "Smart data-level copy" "$src" "$dst" "$start_ts"
}


# ── Fallback rsync-based data copy ──
smart_data_copy_rsync() {
  local src="$1"

  hr
  echo "📦 Smart Data-Level Copy — rsync fallback"
  hr

  # btrfs subvolume layouts (@, @home, etc.) are invisible to a plain mount.
  # The rsync fallback would copy empty directories and produce a broken image.
  local _src_fs
  _src_fs="$(lsblk -no FSTYPE "$src" 2>/dev/null | head -n1)"
  if [[ "$_src_fs" == "btrfs" ]]; then
    warn "Source is btrfs — the rsync fallback cannot see subvolume contents reliably."
    tip "Install partclone (sudo apt install partclone) and use the primary copy path."
    return 1
  fi

  local dstfmt
  dstfmt="$(ask_format_out)"
  local ext
  ext="$(fmt_to_ext "$dstfmt")"

  # ── Cleanup state (globals for cleanup hook) ──
  _DLC_NBD="" _DLC_WORK_IMG="" _DLC_SRC_MNT="" _DLC_DST_MNT="" _DLC_CLEANED=0 _DLC_FAST=0

  dlc_cleanup() {
    [[ "${_DLC_CLEANED:-0}" -eq 1 ]] && return 0
    _DLC_CLEANED=1
    local had_e=0; [[ $- == *e* ]] && had_e=1
    set +e

    # Unmount target first, then source (reverse of mount order).
    if [[ -n "${_DLC_DST_MNT:-}" ]]; then
      umount "${_DLC_DST_MNT}" 2>/dev/null || true
      rmdir "${_DLC_DST_MNT}" 2>/dev/null || true
    fi
    _DLC_DST_MNT=""

    if [[ -n "${_DLC_SRC_MNT:-}" ]]; then
      umount "${_DLC_SRC_MNT}" 2>/dev/null || true
      rmdir "${_DLC_SRC_MNT}" 2>/dev/null || true
    fi
    _DLC_SRC_MNT=""

    # Release nbd: fast path kills (image discarded), normal path flushes.
    if [[ -n "${_DLC_NBD:-}" ]]; then
      if (( ${_DLC_FAST:-0} == 1 )); then
        nbd_kill "${_DLC_NBD}"
      else
        nbd_release "${_DLC_NBD}"
      fi
    fi
    _DLC_NBD=""

    # Auto-delete work image on fast cleanup (cancel/error).
    if (( ${_DLC_FAST:-0} == 1 )) && [[ -n "${_DLC_WORK_IMG:-}" ]]; then
      rm -f "${_DLC_WORK_IMG}" 2>/dev/null
    fi
    _DLC_WORK_IMG=""

    (( had_e )) && set -e
    return 0
  }
  cleanup_unregister dlc_cleanup 2>/dev/null
  register_cleanup dlc_cleanup

  # ── Mount source read-only ──
  _DLC_SRC_MNT="$(mktemp -d)"
  if ! mount_ro_fs "$src" "$_DLC_SRC_MNT" true; then
    err "Cannot mount $src read-only."
    rmdir "$_DLC_SRC_MNT" 2>/dev/null
    _DLC_SRC_MNT=""
    cleanup_unregister dlc_cleanup
    return 1
  fi

  # ── Measure used space and compute image size ──
  # For rsync fallback, we don't need to preserve block offsets, so we can size
  # the image to used data + margin (like Option 10).
  local used_bytes
  used_bytes="$(df -B1 "$_DLC_SRC_MNT" 2>/dev/null | awk 'NR==2 {print $3}')"
  local img_size
  if [[ -n "$used_bytes" && "$used_bytes" =~ ^[0-9]+$ && "$used_bytes" -gt 0 ]]; then
    img_size=$(( used_bytes * 120 / 100 + 5*1024*1024*1024 ))
    info "Used data: $(numfmt --to=iec "$used_bytes") → image size $(numfmt --to=iec "$img_size")"
  else
    img_size="$(bytes_of_src "$src")"
    warn "Could not measure used space; using full partition size $(numfmt --to=iec "$img_size")."
  fi

  local dst=""
  local outdir default_path
  outdir="$(suggest_out_dir)"
  default_path="$outdir/data-copy.$ext"
  dst="$(ask_save_path "$default_path" "$ext" "$img_size")" || {
    dlc_cleanup
    cleanup_unregister dlc_cleanup
    return 1
  }

  # ── Create image ──
  local work_img="" need_convert=false
  if [[ "$dstfmt" == "qcow2" || "$dstfmt" == "raw" ]]; then
    work_img="$dst"
    qemu-img create -f "$dstfmt" "$work_img" "$img_size" >&2 || {
      err "qemu-img create failed."
      _DLC_FAST=1
      dlc_cleanup
      cleanup_unregister dlc_cleanup
      rm -f "$dst"
      return 1
    }
  else
    work_img="${dst}.tmp.qcow2"
    need_convert=true
    _DLC_WORK_IMG="$work_img"
    qemu-img create -f qcow2 "$work_img" "$img_size" >&2 || {
      err "qemu-img create failed."
      _DLC_FAST=1
      dlc_cleanup
      cleanup_unregister dlc_cleanup
      rm -f "$work_img"
      return 1
    }
  fi

  # ── Attach + partition + format ──
  _DLC_NBD="$(nbd_attach "$work_img" false)" || {
    err "Failed to attach image."
    _DLC_FAST=1
    dlc_cleanup
    cleanup_unregister dlc_cleanup
    return 1
  }
  USED_NBDS+=("$_DLC_NBD")
  local nbd="$_DLC_NBD"

  parted -s "$nbd" mklabel msdos >/dev/null 2>&1
  parted -s "$nbd" mkpart primary ext4 1MiB 100% >/dev/null 2>&1
  partprobe "$nbd" 2>/dev/null || true
  sleep 1

  [[ -b "${nbd}p1" ]] || {
    err "Partition ${nbd}p1 did not appear."
    _DLC_FAST=1
    dlc_cleanup
    cleanup_unregister dlc_cleanup
    rm -f "$work_img"
    return 1
  }

  local root_uuid
  root_uuid="$(blkid -s UUID -o value "$src" 2>/dev/null || true)"
  if [[ -n "$root_uuid" ]]; then
    mkfs.ext4 -q -F -U "$root_uuid" "${nbd}p1" >/dev/null 2>&1 || {
      err "mkfs.ext4 failed."
      _DLC_FAST=1
      dlc_cleanup
      cleanup_unregister dlc_cleanup
      rm -f "$work_img"
      return 1
    }
  else
    mkfs.ext4 -q -F "${nbd}p1" >/dev/null 2>&1 || {
      err "mkfs.ext4 failed."
      _DLC_FAST=1
      dlc_cleanup
      cleanup_unregister dlc_cleanup
      rm -f "$work_img"
      return 1
    }
  fi

  _DLC_DST_MNT="$(mktemp -d)"
  mount "${nbd}p1" "$_DLC_DST_MNT" || {
    err "Cannot mount target partition."
    _DLC_FAST=1
    dlc_cleanup
    cleanup_unregister dlc_cleanup
    rm -f "$work_img"
    return 1
  }

  # ── rsync with progress bar ──
  local copy_total="${used_bytes:-$img_size}" rc=0
  PB_EMOJI="📦"
  PB_DEV="$nbd"  # whole-disk: partition stats may not exist on older kernels
  PB_TOTAL="$copy_total"
  if [[ "$need_convert" == "true" ]]; then
    PB_HEADER="$(basename "$src") → $(basename "$work_img")"
  else
    PB_HEADER="$(basename "$src") → $(basename "$dst")"
  fi
  PB_SUBLINE="rsync fallback · $(numfmt --to=iec "$copy_total")"

  run_with_progress_bar "Copying files…" "$copy_total" \
    rsync -aHAXSx --numeric-ids \
      --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' \
      --exclude='/run/*' --exclude='/tmp/*' --exclude='/mnt/*' \
      --exclude='/media/*' --exclude='/lost+found' \
      "$_DLC_SRC_MNT/" "$_DLC_DST_MNT/" || rc=$?

  unset PB_DEV PB_TOTAL PB_HEADER PB_SUBLINE PB_EMOJI

  if (( rc == 130 )); then
    local keep
    keep="$(ask_yesno "Copy cancelled. Keep the partial image?" "N")"
    if [[ "$keep" == "true" ]]; then
      info "Partial image kept at: $work_img"
      dlc_cleanup
    else
      info "Removing incomplete image."
      _DLC_FAST=1
      dlc_cleanup
      rm -f "$work_img" 2>/dev/null
    fi
    cleanup_unregister dlc_cleanup
    return 1
  elif (( rc == 24 )); then
    warn "rsync reported vanished source files (exit 24) — likely benign for this copy."
  elif (( rc == 23 )); then
    err "rsync reported a partial transfer due to copy errors (exit 23)."
    err "The image is not considered complete."
    warn "The partial image has been KEPT at: $work_img"
    dlc_cleanup
    cleanup_unregister dlc_cleanup
    return 1
  elif (( rc != 0 )); then
    err "rsync copy failed (exit $rc)."
    _DLC_FAST=1
    dlc_cleanup
    cleanup_unregister dlc_cleanup
    rm -f "$work_img" 2>/dev/null
    return 1
  fi

  # ── Cleanup + convert ──
  dlc_cleanup
  cleanup_unregister dlc_cleanup

  if [[ "$need_convert" == "true" ]]; then
    log "Converting to $dstfmt…"
    if ! qemu-img convert -p -O "$dstfmt" "$work_img" "$dst" 2>/dev/null; then
      warn "Conversion to $dstfmt failed. Keeping as qcow2."
      if ! mv "$work_img" "$dst" 2>/dev/null; then
        err "Failed to move $work_img to $dst"
        err "Your image is still available at: $work_img"
        return 1
      fi
      dstfmt="qcow2"
    else
      rm -f "$work_img" 2>/dev/null
    fi
  fi

  echo
  success "Smart Data-Level Copy (rsync fallback) complete!"
  std_ending "Smart data-level copy (rsync)" "$src" "$dst" "$(date +%s)"
}