# ============================================================
# Option 4: Convert an image between formats
# Supports: qcow2 ↔ raw ↔ vmdk ↔ vhdx ↔ vhd
# Includes: compression options, verification
# ============================================================
convert_image() {
  hr
  echo "🔁 Convert an image to another format"
  hr

  # ── Source image ──
  echo
  echo "📥 Step 1: Select the image file to convert"
  local src srcfmt
  src="$(ask_path_existing_file "📥 Enter source image path: ")"
  srcfmt="$(detect_img_format "$src")"
  [[ -n "$srcfmt" ]] || srcfmt="raw"
  log "Source: $(basename "$src") (format: $srcfmt)"

  # ── Destination format ──
  echo
  echo "🧩 Step 2: Choose the output format"
  local dstfmt ext
  dstfmt="$(ask_format_out)"
  ext="$(fmt_to_ext "$dstfmt")"

  # Warn if same format (useful for recompaction)
  if [[ "$srcfmt" == "$dstfmt" ]]; then
    warn "Source and destination format are the same ($srcfmt)."
    local cont_ans
    cont_ans="$(ask_yesno "Continue anyway? (useful for recompaction)" "N")"
    [[ "$cont_ans" == "true" ]] || { user_cancel; return 1; }
  fi

  # ── Compression options (qcow2 only) ──
  local extra=()
  if [[ "$dstfmt" == "qcow2" ]]; then
    local compress
    compress="$(ask_yesno "🗜️  Compress qcow2 output? (smaller file, slower convert)" "Y")"
    if [[ "$compress" == "true" ]]; then
      ask_compression_opts extra
    fi
  fi

  # ── Output path (standard helper: GUI + terminal + overwrite + space) ──
  echo
  echo "💾 Step 3: Choose where to save the converted image"
  local outdir default_path dst
  outdir="$(suggest_out_dir)"
  local base_name
  base_name="$(basename "$src")"
  base_name="${base_name%.*}"
  default_path="$outdir/${base_name}.${ext}"

  local est_size
  est_size="$(estimate_image_size "$src" "$dstfmt" "$([[ " ${extra[*]} " == *" -c "* ]] && echo true || echo false)")"
  # Pass $src as 4th argument to prevent overwriting the source image
  dst="$(ask_save_path "$default_path" "$ext" "$est_size" "$src")" || return 1

  # ── Convert with live progress ──
  PB_EMOJI="🔁"
  local rc=0 start_ts
  start_ts="$(date +%s)"
  run_convert_engine "$srcfmt" "$src" "$dstfmt" "$dst" "${extra[@]}" || rc=$?
  unset PB_EMOJI
  if (( rc != 0 )); then
    err "Conversion failed (exit $rc)."
    [[ -f "$dst" ]] && rm -f "$dst"
    return 1
  fi

  std_ending "Convert image" "$src" "$dst" "$start_ts"
}