# ============================================================
# Option 7: Show detailed image information
# ============================================================
image_info() {
  hr
  echo "ℹ️  Image Information"
  hr

  local f
  f="$(ask_path_existing_file "📦 Enter image path: ")"

  local fmt vsize dsize cluster_size compat compression
  fmt="$(qemu-img info "$f" 2>/dev/null | awk -F': ' '/^file format:/ {print $2}')"
  vsize="$(qemu-img info "$f" 2>/dev/null | awk -F': ' '/^virtual size:/ {print $2}')"
  dsize="$(stat -c '%s' "$f" 2>/dev/null || echo 0)"
  cluster_size="$(qemu-img info "$f" 2>/dev/null | awk -F': ' '/^cluster_size:/ {print $2}')"
  compat="$(qemu-img info "$f" 2>/dev/null | awk -F': ' '/^compat:/ {print $2}')"
  compression="$(qemu-img info "$f" 2>/dev/null | awk -F': ' '/compression type:/ {print $2}')"

  echo
  echo "  📄 File:          $(basename "$f")"
  echo "  📁 Path:          $f"
  echo "  🧩 Format:        ${fmt:-unknown}"
  echo "  📏 Virtual size:  ${vsize:-unknown}"
  echo "  💾 Actual size:   $(numfmt --to=iec "$dsize")"
  echo "  📐 Cluster size:  ${cluster_size:-N/A}"
  echo "  🔄 Compat:        ${compat:-N/A}"
  echo "  🗜️  Compression:   ${compression:-none}"

  # Show space efficiency for qcow2
  if [[ "$fmt" == "qcow2" && "$dsize" -gt 0 ]]; then
    local vsize_bytes
    vsize_bytes="$(qemu-img info "$f" 2>/dev/null | sed -n 's/.*(\([0-9]\+\) bytes).*/\1/p' | head -1)"
    if [[ "$vsize_bytes" =~ ^[0-9]+$ && "$vsize_bytes" -gt 0 ]]; then
      local efficiency=$((100 - (dsize * 100 / vsize_bytes)))
      echo "  📊 Efficiency:    ${efficiency}% space saved (thin-provisioned)"
    fi
  fi

  echo
  hr
  echo "  Full qemu-img output:"
  hr
  qemu-img info "$f" 2>/dev/null || true
  echo

  # Verify integrity
  local check_ans
  check_ans="$(ask_yesno "🔍 Run integrity check?" "N")"
  if [[ "$check_ans" == "true" ]]; then
    verify_image "$f" || warn "Image has issues. Try Option 15 (Repair)."
  fi

  pause
}