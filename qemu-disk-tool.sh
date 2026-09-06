#!/usr/bin/env bash
set -euo pipefail

# Allow tests to override interactive input source
TTY="${TTY:-/dev/tty}"

hr() { echo "────────────────────────────────────────────────────────"; }


# ── Source all modules ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -d "$SCRIPT_DIR/lib" ]] || { echo "🟥 lib/ directory not found next to $0"; exit 1; }
for lib_file in "$SCRIPT_DIR"/lib/*.sh; do
  [[ -f "$lib_file" ]] && source "$lib_file"
done

trap global_cleanup EXIT
trap 'exit 130' INT TERM   # Ctrl+C / kill → clean exit → EXIT trap runs global_cleanup

main_menu() {
  while true; do
    clear || true
    echo "🧰 QEMU Disk Tool"
    echo "────────────────────────────────────────────────────────"
    echo "What do you want to do?"
    echo
    echo "  [1] 🔍 Scan disks/partitions"
    echo "  [2] 🧱 Create NEW blank VM disk image"
    echo "  [3] 🧊 Create image from real disk/partition"
    echo "  [4] 🔁 Convert image format"
    echo "  [5] 🔎 Explore/Mount an image (read-only)"
    echo "  [6] 🧨 Write image to disk/partition (restore)"
    echo "  [7] ℹ️  Show image info"
    echo "  [8] 🗑️  Delete an image file"
    echo "  [9] 📀 Direct Clone (disk/partition → disk/partition)"
    echo "  [10] 🚀 Smart OS Migration (bootable VM from real drive)"
    echo "  [11] 📦 Smart Data-Level Copy (used blocks only)"
    echo "  [12] 📏 Resize/Shrink Image"
    echo "  [13] 🏥 Disk Health Check"
    echo "  [14] 🔄 MBR/GPT Conversion"
    echo "  [15] 🔧 Repair Image / Disk / Partition"
    echo "  [16] ❓ Help"
    echo "  [17] 🚪 Exit"
    echo

    read -rp "➡️  Enter choice (1-17): " c <"$TTY"
    case "$c" in
      1) human_lsblk; pause ;;
      2) create_blank_disk ;;
      3) create_image_from_device ;;
      4) convert_image ;;
      5) explore_mount_image ;;
      6) write_image_to_device ;;
      7) image_info ;;
      8) delete_image_file ;;
      9) direct_clone ;;
      10) smart_os_migration ;;
      11) smart_data_copy ;;
      12) resize_image ;;
      13) disk_health_check ;;
      14) mbr_gpt_convert ;;
      15) repair_target ;;
      16) show_help; continue ;;
      17) log "Bye 👋"; exit 0 ;;
      *) warn "Pick 1-17."; pause ;;
    esac
  done
}

# --------- Start ---------
need_root "$@"
preflight_check
main_menu
