# ============================================================
# Option 2: Create a new blank virtual disk image
# Supports: qcow2, raw, vmdk, vhdx, vhd
# ============================================================
create_blank_disk() {
  hr
  echo "🧱 Create a NEW blank virtual disk image"
  hr

  # ── Format first (determines extension) ──
  local fmt ext
  fmt="$(ask_format_out)"
  ext="$(fmt_to_ext "$fmt")"

  # ── Size (validated + bounded by common helper) ──
  local size size_bytes
  size="$(ask_size "📏 Size (e.g., 20G, 500G, 1T)")" || return 1
  size_bytes="$(numfmt --from=auto "$size")"

  # ── Format-specific options ──
  local -a create_opts=()
  local prealloc="sparse"

  if [[ "$fmt" == "qcow2" ]]; then
    { echo
      echo "  QCOW2 Options:"
      echo "  [1] Standard (sparse, grows as needed)"
      echo "  [2] Preallocated metadata (faster snapshots)"
      echo "  [3] Fully preallocated (fastest I/O, uses full disk space now)"
      echo
    } >&2
    local qcow_opt
    read -rp "➡️  Choose (1-3) [1]: " qcow_opt <"$TTY"
    qcow_opt="${qcow_opt:-1}"
    case "$qcow_opt" in
      2) create_opts+=(-o preallocation=metadata); prealloc="metadata" ;;
      3) create_opts+=(-o preallocation=falloc);   prealloc="falloc" ;;
    esac
    if [[ "$prealloc" != "falloc" ]]; then
      local comp
      comp="$(ask_yesno "🗜️  Set zstd compression type for future writes?" "N")"
      if [[ "$comp" == "true" ]]; then
        create_opts+=(-o compression_type=zstd)
        info "zstd compression type set (applies to data written later)."
      fi
    fi

  elif [[ "$fmt" == "raw" ]]; then
    { echo
      echo "  RAW Options:"
      echo "  [1] Sparse file (instant creation, grows as needed)"
      echo "  [2] Fully allocated (slower creation, guaranteed disk space)"
      echo
    } >&2
    local raw_opt
    read -rp "➡️  Choose (1-2) [1]: " raw_opt <"$TTY"
    [[ "${raw_opt:-1}" == "2" ]] && prealloc="full"
  fi

  # ── Disk space actually needed AT CREATION TIME ──
  local alloc_bytes=1048576                      # sparse: metadata only
  [[ "$prealloc" == "metadata" ]] && alloc_bytes=16777216   # L1/L2/refcount tables
  [[ "$prealloc" == "falloc" || "$prealloc" == "full" ]] && alloc_bytes="$size_bytes"

  # ── Output path (standard helper: GUI + terminal + overwrite + space) ──
  local outdir default_path dst
  outdir="$(suggest_out_dir)"
  default_path="$outdir/new_disk_${size}.$ext"
  dst="$(ask_save_path "$default_path" "$ext" "$alloc_bytes")" || return 1

  # ── Create (timer starts here — excludes interactive prompt time) ──
  local start_ts; start_ts="$(date +%s)"

  if [[ "$fmt" == "raw" && "$prealloc" == "sparse" ]]; then
    log "Creating sparse raw image ($size)…"
    truncate -s "$size" "$dst" || { err "Failed to create sparse file."; rm -f "$dst" 2>/dev/null; return 1; }

  elif [[ "$fmt" == "raw" && "$prealloc" == "full" ]]; then
    PB_EMOJI="🧱"
    PB_TOTAL="$size_bytes"
    PB_HEADER="/dev/zero → $dst"
    PB_SUBLINE="full allocation · $size · raw"
    local rc=0
    run_with_progress_bar "Writing zero blocks (full allocation)…" "$size_bytes" \
      dd if=/dev/zero of="$dst" bs=1M status=progress || rc=$?
    unset PB_EMOJI PB_TOTAL PB_HEADER PB_SUBLINE
    if (( rc != 0 )); then
      err "Failed to allocate disk space."
      rm -f "$dst"; return 1
    fi

  else
    log "Creating $fmt image ($size, $prealloc)…"
    qemu-img create -f "$fmt" "${create_opts[@]}" "$dst" "$size" >&2 || {
      err "qemu-img create failed."
      rm -f "$dst" 2>/dev/null
      return 1
    }
  fi

  # ── Show result ──
  echo
  qemu-img info "$dst" >&2 || warn "Could not read image info."
  [[ "$prealloc" == "sparse" ]] && \
    info "Sparse file: uses minimal disk space now, grows as you write data."
  success "Created: $dst"

  std_ending "Create blank image" "-" "$dst" "$start_ts"
}