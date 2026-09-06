# ============================================================
# Option 2: Create a new blank virtual disk image
# Supports: qcow2, raw, vmdk, vhdx, vhd
# ============================================================
create_blank_disk() {
  hr
  echo "🧱 Create a NEW blank virtual disk image"
  hr

  # ── Ask format first (determines file extension) ──
  local fmt
  fmt="$(ask_format_out)"

  # ── Ask size with validation ──
  local size
  while true; do
    read -rp "📏 Size (e.g., 20G, 500G, 1T): " size <"$TTY"
    if [[ -z "$size" ]]; then
      warn "Size cannot be empty."
      continue
    fi
    if [[ ! "$size" =~ ^[0-9]+[bBkKmMgGtTpPeE]?$ ]]; then
      warn "Invalid format. Use numbers followed by K, M, G, or T (e.g., 50G)."
      continue
    fi
    
    # Convert to bytes for validation
    local size_bytes
    size_bytes="$(numfmt --from=auto "$size" 2>/dev/null)" || {
      warn "Could not parse size."
      continue
    }
    
    # Reasonable bounds: 1MB to 64TB
    if (( size_bytes < 1048576 )); then
      warn "Size too small (minimum 1M)."
      continue
    fi
    if (( size_bytes > 70368744177664 )); then
      warn "Size too large (maximum 64T)."
      continue
    fi
    break
  done

  # ── Format-specific options ──
  local -a create_opts=()
  local qcow_opt="" raw_opt=""
  
  if [[ "$fmt" == "qcow2" ]]; then
    echo
    echo "  QCOW2 Options:"
    echo "  [1] Standard (sparse, grows as needed)"
    echo "  [2] Preallocated metadata (faster snapshots)"
    echo "  [3] Fully preallocated (fastest I/O, uses full disk space now)"
    echo
    read -rp "➡️  Choose (1-3) [1]: " qcow_opt <"$TTY"
    qcow_opt="${qcow_opt:-1}"
    
    case "$qcow_opt" in
      2) create_opts+=(-o preallocation=metadata) ;;
      3) create_opts+=(-o preallocation=falloc) ;;
    esac
    
    # Offer compression
    if [[ "$qcow_opt" != "3" ]]; then
      echo
      read -rp "🗜️  Enable compression? (y/N): " comp <"$TTY"
      if [[ "${comp,,}" == "y" ]]; then
        # Fix: -c is not valid for qemu-img create. Use -o compression_type instead.
        create_opts+=(-o compression_type=zstd)
        info "Compression enabled (zstd - faster and better compression)"
      fi
    fi
    
  elif [[ "$fmt" == "raw" ]]; then
    echo
    echo "  RAW Options:"
    echo "  [1] Sparse file (instant creation, grows as needed)"
    echo "  [2] Fully allocated (slower creation, guaranteed disk space)"
    echo
    read -rp "➡️  Choose (1-2) [1]: " raw_opt <"$TTY"
    raw_opt="${raw_opt:-1}"
    
    if [[ "$raw_opt" == "2" ]]; then
      info "Full allocation: this may take several minutes for large disks…"
    fi
  fi

  # ── Ask output path (GUI or terminal) ──
  local ext
  case "$fmt" in
    qcow2) ext="qcow2" ;; raw) ext="img" ;; vmdk) ext="vmdk" ;;
    vhdx) ext="vhdx" ;; vpc) ext="vhd" ;; *) ext="img" ;;
  esac

  local dst=""
  local outdir
  outdir="$(suggest_out_dir)"
  local default_path="$outdir/new_disk.$ext"

  if has_gui; then
    local gui_path
    gui_path="$(gui_pick_save_file "Save new disk image as" "$default_path")"
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
        tmp="$outdir/$tmp"
      fi
      # Ensure correct extension
      if [[ "$tmp" != *".$ext" ]]; then
        tmp="$tmp.$ext"
      fi
      dst="$tmp"
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
    ow_ans="$(ask_yesno "Overwrite?" "N")"
    [[ "$ow_ans" == "true" ]] || die "Cancelled."
    rm -f "$dst"
  fi

  # ── Create the image ──
  local start_ts
  start_ts="$(date +%s)"
  
  if [[ "$fmt" == "raw" && "${raw_opt:-1}" == "1" ]]; then
    # Sparse raw file - instant
    log "Creating sparse raw image ($size)…"
    truncate -s "$size" "$dst" || die "Failed to create sparse file."
  elif [[ "$fmt" == "raw" && "${raw_opt:-1}" == "2" ]]; then
    # Full allocation raw - use dd with progress
    log "Creating fully allocated raw image ($size)…"
    local size_bytes
    size_bytes="$(numfmt --from=auto "$size")"
    
    PB_EMOJI="🧱"
    PB_TOTAL="$size_bytes"
    PB_HEADER="$(basename "$dst")"
    if ! run_with_progress_bar "Allocating disk space…" "$size_bytes" \
      dd if=/dev/zero of="$dst" bs=1M status=progress; then
      unset PB_EMOJI PB_TOTAL PB_HEADER
      die "Failed to allocate disk space."
    fi
    unset PB_EMOJI PB_TOTAL PB_HEADER
  else
    # qemu-img create with options
    log "Creating $fmt image ($size)…"
    if ! qemu-img create -f "$fmt" "${create_opts[@]}" "$dst" "$size" >/dev/null; then
      die "qemu-img create failed."
    fi
  fi

  # ── Verify ──
  echo
  qemu-img info "$dst" || warn "Could not read image info."
  verify_image "$dst" || warn "Image may have issues."

  # ── Summary ──
  print_summary "Create blank image" "-" "$dst" "$start_ts"
  
  echo
  success "Created: $dst"
  
  if [[ "$fmt" == "raw" && "${raw_opt:-1}" == "1" ]]; then
    info "Sparse file: uses minimal disk space now, grows as you write data."
  fi
  
  pause
}