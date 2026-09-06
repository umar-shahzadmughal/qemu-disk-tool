# ============================================================
# Option 6: Write an image back to a real disk/partition
# DESTRUCTIVE: Wipes target device completely
# Includes: size check, verification, double confirmation,
#           real-time progress bar, compressed image support
# ============================================================
write_image_to_device() {
  hr
  echo "🧨 Write an image BACK to a real disk/partition (DESTRUCTIVE)"
  hr

  local img target t

  img="$(ask_path_existing_file "📥 Enter image path to write: ")"

  echo "Target type:"
  echo "  [1] Whole disk  💽 (wipes everything)"
  echo "  [2] Partition   🧩 (wipes only that partition)"
  read -rp "➡️  Enter number (1-2): " t <"$TTY"

  case "$t" in
    1) target="$(pick_block_device disk)" ;;
    2) target="$(pick_block_device part)" ;;
    *) die "Invalid choice." ;;
  esac

  maybe_unmount "$target"

  hr
  echo "🔥 FINAL WARNING"
  echo "   Image : $img"
  echo "   Target: $target"
  echo
  echo "📌 Target details:"
  lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL "$target" 2>/dev/null | sed 's/\\x20/ /g' || true
  hr

  echo "To continue, type the target EXACTLY (or 'cancel' to abort):"
  echo "   $target"
  local confirm1
  while true; do
    read -rp "✍️  Type target path: " confirm1 <"$TTY"
    if [[ "$confirm1" == "$target" ]]; then
      break
    elif [[ "${confirm1,,}" == "cancel" || "${confirm1,,}" == "q" ]]; then
      die "Aborted by user."
    else
      warn "Mismatch! Please type exactly: $target"
    fi
  done

  echo
  echo "Now type: WIPE (or 'cancel' to abort)"
  local confirm2
  while true; do
    read -rp "✍️  Type WIPE: " confirm2 <"$TTY"
    if [[ "$confirm2" == "WIPE" ]]; then
      break
    elif [[ "${confirm2,,}" == "cancel" || "${confirm2,,}" == "q" ]]; then
      die "Aborted by user."
    else
      warn "Mismatch! You must type exactly: WIPE"
    fi
  done

  if has_gui; then
    if ! gui_confirm "DESTRUCTIVE WRITE" "You are about to write to:\n$target\n\nThis will ERASE ALL DATA on the target.\n\nAre you absolutely sure?"; then
      die "Cancelled via GUI confirmation."
    fi
  fi

  # ── Size check ──
  local img_size target_size
  img_size="$(img_virtual_bytes "$img" 2>/dev/null || echo 0)"
  target_size="$(bytes_of_src "$target" 2>/dev/null || echo 0)"

  if [[ "$img_size" =~ ^[0-9]+$ && "$target_size" =~ ^[0-9]+$ && "$img_size" -gt "$target_size" ]]; then
    echo
    warn "⚠️  Image virtual size: $(numfmt --to=iec "$img_size")"
    warn "⚠️  Target device size: $(numfmt --to=iec "$target_size")"
    echo
    warn "The image is LARGER than the target device."
    echo
    echo "  💡 Tip: Use Option 12 (Resize/Shrink Image) to reduce the image size first."
    echo
    local cont_ans
    cont_ans="$(ask_yesno "Continue anyway?" "N")"
    [[ "$cont_ans" == "true" ]] || die "Cancelled due to size mismatch."
  fi

  # ── Verify source image (once) ──
  if ! verify_image "$img"; then
    warn "Source image has issues. Writing a corrupted image may brick the target."
    local cont_ans2
    cont_ans2="$(ask_yesno "Continue anyway?" "N")"
    [[ "$cont_ans2" == "true" ]] || die "Cancelled due to image verification failure."
  fi

  # ── Build command ──
  local is_compressed=false
  if qemu-img info "$img" 2>/dev/null | grep -qi "compress"; then
    is_compressed=true
    log "Compressed image detected — using low-memory mode (-m 1)"
  fi

  local convert_args=(qemu-img convert -p)
  if [[ "$is_compressed" == "true" ]]; then
    convert_args+=(-m 1)
  fi
  convert_args+=(-O raw "$img" "$target")

  # ── Run via shared progress engine (smooth kernel-stat mode) ──
  # PB_DEV    → kernel write counters = true 0.1% updates (no 2% gap)
  # PB_TOTAL  → image virtual size (bytes actually written by convert)
  # PB_HEADER → dashboard title line
  PB_DEV="$target"
  PB_TOTAL="$img_size"
  PB_HEADER="$(basename "$img") → $target"
  run_with_progress_bar "Writing (image → raw → device)…" "$img_size" "${convert_args[@]}"
  local rc=$?
  unset PB_DEV PB_TOTAL PB_HEADER

  if [[ $rc -ne 0 ]]; then
    err "Write failed (exit code: $rc)"
    echo
    warn "Possible causes and fixes:"
    echo "  1. If you saw 'Cannot allocate memory':"
    echo "     • Increase available RAM (WSL: edit .wslconfig → memory=...)"
    echo "     • Close other applications to free RAM"
    echo "     • Retry manually with: qemu-img convert -p -n -m 1 -O raw \"$img\" \"$target\""
    echo "  2. Check target device health and free space"
    echo "  3. Verify the source image: qemu-img check \"$img\""
    echo
    die "Write failed. Target device may be partially written."
  fi

  sync
  local parent
  parent="$(lsblk -no PKNAME "$target" 2>/dev/null || true)"
  if [[ -n "$parent" ]]; then
    partprobe "/dev/$parent" 2>/dev/null || true
  else
    partprobe "$target" 2>/dev/null || true
  fi

  echo
  success "Restore complete: $img → $target"
  echo
  lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS "$target" 2>/dev/null | sed 's/\\x20/ /g' || true
  echo
  info "💡 Tip: Run Option 15 (Repair) if the restored disk doesn't boot."
  _write_log "WRITE" "$img → $target"
  pause
}