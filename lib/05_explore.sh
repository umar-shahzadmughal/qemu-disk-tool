# ============================================================
# Option 5: Explore/Mount an image (read-only or read-write)
# Uses qemu-nbd to attach image as block device
# Supports: ext4, ntfs, vfat, exfat, and more
# ============================================================
explore_mount_image() {
  hr
  echo "🔎 Explore / Mount an image (READ-ONLY recommended)"
  hr

  # GLOBALS (prefixed): EXIT/INT traps may fire after this function has
  # returned, when its locals no longer exist — traps must see these.
  _EXP_NBD="" _EXP_MP="" _EXP_CLEANED=0

  # Step 1: Select image
  echo
  echo "📥 Step 1: Select the image file to explore"
  local img
  img="$(ask_path_existing_file "📥 Enter image path to explore: ")"
  log "Source image: $img"

  # Step 2: Access mode
  echo
  echo "🔒 Step 2: Choose access mode"
  local ro
  ro="$(ask_yesno "🧊 Connect read-only? (recommended for safety)" "Y")"

  # Step 3: Connect via NBD
  echo
  echo "🔌 Step 3: Connecting image to virtual block device"
  _EXP_NBD="$(nbd_attach "$img" "$ro")" || {
    err "Failed to attach image"
    _EXP_NBD=""
    return 1
  }
  USED_NBDS+=("$_EXP_NBD")

  # Cleanup: unmount + disconnect + RESTORE GLOBAL TRAPS + restore set -e
  cleanup_explore() {
    [[ "${_EXP_CLEANED:-0}" -eq 1 ]] && return 0
    _EXP_CLEANED=1

    local had_e=0; [[ $- == *e* ]] && had_e=1
    trap '' INT TERM
    set +e

    if [[ -n "${_EXP_MP:-}" && -d "${_EXP_MP:-}" ]]; then
      while IFS= read -r t; do
        [[ -n "$t" ]] || continue
        umount "$t" 2>/dev/null || umount -l "$t" 2>/dev/null || true
      done < <(
        findmnt -rn -o TARGET | awk -v m="$_EXP_MP" '$0 ~ "^"m {print}' |
          awk '{print length "\t" $0}' | sort -nr | cut -f2-
      )
      umount "$_EXP_MP" 2>/dev/null || umount -l "$_EXP_MP" 2>/dev/null || true
      rmdir "$_EXP_MP" 2>/dev/null || true
      _EXP_MP=""
    fi

    [[ -n "${_EXP_NBD:-}" ]] && nbd_release "$_EXP_NBD"
    _EXP_NBD=""

    # Restore global trap system for all later operations
    trap global_cleanup EXIT
    trap 'exit 130' INT TERM
    (( had_e )) && set -e
  }

  trap cleanup_explore EXIT INT TERM

  # Image analysis
  hr
  echo "📦 Image Analysis:"
  detect_disk_info "$_EXP_NBD"
  hr

  # Step 4: Select partition
  echo
  echo "🧩 Step 4: Choose which partition to mount"
  local part
  part="$(pick_partition_from_device "$_EXP_NBD")" || {
    warn "No partition selected"
    cleanup_explore
    return 1
  }

  # Mount point
  local REAL_USER MEDIA_ROOT safe_name
  REAL_USER="${SUDO_USER:-$USER}"
  MEDIA_ROOT="/media/$REAL_USER"
  mkdir -p "$MEDIA_ROOT"
  safe_name="$(basename "$img" | tr ' ' '_' | tr -cd '[:alnum:]_.-')"
  _EXP_MP="$MEDIA_ROOT/QEMU_${safe_name}_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$_EXP_MP"
  chown "$REAL_USER:$REAL_USER" "$_EXP_MP" 2>/dev/null || true

  log "Mounting to $_EXP_MP"

  # Mount with filesystem-specific options
  local fstype mount_ok=true
  fstype="$(lsblk -no FSTYPE "$part" 2>/dev/null || true)"

  if [[ "$ro" == "true" ]]; then
    case "$fstype" in
      ext4)  mount -t ext4 -o ro,noload "$part" "$_EXP_MP" || mount_ok=false ;;
      ntfs)
        local uid gid
        uid="$(id -u "$REAL_USER")"; gid="$(id -g "$REAL_USER")"
        mount -t ntfs3 -o ro,uid="$uid",gid="$gid" "$part" "$_EXP_MP" 2>/dev/null || \
        mount -t ntfs-3g -o ro,uid="$uid",gid="$gid" "$part" "$_EXP_MP" || mount_ok=false
        ;;
      *)     mount -o ro "$part" "$_EXP_MP" || mount_ok=false ;;
    esac
  else
    mount "$part" "$_EXP_MP" || mount_ok=false
  fi

  if [[ "$mount_ok" != "true" ]]; then
    err "Mount failed for $part (filesystem: ${fstype:-unknown})"
    warn "Try running Option 15 (Repair) to fix filesystem issues."
    cleanup_explore
    return 1
  fi

  echo
  if [[ "$ro" == "true" ]]; then
    success "Mounted (READ-ONLY 🔒): $_EXP_MP"
  else
    success "Mounted (READ-WRITE ⚠️): $_EXP_MP"
  fi
  echo "📌 Open it in your File Manager using this path:"
  echo "    $_EXP_MP"
  echo "🔗 Or run:"
  echo "    xdg-open \"$_EXP_MP\""
  echo
  read -rp "⏎ Press Enter to unmount + disconnect… " _ <"$TTY" || true

  cleanup_explore
  log "Done ✅"
  pause
}