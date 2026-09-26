# ============================================================
# Option 9: Direct Clone (disk/partition → disk/partition)
# DESTRUCTIVE: Wipes target device completely
# No intermediate image file needed
# ============================================================
direct_clone() {
  hr
  echo "📀 Direct Clone (disk/partition → disk/partition)"
  hr

  # ── Step 1: Source ──
  echo
  echo "💽 Step 1: Select the SOURCE device"
  echo "  [1] Whole disk  💽"
  echo "  [2] Partition   🧩"
  local t src target
  read -rp "➡️  Enter number (1-2): " t <"$TTY"
  case "$t" in
    1) src="$(pick_block_device disk)";;
    2) src="$(pick_block_device part)";;
    *) die "Invalid choice.";;
  esac
  local src_size
  src_size="$(bytes_of_src "$src" 2>/dev/null || echo 0)"
  if (( src_size == 0 )); then
    err "Source $src reports size 0 — empty card reader or unplugged media?"
    return 1
  fi
  maybe_unmount "$src" || return 1

  # ── Step 2: Target ──
  echo
  echo "💽 Step 2: Select the TARGET device (will be erased)"
  echo "  [1] Whole disk  💽 (wipes everything)"
  echo "  [2] Partition   🧩 (wipes only that partition)"
  read -rp "➡️  Enter number (1-2): " t <"$TTY"
  case "$t" in
    1) target="$(pick_block_device disk)";;
    2) target="$(pick_block_device part)";;
    *) die "Invalid choice.";;
  esac
  local target_size
  target_size="$(bytes_of_src "$target" 2>/dev/null || echo 0)"
  if (( target_size == 0 )); then
    err "Target $target reports size 0 — empty card reader or unplugged media?"
    return 1
  fi

  # ── Step 3: Safety guard + unmount target ──
  assert_clone_safe "$src" "$target" || return 1
  maybe_unmount "$target" || return 1

  # ── Size check ──
  if (( src_size > target_size )); then
    echo
    warn "Source size: $(numfmt --to=iec "$src_size")"
    warn "Target size: $(numfmt --to=iec "$target_size")"
    echo
    warn "Source is LARGER than target. Clone will fail."
    tip "Use Option 11 (Smart Data-Level Copy) to copy only used blocks."
    echo
    local cont_ans
    cont_ans="$(ask_yesno "Continue anyway?" "N")"
    [[ "$cont_ans" == "true" ]] || { user_cancel; return 1; }
  fi

  # ── Step 4: Final confirmation ──
  hr
  echo "🔥 FINAL WARNING — DIRECT CLONE"
  echo "   Source: $src ($(numfmt --to=iec "$src_size"))"
  echo "   Target: $target ($(numfmt --to=iec "$target_size"))"
  echo
  echo "📌 Target details:"
  lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL "$target" 2>/dev/null | sed 's/\\x20/ /g' || true
  hr

  echo "To continue, type the target EXACTLY (Enter/'cancel' aborts):"
  echo "   $target"
  confirm_typed "$target" "Type target path to confirm:" true || return 1

  echo
  echo "Now type: CLONE"
  confirm_typed "CLONE" "Type CLONE to confirm:" true || return 1

  if has_gui; then
    if ! gui_confirm "DESTRUCTIVE CLONE" "You are about to clone:\n$src → $target\n\nThis will ERASE ALL DATA on the target.\n\nAre you absolutely sure?"; then
      user_cancel "Cancelled via GUI confirmation."
      return 1
    fi
  fi

  # ── Step 5: Method + clone ──
  local use_pv_method=false
  if use_pv; then
    use_pv_method="$(ask_yesno "🚀 Use pv for faster raw copy? (recommended)" "Y")"
  fi

  local rc=0 start_ts
  start_ts="$(date +%s)"
  run_clone_engine "$src" "$target" "$src_size" "$use_pv_method" || rc=$?

  if (( rc != 0 )); then
    err "Clone failed (exit $rc)"
    warn "Target may be PARTIALLY written — do not use it."
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
  success "Clone complete: $src → $target"
  echo
  lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS "$target" 2>/dev/null | sed 's/\\x20/ /g' || true
  echo
  tip "Run Option 1 (Scan) to verify the cloned disk."
  print_summary "Direct clone" "$src" "$target" "$start_ts"
  pause
}