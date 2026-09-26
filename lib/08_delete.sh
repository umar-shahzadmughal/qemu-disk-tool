# ============================================================
# Option 8: Delete an image file (with safety confirmations)
# Also removes associated .info metadata file
# ============================================================
delete_image_file() {
  hr
  echo "🗑️  Delete an image file"
  hr

  # ── Step 1: Select image ──
  echo
  echo "📦 Step 1: Select the image to delete"
  local f
  f="$(ask_path_existing_file "📦 Enter file path to delete: ")"

  # ── Step 2: Show details ──
  echo
  echo "📋 Step 2: File details"
  local info_output
  info_output="$(qemu-img info "$f" 2>/dev/null || true)"

  local fmt vsize dsize
  fmt="$(echo "$info_output" | awk -F': ' '/^file format:/ {print $2; exit}')"
  vsize="$(echo "$info_output" | awk -F': ' '/^virtual size:/ {print $2; exit}')"
  dsize="$(stat -c '%s' "$f" 2>/dev/null || echo 0)"

  echo "  📄 File:    $(basename "$f")"
  echo "  📁 Path:    $f"
  echo "  🧩 Format:  ${fmt:-unknown}"
  echo "  📏 Virtual: ${vsize:-unknown}"
  echo "  💾 Size:    $(numfmt --to=iec "$dsize")"

  local info_file="${f}.info"
  if [[ -f "$info_file" ]]; then
    echo "  📝 Metadata: $(basename "$info_file") (will also be deleted)"
  fi
  echo

  # ── Step 3: Confirm deletion ──
  echo "🗑️  Step 3: Confirm deletion"
  local del_ans
  del_ans="$(ask_yesno "🗑️  Delete this file?" "N")"
  [[ "$del_ans" == "true" ]] || { user_cancel; return 1; }

  hr
  echo "⚠️  This action is PERMANENT and cannot be undone."
  confirm_typed "DELETE" "Type DELETE to confirm:" true || return 1
  hr

  # ── Delete ──
  rm -f -- "$f"
  success "Deleted: $f"

  if [[ -f "$info_file" ]]; then
    rm -f -- "$info_file"
    log "Metadata removed: $info_file"
  fi

  _write_log "DELETE" "$f (${fmt:-unknown}, $(numfmt --to=iec "$dsize"))"
  pause
}