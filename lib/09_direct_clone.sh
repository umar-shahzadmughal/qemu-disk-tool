# ============================================================
# Option 9: Direct Clone (disk/partition → disk/partition)
# DESTRUCTIVE: Wipes target device completely
# No intermediate image file needed
# Supports: pv for faster raw copies, size validation
# ============================================================
direct_clone() {
  hr
  echo "📀 Direct Clone (disk/partition → disk/partition)"
  hr

  local src target t

  # ── Pick source ──
  echo "Source type:"
  echo "  [1] Whole disk  💽"
  echo "  [2] Partition   🧩"
  read -rp "➡️  Enter number (1-2): " t <"$TTY"

  case "$t" in
    1) src="$(pick_block_device disk)";;
    2) src="$(pick_block_device part)";;
    *) die "Invalid choice.";;
  esac

  maybe_unmount "$src"

  # ── Pick target ──
  echo
  echo "Target type:"
  echo "  [1] Whole disk  💽 (wipes everything)"
  echo "  [2] Partition   🧩 (wipes only that partition)"
  read -rp "➡️  Enter number (1-2): " t <"$TTY"

  case "$t" in
    1) target="$(pick_block_device disk)";;
    2) target="$(pick_block_device part)";;
    *) die "Invalid choice.";;
  esac

  # Prevent cloning to self
  if [[ "$src" == "$target" ]]; then
    die "Source and target are the same device. Aborting."
  fi

  maybe_unmount "$target"

  # ── Size check ──
  local src_size target_size
  src_size="$(bytes_of_src "$src" 2>/dev/null || echo 0)"
  target_size="$(bytes_of_src "$target" 2>/dev/null || echo 0)"

  if [[ "$src_size" =~ ^[0-9]+$ && "$target_size" =~ ^[0-9]+$ && "$src_size" -gt "$target_size" ]]; then
    echo
    warn "⚠️  Source size: $(numfmt --to=iec "$src_size")"
    warn "⚠️  Target size: $(numfmt --to=iec "$target_size")"
    echo
    warn "Source is LARGER than target. Clone will fail."
    echo
    info "💡 Tip: Use Option 11 (Smart Data-Level Copy) to copy only used blocks."
    echo
    local cont_ans
    cont_ans="$(ask_yesno "Continue anyway?" "N")"
    [[ "$cont_ans" == "true" ]] || die "Cancelled due to size mismatch."
  fi

  # ── Final confirmation ──
  hr
  echo "🔥 FINAL WARNING — DIRECT CLONE"
  echo "   Source: $src ($(numfmt --to=iec "$src_size"))"
  echo "   Target: $target ($(numfmt --to=iec "$target_size"))"
  echo
  echo "📌 Target details:"
  lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL "$target" 2>/dev/null | sed 's/\\x20/ /g' || true
  hr

  echo "To continue, type the target EXACTLY:"
  echo "   $target"
  read -rp "✍️  Type target path to confirm: " confirm1 <"$TTY"
  [[ "$confirm1" == "$target" ]] || die "Mismatch. Aborting."

  echo "Now type: CLONE"
  read -rp "✍️  Type CLONE to confirm: " confirm2 <"$TTY"
  [[ "$confirm2" == "CLONE" ]] || die "Not confirmed. Aborting."

  # Extra GUI confirmation
  if has_gui; then
    if ! gui_confirm "DESTRUCTIVE CLONE" "You are about to clone:\n$src → $target\n\nThis will ERASE ALL DATA on the target.\n\nAre you absolutely sure?"; then
      die "Cancelled via GUI confirmation."
    fi
  fi

  # ── Perform clone ──
  log "Cloning $src → $target …"
  echo

  local total="$src_size"
  local rc=0
  local use_pv_method=false

  # Ask if user wants pv (faster for raw copies)
  if use_pv; then
    use_pv_method="$(ask_yesno "🚀 Use pv for faster raw copy? (recommended)" "Y")"
  fi

  if [[ "$use_pv_method" == "true" ]]; then
    log "Using pv for block-level copy…"
    pv -s "$total" -N "Cloning" "$src" > "$target" || rc=$?
  else
    # Use beautiful progress bar with qemu-img
    local err_log="/tmp/clone_err_$$.log"

    qemu-img convert -p -f raw -O raw "$src" "$target" 2>"$err_log" &
    local clone_pid=$!

    local start_ts last_pct
    start_ts="$(date +%s)"
    last_pct="-1"
    local bar_width=40

    while kill -0 "$clone_pid" 2>/dev/null; do
      local pct pct_display
      pct_display="$(tail -c 200 "$err_log" 2>/dev/null | tr '\r' '\n' | (grep -oE '\([0-9]+\.[0-9]+/100%\)' || true) | tail -n1 | (grep -oE '[0-9]+\.[0-9]+' || true) | head -n1)"
      pct="${pct_display%%.*}"
      [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
      pct_display="${pct_display:-0.0}"

      local now elapsed elapsed_str eta_str
      now="$(date +%s)"
      elapsed=$((now - start_ts))
      elapsed_str="$(printf '%02d:%02d:%02d' $((elapsed/3600)) $(((elapsed%3600)/60)) $((elapsed%60)))"

      if ((pct > 0)); then
        local eta=$(( (elapsed * 100 / pct) - elapsed ))
        eta_str="$(printf '%02d:%02d:%02d' $((eta/3600)) $(((eta%3600)/60)) $((eta%60)))"
      else
        eta_str="--:--:--"
      fi

      if [[ "$pct" != "$last_pct" ]]; then
        last_pct="$pct"
        local filled=$(( (pct * bar_width) / 100 ))
        local empty=$((bar_width - filled))
        local bar_fill="" bar_empty=""
        for ((i=0; i<filled; i++)); do bar_fill+="█"; done
        for ((i=0; i<empty; i++)); do bar_empty+="░"; done
      fi

      printf "\r  [%s%s] %5s%%  Elapsed: %s  ETA: %s  " \
        "$bar_fill" "$bar_empty" "$pct_display" "$elapsed_str" "$eta_str"

      sleep 0.5
    done

    wait "$clone_pid" 2>/dev/null
    rc=$?

    printf "\r  [%s] 100%%  Done!                                        \n" \
      "$(printf '█%.0s' $(seq 1 $bar_width))"

    rm -f "$err_log"
  fi

  if [[ $rc -ne 0 ]]; then
    err "Clone failed (rc=$rc)"
    die "Clone operation failed. Target may be partially written."
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
  success "Clone complete: $src → $target"
  echo
  lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS "$target" 2>/dev/null | sed 's/\\x20/ /g' || true
  echo
  info "💡 Tip: Run Option 1 (Scan) to verify the cloned disk."
  pause
}

