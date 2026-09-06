# ============================================================
# Option 8: Delete an image file (with safety confirmations)
# Also removes associated .info metadata file
# ============================================================
delete_image_file() {
  hr
  echo "🗑️  Delete an image file"
  hr

  local f
  f="$(ask_path_existing_file "📦 Enter file path to delete: ")"

  # Show file details before deletion
  local fmt vsize dsize
  fmt="$(detect_img_format "$f" 2>/dev/null || echo "unknown")"
  vsize="$(qemu-img info "$f" 2>/dev/null | awk -F': ' '/^virtual size:/ {print $2; exit}')"
  dsize="$(stat -c '%s' "$f" 2>/dev/null || echo 0)"

  echo
  echo "  📄 File:    $(basename "$f")"
  echo "  📁 Path:    $f"
  echo "  🧩 Format:  ${fmt:-unknown}"
  echo "  📏 Virtual: ${vsize:-unknown}"
  echo "  💾 Size:    $(numfmt --to=iec "$dsize")"

  # Check for metadata file
  local info_file="${f}.info"
  if [[ -f "$info_file" ]]; then
    echo "  📝 Metadata: $(basename "$info_file") (will also be deleted)"
  fi
  echo

  # First confirmation
  local del_ans
  del_ans="$(ask_yesno "🗑️  Delete this file?" "N")"
  [[ "$del_ans" == "true" ]] || die "Cancelled."

  # Final confirmation: type DELETE
  hr
  echo "⚠️  This action is PERMANENT and cannot be undone."
  echo "   Type DELETE to confirm:"
  read -rp "✍️  Confirm: " c <"$TTY"
  [[ "$c" == "DELETE" ]] || die "Not confirmed. Aborting."
  hr

  # Delete the image file
  rm -f -- "$f"
  success "Deleted: $f"

  # Delete metadata file if it exists
  if [[ -f "$info_file" ]]; then
    rm -f -- "$info_file"
    log "Metadata removed: $info_file"
  fi

  _write_log "DELETE" "$f (${fmt:-unknown}, $(numfmt --to=iec "$dsize"))"
  pause
}