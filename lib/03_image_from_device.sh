# ============================================================
# Option 3: Create an image from a real disk or partition
# WARNING: Partition images are NOT bootable (data backup only)
# Includes: smart space check, compression, auto-extension
# ============================================================
create_image_from_device() {
  hr
  echo "🧊 Create image from a REAL disk/partition"
  hr

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
    [[ "$cont_ans" == "true" ]] || die "Cancelled."
  fi

  maybe_unmount "$src"

  # ── Format selection ──
  local fmt
  fmt="$(ask_format_out)"

  local ext
  case "$fmt" in
    qcow2) ext="qcow2" ;; raw) ext="img" ;; vmdk) ext="vmdk" ;;
    vhdx) ext="vhdx" ;; vpc) ext="vhd" ;; *) ext="img" ;;
  esac

  # ── Compression options (qcow2 only) ──
  local extra=()
  local is_compressed=false
  if [[ "$fmt" == "qcow2" ]]; then
    local compress
    compress="$(ask_yesno "🗜️  Compress qcow2 output? (smaller file, slower convert)" "Y")"
    if [[ "$compress" == "true" ]]; then
      is_compressed=true
      ask_compression_opts extra
    fi
  fi

  # ── Calculate estimated output size ──
  local src_size
  src_size="$(bytes_of_src "$src" 2>/dev/null || echo 0)"

  local est_size
  if [[ "$fmt" == "raw" ]]; then
    est_size="$src_size"  # raw = full size
  else
    # Try to calculate actual used space from mounted partitions
    local used_space=0
    local part_list=()
    if [[ -b "$src" ]]; then
      # Source is a partition
      if mountpoint -q "$src" 2>/dev/null; then
        used_space="$(df -B1 "$src" 2>/dev/null | tail -1 | awk '{print $3}')"
      fi
    else
      # Source is a disk — sum used space from all partitions
      while IFS= read -r p; do
        [[ -b "$p" ]] && part_list+=("$p")
      done < <(lsblk -nrpo NAME,TYPE "$src" 2>/dev/null | awk '$2=="part"{print $1}')

      for p in "${part_list[@]}"; do
        if mountpoint -q "$p" 2>/dev/null; then
          local p_used
          p_used="$(df -B1 "$p" 2>/dev/null | tail -1 | awk '{print $3}')"
          used_space=$((used_space + ${p_used:-0}))
        fi
      done
    fi

    if ((used_space > 0)); then
      # Used data + 15% buffer for metadata/overhead
      est_size=$((used_space * 115 / 100))
    else
      # Fallback: estimate based on format
      if [[ "$is_compressed" == "true" ]]; then
        est_size=$((src_size * 40 / 100))  # compressed: ~40% estimate
      else
        est_size=$((src_size * 70 / 100))  # uncompressed: ~70% estimate
      fi
    fi
  fi

  log "Estimated output size: $(numfmt --to=iec "$est_size")"

   # ── Output path loop (remembers filename, retries on space issues) ──
  local dst=""
  local outdir
  outdir="$(suggest_out_dir)"
  local src_label
  src_label="$(basename "$src")"
  local default_path="$outdir/${src_label}_backup.$ext"
  local remembered_path="$default_path"
  local first_attempt=true

    # ── Output path loop ──
  local dst=""
  local outdir
  outdir="$(suggest_out_dir)"
  local src_label
  src_label="$(basename "$src")"
  local default_path="$outdir/${src_label}_backup.$ext"
  local remembered_path="$default_path"

  # ── Output path loop ──
  local dst=""
  local outdir
  outdir="$(suggest_out_dir)"
  local src_label
  src_label="$(basename "$src")"
  local default_path="$outdir/${src_label}_backup.$ext"
  local remembered_path="$default_path"
  local try_gui=true

  while true; do
    dst=""

    # ── Open GUI only when requested ──
    if [[ "$try_gui" == "true" ]] && has_gui; then
      local gui_path
      gui_path="$(gui_pick_save_file "Save image as" "$remembered_path" || true)"
      if [[ -n "$gui_path" ]]; then
        dst="$gui_path"
      fi
      try_gui=false  # Don't auto-open GUI on next iteration
    fi

    # ── Terminal prompt (shown when GUI cancelled or not available) ──
    if [[ -z "$dst" ]]; then
      echo
      echo "   📁 Current path: $remembered_path"
      if has_gui; then
        echo "   💡 Type a path, 'gui' to open file picker, or 'cancel' to abort."
      else
        echo "   💡 Type a path or 'cancel' to abort."
      fi
      if ! read -rp "   ➡️  Save as: " tmp <"$TTY"; then
        echo
        die "Cancelled."
      fi

      if [[ "${tmp,,}" == "cancel" || "${tmp,,}" == "q" ]]; then
        die "Cancelled."
      elif [[ "${tmp,,}" == "gui" ]]; then
        try_gui=true
        continue
      elif [[ -z "$tmp" ]]; then
        dst="$remembered_path"
      elif [[ "$tmp" != */* ]]; then
        dst="$outdir/$tmp"
      else
        dst="$tmp"
      fi
    fi

    # ── Auto-append extension ──
    if [[ "$dst" != *".$ext" ]]; then
      dst="${dst}.${ext}"
    fi
    remembered_path="$dst"

    # ── Check directory exists ──
    local parent_dir
    parent_dir="$(dirname "$dst")"
    if [[ ! -d "$parent_dir" ]]; then
      warn "Directory not found: $parent_dir"
      continue
    fi

    # ── Overwrite check ──
    if [[ -e "$dst" ]]; then
      warn "File exists: $dst"
      local ow_ans
      ow_ans="$(ask_yesno "Overwrite it?" "N")"
      if [[ "$ow_ans" != "true" ]]; then
        continue
      fi
      rm -f "$dst"
    fi

    # ── Space check ──
    local avail_space
    avail_space="$(df -B1 "$parent_dir" 2>/dev/null | awk 'NR==2 {print $4}')"
    avail_space="${avail_space:-0}"

    if ((est_size > avail_space)); then
      echo
      err "Not enough disk space in $parent_dir"
      echo "   Estimated size: $(numfmt --to=iec "$est_size")"
      echo "   Available:      $(numfmt --to=iec "$avail_space")"
      echo
      warn "Choose a different directory."
      continue  # → shows terminal prompt (NOT GUI)
    fi

    # ── Confirmed ──
    echo
    success "Output confirmed: $dst"
    log "Space check: $(numfmt --to=iec "$avail_space") available ✅"
    break
  done

  # ── Convert ──
  run_convert raw "$src" "$fmt" "$dst" "${extra[@]}"
  qemu-img info "$dst" || true
  verify_image "$dst" || warn "Image may have issues."
  write_image_metadata "$dst" "$src" "Created from real device via Option 3"

  echo
  success "Image created: $dst"
  pause
}