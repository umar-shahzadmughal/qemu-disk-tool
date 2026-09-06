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
  local src srcfmt
  src="$(ask_path_existing_file "📥 Enter source image path: ")"
  srcfmt="$(detect_img_format "$src")"
  [[ -n "$srcfmt" ]] || srcfmt="raw"
  log "Source: $(basename "$src") (format: $srcfmt)"

  # ── Destination format ──
  local dstfmt
  dstfmt="$(ask_format_out)"

  # Warn if same format
  if [[ "$srcfmt" == "$dstfmt" ]]; then
    warn "Source and destination format are the same ($srcfmt)."
    local cont_ans
    cont_ans="$(ask_yesno "Continue anyway? (useful for recompaction)" "N")"
    [[ "$cont_ans" == "true" ]] || die "Cancelled."
  fi

  local ext
  case "$dstfmt" in
    qcow2) ext="qcow2" ;; raw) ext="img" ;; vmdk) ext="vmdk" ;;
    vhdx) ext="vhdx" ;; vpc) ext="vhd" ;; *) ext="img" ;;
  esac

  # ── Compression options (qcow2 only) ──
  local extra=()
  if [[ "$dstfmt" == "qcow2" ]]; then
    local compress
    compress="$(ask_yesno "🗜️  Compress qcow2 output? (smaller file, slower convert)" "Y")"
    if [[ "$compress" == "true" ]]; then
      ask_compression_opts extra
    fi
  fi

  # ── Output path ──
  local dst=""
  local outdir
  outdir="$(suggest_out_dir)"
  local base_name
  base_name="$(basename "$src")"
  base_name="${base_name%.*}"
  local default_path="$outdir/${base_name}.${ext}"

  if has_gui; then
    local gui_path
    gui_path="$(gui_pick_save_file "Save converted image as" "$default_path")"
    if [[ -n "$gui_path" ]]; then
      dst="$gui_path"
    fi
  fi

  if [[ -z "$dst" ]]; then
    echo
    echo "   Default: $default_path"
    while true; do
      read -rp "📁 Save as (full path or just filename): " tmp <"$TTY"
      if [[ -z "$tmp" ]]; then
        dst="$default_path"
        break
      fi
      if [[ "$tmp" != */* ]]; then
        dst="$outdir/$tmp"
      else
        dst="$tmp"
      fi
      local parent_dir
      parent_dir="$(dirname "$dst")"
      if [[ -d "$parent_dir" ]]; then
        break
      else
        warn "Directory not found: $parent_dir — try again."
      fi
    done
  fi

  # ── Overwrite check ──
  if [[ -e "$dst" ]]; then
    warn "File exists: $dst"
    local ow_ans
    ow_ans="$(ask_yesno "Overwrite it?" "N")"
    [[ "$ow_ans" == "true" ]] || die "Cancelled."
    rm -f "$dst"
  fi

  # ── Convert ──
  run_convert "$srcfmt" "$src" "$dstfmt" "$dst" "${extra[@]}"
  qemu-img info "$dst" || true
  verify_image "$dst" || warn "Image may have issues."
  write_image_metadata "$dst" "$src" "Converted from $srcfmt to $dstfmt via Option 4"

  echo
  success "Converted: $src → $dst"
  pause
}