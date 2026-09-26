# ============================================================
# Option 7: Show detailed image information
# ============================================================
image_info() {
  hr
  echo "ℹ️  Image Information"
  hr

  # ── Step 1: Select image ──
  echo
  echo "📦 Step 1: Select the image to inspect"
  local f
  f="$(ask_path_existing_file "📦 Enter image path: ")"
  log "Inspecting image: $f"

  # ── Step 2: Parse (single qemu-img call) ──
  local info_output
  info_output="$(qemu-img info "$f" 2>/dev/null || true)"
  
  local fmt vsize dsize cluster_size compat compression corrupt
  fmt="$(echo "$info_output" | awk -F': ' '/^file format:/ {print $2; exit}')"
  vsize="$(echo "$info_output" | awk -F': ' '/^virtual size:/ {print $2; exit}')"
  dsize="$(stat -c '%s' "$f" 2>/dev/null || echo 0)"
  cluster_size="$(echo "$info_output" | awk -F': ' '/^cluster_size:/ {print $2; exit}')"
  compat="$(echo "$info_output" | awk -F': ' '/^compat:/ {print $2; exit}')"
  compression="$(echo "$info_output" | awk -F': ' '/compression type:/ {print $2; exit}')"
  corrupt="$(echo "$info_output" | awk -F': ' '/^corrupt:/ {print $2; exit}')"

  echo
  echo "  📄 File:          $(basename "$f")"
  echo "  📁 Path:          $f"
  echo "  🧩 Format:        ${fmt:-unknown}"
  echo "  📏 Virtual size:  ${vsize:-unknown}"
  echo "  💾 Actual size:   $(numfmt --to=iec "$dsize")"
  echo "  📐 Cluster size:  ${cluster_size:-N/A}"
  echo "  🔄 Compat:        ${compat:-N/A}"
  echo "  🗜️  Compression:   ${compression:-none}"
  
  if [[ "$corrupt" == "true" ]]; then
    echo "  ⚠️  Corrupt:       YES — image may have issues!"
  fi

  # Show space efficiency for qcow2
  if [[ "$fmt" == "qcow2" && "$dsize" -gt 0 ]]; then
    local vsize_bytes
    vsize_bytes="$(echo "$info_output" | sed -n 's/.*(\([0-9]\+\) bytes).*/\1/p' | head -1)"
    if [[ "$vsize_bytes" =~ ^[0-9]+$ && "$vsize_bytes" -gt 0 ]]; then
      local efficiency=$((100 - (dsize * 100 / vsize_bytes)))
      echo "  📊 Efficiency:    ${efficiency}% space saved (thin-provisioned)"
    fi
  fi

  echo
  hr
  echo "  Full qemu-img output:"
  hr
  echo "$info_output"
  echo

  # ── Step 3: Integrity check (skip for formats that don't support it) ──
  if [[ "$fmt" == "raw" || "$fmt" == "vmdk" || "$fmt" == "vpc" || "$fmt" == "vhdx" ]]; then
    info "Format $fmt does not support integrity checks (skipped)."
  else
    echo "🔍 Step 3: Optional integrity verification"
    local check_ans
    check_ans="$(ask_yesno "Run integrity check?" "N")"
    if [[ "$check_ans" == "true" ]]; then
      verify_image "$f" || warn "Image has issues. Try Option 15 (Repair)."
    fi
  fi

  _write_log "INFO" "Inspected $f (format: ${fmt:-unknown}, virtual: ${vsize:-?}, actual: $(numfmt --to=iec "$dsize"))"
  pause
}