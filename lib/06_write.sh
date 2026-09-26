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

  # ── Step 1: Source image ──
  echo
  echo "📥 Step 1: Select the image file to restore"
  local img
  img="$(ask_path_existing_file "📥 Enter image path to write: ")"
  log "Source image: $img"

  # ── Step 2: Target ──
  echo
  echo "💽 Step 2: Select the TARGET device (will be erased)"
  echo "  [1] Whole disk  💽 (wipes everything)"
  echo "  [2] Partition   🧩 (wipes only that partition)"
  local t target
  read -rp "➡️  Enter number (1-2): " t <"$TTY"
  case "$t" in
    1) target="$(pick_block_device disk)" ;;
    2) target="$(pick_block_device part)" ;;
    *) die "Invalid choice." ;;
  esac

  local target_size_early
  target_size_early="$(bytes_of_src "$target" 2>/dev/null || echo 0)"
  if (( target_size_early == 0 )); then
    err "Target $target reports size 0 — empty card reader or unplugged media?"
    return 1
  fi

  # ── Guard: image must NOT live on any physical disk behind the target ──
  local img_src
  img_src="$(findmnt -no SOURCE --target "$(dirname "$img")" 2>/dev/null || true)"
  if [[ -b "$img_src" ]]; then
    local -a img_disks tgt_disks shared
    mapfile -t img_disks < <(phys_disks_of "$img_src")
    mapfile -t tgt_disks < <(phys_disks_of "$target")
    mapfile -t shared < <(comm -12 <(printf '%s\n' "${img_disks[@]}") \
                                 <(printf '%s\n' "${tgt_disks[@]}"))
    if (( ${#shared[@]} )); then
      err "Refusing: the image file is stored on the same physical disk(s): ${shared[*]}"
      warn "Writing would destroy the source image mid-operation. Copy it to another disk first."
      return 1
    fi
  fi

  maybe_unmount "$target" || return 1

  # ── Step 3: Final confirmation ──
  hr
  echo "🔥 FINAL WARNING"
  echo "   Image : $img"
  echo "   Target: $target"
  echo
  echo "📌 Target details:"
  lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL "$target" 2>/dev/null | sed 's/\\x20/ /g' || true
  hr

  echo "To continue, type the target EXACTLY (Enter/'cancel' aborts):"
  echo "   $target"
  confirm_typed "$target" "Type target path:" true || return 1

  echo
  echo "Now type: WIPE"
  confirm_typed "WIPE" "Type WIPE to confirm:" true || return 1

  if has_gui; then
    if ! gui_confirm "DESTRUCTIVE WRITE" "You are about to write to:\n$target\n\nThis will ERASE ALL DATA on the target.\n\nAre you absolutely sure?"; then
      user_cancel "Cancelled via GUI confirmation."
      return 1
    fi
  fi

  # ── Size check ──
  local img_size target_size
  img_size="$(img_virtual_bytes "$img" 2>/dev/null || echo 0)"
  target_size="$(bytes_of_src "$target" 2>/dev/null || echo 0)"

  if [[ "$img_size" =~ ^[0-9]+$ && "$target_size" =~ ^[0-9]+$ && "$img_size" -gt "$target_size" ]]; then
    echo
    warn "Image virtual size: $(numfmt --to=iec "$img_size")"
    warn "Target device size: $(numfmt --to=iec "$target_size")"
    echo
    warn "The image is LARGER than the target device."
    tip "Use Option 12 (Resize/Shrink Image) to reduce the image size first."
    echo
    local cont_ans
    cont_ans="$(ask_yesno "Continue anyway?" "N")"
    [[ "$cont_ans" == "true" ]] || { user_cancel; return 1; }
  fi

  # ── Verify source image (once) ──
  if ! verify_image "$img"; then
    warn "Source image has issues. Writing a corrupted image may brick the target."
    local cont_ans2
    cont_ans2="$(ask_yesno "Continue anyway?" "N")"
    [[ "$cont_ans2" == "true" ]] || { user_cancel; return 1; }
  fi

  # ── Build command ──
  local is_compressed=false
  if qemu-img info "$img" 2>/dev/null | grep -qi "compression type:"; then
    is_compressed=true
  fi

  local start_ts rc=0
  start_ts="$(date +%s)"
  run_write_engine "$img" "$target" "$img_size" "$is_compressed" || rc=$?


  if (( rc != 0 )); then
    err "Write failed (exit code: $rc)"
    warn "Target device may be PARTIALLY written — do not boot from it."
    print_write_failure_hints "$img" "$target"
    return 1
  fi

  sync
  udevadm settle 2>/dev/null || true
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
  tip "Run Option 15 (Repair) if the restored disk doesn't boot."
  print_summary "Write image to device" "$img" "$target" "$start_ts"
  pause
}