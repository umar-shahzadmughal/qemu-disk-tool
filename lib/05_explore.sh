# ============================================================
# Option 5: Explore/Mount an image (read-only or read-write)
# Uses qemu-nbd to attach image as block device
# Supports: ext4, ntfs, vfat, exfat, and more
# Includes: smart detection (GPT/MBR, UEFI/BIOS)
# ============================================================
explore_mount_image() {
  hr
  echo "🔎 Explore / Mount an image (READ-ONLY recommended)"
  hr

  local img part ro fstype REAL_USER MEDIA_ROOT
  nbd=""          # ✅ Global so trap can access it after function exits
  mp=""           # ✅ Global so trap can access it after function exits
  _CLEANED_UP=0   # ✅ Global so trap can access it after function exits

  img="$(ask_path_existing_file "📥 Enter image path to explore: ")"

  nbd="$(pick_free_nbd)"
  log "Using $nbd"
  [[ "$nbd" =~ ^/dev/nbd[0-9]+$ ]] || die "Bug: NBD picker returned invalid node ($nbd). Must be /dev/nbd<number>."

  mp=""
  part=""
  ro="true"

  REAL_USER="${SUDO_USER:-$USER}"
  MEDIA_ROOT="/media/$REAL_USER"

  cleanup_explore() {
    # run-once guard
    [[ "${_CLEANED_UP:-0}" -eq 1 ]] && return 0
    _CLEANED_UP=1

    # ignore signals during cleanup (prevents re-entry spam)
    trap '' INT TERM

    set +e

    if [[ -n "${mp:-}" ]]; then
      while IFS= read -r t; do
        [[ -n "$t" ]] || continue
        umount "$t" >/dev/null 2>&1 || true
      done < <(
        findmnt -rn -o TARGET |
          awk -v m="$mp" '$0 ~ "^"m {print}' |
          awk '{print length "\t" $0}' |
          sort -nr | cut -f2-
      )

      umount "$mp" >/dev/null 2>&1 || umount -l "$mp" >/dev/null 2>&1 || true
      rmdir "$mp" >/dev/null 2>&1 || true
    fi

    if [[ "${nbd:-}" =~ ^/dev/nbd[0-9]+$ ]]; then
      qemu-nbd --disconnect "$nbd" >/dev/null 2>&1 || true

      # remove from USED_NBDS so we don't touch it later
      if ((${#USED_NBDS[@]})); then
        local tmp=() x
        for x in "${USED_NBDS[@]}"; do
          [[ "$x" == "$nbd" ]] && continue
          tmp+=("$x")
        done
        USED_NBDS=("${tmp[@]}")
      fi
    fi

    # restore signal handlers to normal behavior (global EXIT trap stays as-is)
    trap - INT TERM
  }

  # run cleanup on exit / ctrl+c
  trap cleanup_explore EXIT INT TERM

  ro="$(ask_yesno "🧊 Connect read-only? (safe)" "Y")"

  if [[ "$ro" == "true" ]]; then
    qemu-nbd --read-only --connect="$nbd" "$img" || {
      err "Failed to connect image to $nbd"
      die "Cannot explore image."
    }
  else
    warn "Read-write can corrupt images if you mess up."
    qemu-nbd --connect="$nbd" "$img" || {
      err "Failed to connect image to $nbd"
      die "Cannot explore image."
    }
  fi

  # ✅ only track after successful connect
  USED_NBDS+=("$nbd")

  partprobe "$nbd" 2>/dev/null || true
  sleep 0.5

  hr
  echo "📦 Image Analysis ($nbd):"
  detect_disk_info "$nbd"
  echo
  echo "📦 Partitions inside image ($nbd):"
  lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS "$nbd" || true
  hr

  part="$(pick_partition_from_device "$nbd")"

  mkdir -p "$MEDIA_ROOT"
  local safe_name
  safe_name="$(basename "$img" | tr ' ' '_' | tr -cd '[:alnum:]_.-')"
  mp="$MEDIA_ROOT/QEMU_${safe_name}_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$mp"
  chown "$REAL_USER:$REAL_USER" "$mp" 2>/dev/null || true

  log "Mounting to $mp"

  fstype="$(lsblk -no FSTYPE "$part" 2>/dev/null || true)"

  local mount_ok=true
  if [[ "$ro" == "true" ]]; then
    case "$fstype" in
      ext4)  mount -t ext4 -o ro,noload "$part" "$mp" || mount_ok=false ;;
      ntfs)
        uid="$(id -u "$REAL_USER")"
        gid="$(id -g "$REAL_USER")"
        mount -t ntfs3 -o ro,uid="$uid",gid="$gid" "$part" "$mp" 2>/dev/null || \
        mount -t ntfs-3g -o ro,uid="$uid",gid="$gid" "$part" "$mp" || mount_ok=false
        ;;
      vfat|fat|exfat) mount -o ro "$part" "$mp" || mount_ok=false ;;
      *)              mount -o ro "$part" "$mp" || mount_ok=false ;;
    esac
  else
    mount "$part" "$mp" || mount_ok=false
  fi

  if [[ "$mount_ok" != "true" ]]; then
    err "Mount failed for $part (filesystem: ${fstype:-unknown})"
    warn "Try running Option 15 (Repair) to fix filesystem issues."
    cleanup_explore
    trap global_cleanup EXIT INT TERM
    pause
    return
  fi

  echo
  if [[ "$ro" == "true" ]]; then
    success "Mounted (READ-ONLY 🔒): $mp"
  else
    success "Mounted (READ-WRITE ⚠️): $mp"
  fi
  echo "📌 Open it in your File Manager using this path:"
  echo "    $mp"
  echo "🔗 Or run:"
  echo "    xdg-open \"$mp\""
  echo
  read -rp "⏎ Press Enter to unmount + disconnect… " _ <"$TTY" || true

  cleanup_explore
  trap global_cleanup EXIT INT TERM

  log "Done ✅"
  pause
}

