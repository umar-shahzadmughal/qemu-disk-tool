# ============================================================
# Option 3: Create an image from a real disk or partition
# WARNING: Partition images are NOT bootable (data backup only)
# ============================================================
create_image_from_device() {
  hr
  echo "🧊 Create image from a REAL disk/partition"
  hr
  local start_ts; start_ts="$(date +%s)"

  # ── Source type ──
  echo
  echo "  [1] 💽 Whole disk   → bootable clone (partition table included)"
  echo "  [2] 🧩 Partition    → data-only backup (NOT bootable)"
  echo
  local t
  read -rp "➡️  Enter choice (1-2): " t <"$TTY"

  local src=""
  case "$t" in
    1) src="$(pick_block_device disk)" ;;
    2) src="$(pick_block_device part)" ;;
    *) die "Invalid choice." ;;
  esac

  if [[ "$t" == "2" ]]; then
    echo
    warn "You are imaging a PARTITION, not a whole disk."
    warn "The resulting image will NOT be bootable."
    local cont_ans
    cont_ans="$(ask_yesno "Continue with partition imaging?" "Y")"
    [[ "$cont_ans" == "true" ]] || { user_cancel; return 1; }
  fi

  # ── Format + compression (chosen BEFORE unmount: estimate needs mounts) ──
  local fmt ext
  fmt="$(ask_format_out)"
  ext="$(fmt_to_ext "$fmt")"

  local extra=() is_compressed=false
  if [[ "$fmt" == "qcow2" ]]; then
    local compress
    compress="$(ask_yesno "🗜️  Compress qcow2 output? (smaller file, slower convert)" "Y")"
    if [[ "$compress" == "true" ]]; then
      is_compressed=true
      ask_compression_opts extra
    fi
  fi

  # ── Estimate BEFORE unmount (measures real used space while mounted) ──
  local est_size
  est_size="$(estimate_image_size "$src" "$fmt" "$is_compressed")"
  # Guard your point 3: never let a 0/invalid estimate skip the space check
  [[ "$est_size" =~ ^[0-9]+$ && "$est_size" -gt 0 ]] || \
    est_size="$(bytes_of_src "$src" 2>/dev/null || echo 0)"
  log "Estimated output size: $(numfmt --to=iec "$est_size")"
  maybe_unmount "$src" || return 1

  # ── Output path (standard helper: GUI + terminal + overwrite + space) ──
  local outdir default_path dst
  outdir="$(suggest_out_dir)"
  default_path="$outdir/$(basename "$src")_backup.$ext"
  dst="$(ask_save_path "$default_path" "$ext" "$est_size")" || return 1
    assert_dst_not_on_src "$src" "$dst" || return 1

  # ── Convert with live progress (pty + total bytes) ──
  PB_EMOJI="🧊"
  local rc=0
  run_convert_engine raw "$src" "$fmt" "$dst" "${extra[@]}" || rc=$?
  unset PB_EMOJI
  if (( rc != 0 )); then
    err "Conversion failed (exit $rc)."
    [[ -f "$dst" ]] && rm -f "$dst"
    return 1
  fi

  std_ending "Image from device" "$src" "$dst" "$start_ts"
}