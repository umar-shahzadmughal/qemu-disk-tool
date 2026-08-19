#!/usr/bin/env bash
set -euo pipefail

# Allow tests to override interactive input source
TTY="${TTY:-/dev/tty}"

hr() { echo "────────────────────────────────────────────────────────"; }

# ============================================================
# QEMU Disk Tool 🧰
# - Create/convert/mount/restore qcow2/raw/img/vmdk/vhdx/vhd
# - Whole disk or partitions
# ============================================================

# --------- Config ---------
DEFAULT_OUT_DIR="${HOME}"
NBD_MAX=2
USED_NBDS=()
NBD_LOADED_BY_US=0  # Track if WE loaded the nbd module
LOG_FILE="${HOME}/.qemu-disk-tool.log"

check_nbd_module() {
  echo
  echo "🧩 Kernel module check: nbd"

  command -v modprobe >/dev/null 2>&1 || {
    echo "  ❌ modprobe not found (install kmod)."
    return 1
  }

  # Check if nbd is ALREADY loaded before we touch it
  if [[ -d /sys/module/nbd ]]; then
    if [[ "${NBD_LOADED_BY_US:-0}" -eq 1 ]]; then
      echo "  ✅ nbd module loaded by this script."
    else
      echo "  ✅ nbd module already loaded (not by us)."
      NBD_LOADED_BY_US=0
    fi
  else
    # Try to load with sensible defaults
    modprobe nbd max_part=16 nbds_max="${NBD_MAX:-16}" 2>/dev/null || \
    modprobe nbd max_part=16 2>/dev/null || true

    [[ -d /sys/module/nbd ]] || {
      echo "  ❌ nbd module is not loaded and could not be loaded."
      return 1
    }
    NBD_LOADED_BY_US=1
    echo "  ✅ nbd module loaded by this script."
  fi

  local mp nb
  mp="$(cat /sys/module/nbd/parameters/max_part 2>/dev/null || echo 0)"
  nb="$(cat /sys/module/nbd/parameters/nbds_max 2>/dev/null || echo "?")"

  # mp should be numeric
  [[ "$mp" =~ ^[0-9]+$ ]] || mp=0

  if (( mp == 0 )); then
    echo "  ❌ nbd loaded but partition support looks disabled (max_part=$mp)."
    echo "     Fix: sudo rmmod nbd && sudo modprobe nbd max_part=16"
    return 1
  fi

  if (( mp < 16 )); then
    echo "  ❌ nbd max_part too low: $mp (need >= 16)."
    echo "     Fix: sudo rmmod nbd && sudo modprobe nbd max_part=16"
    return 1
  fi

  # NOTE: 31 is common/OK (kernel rounding). Don't treat it as an error.
  if (( mp != 16 )); then
    echo "  🟨 nbd loaded (nbds_max=$nb) and max_part=$mp."
    echo "     That’s OK (many kernels round 16 → 31)."
  else
    echo "  ✅ nbd loaded (nbds_max=$nb) and max_part=$mp."
  fi

  return 0
}

preflight_check() {
  hr
  echo "🧰 QEMU Disk Tool — Preflight Check"
  hr

  # Detect distro (we'll support Debian/Ubuntu only for auto-install)
  source /etc/os-release 2>/dev/null || true
  local dist="${ID:-unknown}"

  if [[ "$dist" != "ubuntu" && "$dist" != "debian" ]]; then
    echo "🟨 Auto-install supported on Ubuntu/Debian only. Detected: $dist"
  fi

  # ── Tool lists ──
  local required=(qemu-img qemu-nbd lsblk findmnt mount umount mountpoint partprobe dd truncate modprobe udevadm blockdev numfmt script rsync sgdisk ntfs-3g smartctl resize2fs partclone.ext4 partclone.ntfs)
  local optional=(pv zenity)

  # ── Check required tools ──
  echo "🔎 Checking required tools…"
  local missing=()
  for c in "${required[@]}"; do
    if have "$c"; then
      printf "  ✅ %-14s %s\n" "$c" "$(ver "$c")"
    else
      printf "  ❌ %-14s missing\n" "$c"
      missing+=("$c")
    fi
  done

  # ── Check optional tools (display only) ──
  echo
  echo "🧩 Checking optional tools…"
  local missing_optional=()
  for c in "${optional[@]}"; do
    if have "$c"; then
      printf "  ✅ %-14s %s\n" "$c" "$(ver "$c")"
    else
      printf "  ⚠️  %-14s missing (optional)\n" "$c"
      missing_optional+=("$c")
    fi
  done

  # ── Helper: offer optional tools install ──
  offer_optional_install() {
    ((${#missing_optional[@]} > 0)) || return 0
    [[ "$dist" == "ubuntu" || "$dist" == "debian" ]] || return 0

    echo
    echo "🟨 Missing optional tools:"
    for c in "${missing_optional[@]}"; do
      case "$c" in
        pv)     echo "     • pv      → Faster progress bars for raw copies" ;;
        zenity) echo "     • zenity  → GUI file/folder pickers (needs graphical display)" ;;
        *)      echo "     • $c" ;;
      esac
    done
    echo
    read -rp "🛠️  Install missing optional tools now? (y/N): " ans <"$TTY"
    if [[ "${ans,,}" == "y" ]]; then
      local opt_pkgs=()
      for c in "${missing_optional[@]}"; do
        case "$c" in
          pv)     opt_pkgs+=("pv") ;;
          zenity) opt_pkgs+=("zenity") ;;
          *)      opt_pkgs+=("$c") ;;
        esac
      done
      echo "📦 Installing optional packages: ${opt_pkgs[*]}"
      apt-get install -y "${opt_pkgs[@]}" || warn "Some optional packages failed to install."
    else
      log "Skipping optional tools. Some features will use terminal fallback."
    fi
  }

  # ── All required tools present ──
  if ((${#missing[@]} == 0)); then
    echo
    echo "🟩 Preflight: OK — all required tools are installed."
    hr
    offer_optional_install
    return 0
  fi

  # ── Required tools missing: auto-install on Ubuntu/Debian ──
  if [[ "$dist" == "ubuntu" || "$dist" == "debian" ]]; then
    echo
    echo "🟨 Missing required tools: ${missing[*]}"

    local pkgs=()
    for c in "${missing[@]}"; do
      case "$c" in
        qemu-img|qemu-nbd)              pkgs+=("qemu-utils") ;;
        partprobe)                      pkgs+=("parted") ;;
        lsblk|findmnt|mount|umount|mountpoint|blockdev)
                                        pkgs+=("util-linux") ;;
        dd|truncate|numfmt)             pkgs+=("coreutils") ;;
        modprobe)                       pkgs+=("kmod") ;;
        udevadm)                        pkgs+=("udev") ;;
        script)                         pkgs+=("util-linux") ;;
        rsync)                          pkgs+=("rsync") ;;
        sgdisk)                         pkgs+=("gdisk") ;;
        ntfs-3g)                        pkgs+=("ntfs-3g") ;;
        smartctl)                       pkgs+=("smartmontools") ;;
        resize2fs)                      pkgs+=("e2fsprogs") ;;
        partclone.ext4|partclone.ntfs)  pkgs+=("partclone") ;;
        *)                              pkgs+=("$c") ;;
      esac
    done

    # Deduplicate
    local uniq_pkgs=()
    local seen=" "
    for p in "${pkgs[@]}"; do
      [[ "$seen" == *" $p "* ]] || { uniq_pkgs+=("$p"); seen+=" $p "; }
    done

    echo "📦 Packages to install: ${uniq_pkgs[*]}"
    read -rp "🛠️  Install missing required tools now? (y/N): " ans <"$TTY"
    [[ "${ans,,}" == "y" ]] || { echo "🟥 Install cancelled." >&2; exit 1; }

    apt-get update
    apt-get install -y "${uniq_pkgs[@]}"

    # Re-check
    echo
    echo "🔁 Re-check after install…"
    local still_missing=0
    for c in "${required[@]}"; do
      if have "$c"; then
        printf "  ✅ %-14s %s\n" "$c" "$(ver "$c")"
      else
        printf "  ❌ %-14s still missing\n" "$c"
        still_missing=1
      fi
    done

    if [[ "$still_missing" -eq 1 ]]; then
      echo "🟥 Preflight failed. Some tools didn't install correctly."
      exit 1
    fi

    echo
    echo "🟩 Preflight: OK — tools installed and verified."
    hr
    offer_optional_install
    return 0
  fi

  # ── Not Ubuntu/Debian ──
  echo
  echo "🟥 Missing required tools, and auto-install isn't supported on this distro."
  echo "   Install manually then re-run."
  exit 1
}

# --------- Colors ---------
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --------- Logging ---------
_write_log() {
  local level="$1"
  shift
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

# --------- Helpers ---------
log()  { echo -e "${BLUE}🟦 $*${NC}"; _write_log "INFO" "$*"; }
warn() { echo -e "${YELLOW}🟨 $*${NC}"; _write_log "WARN" "$*"; }
err()  { echo -e "${RED}🟥 $*${NC}" >&2; _write_log "ERROR" "$*"; }
die()  { err "$*"; exit 1; }
success() { echo -e "${GREEN}✅ $*${NC}"; _write_log "SUCCESS" "$*"; }
info()   { echo -e "${CYAN}ℹ️  $*${NC}"; _write_log "INFO" "$*"; }

# Helpers
have(){ command -v "$1" >/dev/null 2>&1; }
ver(){
  # best-effort version extraction
  case "$1" in
    qemu-img)  qemu-img --version 2>/dev/null | head -n1 ;;
    qemu-nbd)  qemu-nbd --version 2>/dev/null | head -n1 ;;
    lsblk)     lsblk --version 2>/dev/null | head -n1 ;;
    partprobe) partprobe --version 2>/dev/null | head -n1 ;;
    dd)        dd --version 2>/dev/null | head -n1 ;;
    pv)        pv --version 2>/dev/null | head -n1 ;;
    sgdisk)    sgdisk --version 2>/dev/null | head -n1 ;;
    ntfs-3g)   ntfs-3g --version 2>/dev/null | head -n1 ;;
    *)         "$1" --version 2>/dev/null | head -n1 ;;
  esac
}

bytes_of_src() {
  local src="$1"
  if [[ -b "$src" ]]; then
    blockdev --getsize64 "$src"
  else
    stat -c '%s' "$src"
  fi
}

img_virtual_bytes() {
  # Extract "(NNN bytes)" from qemu-img info
  local img="$1"
  qemu-img info "$img" 2>/dev/null | sed -n 's/.*(\([0-9]\+\) bytes).*/\1/p' | head -n1
}

# ---------- Pretty progress for qemu-img (-p) ----------
get_total_bytes() {
  local src="$1"

  # Block device?
  if [[ -b "$src" ]]; then
    # bytes
    lsblk -bno SIZE "$src" 2>/dev/null | head -n1
    return 0
  fi

  # Regular file: parse "virtual size: ... (NN bytes)" from qemu-img info
  qemu-img info "$src" 2>/dev/null |
    awk -F'[()]' '/^virtual size:/ {gsub(/[^0-9]/,"",$2); print $2; exit}'
}

qemu_img_progress_bar() {
  local total="$1"
  local label="${2:-Working}"
  local width=60

  [[ "$total" =~ ^[0-9]+$ ]] || total=0
  (( total > 0 )) || { cat >&2; return 0; }

  [[ -t 2 ]] || { cat >&2; return 0; }

  local start_ns now_ns elapsed_s pct pct_int filled empty
  local done_bytes left_bytes speed eta
  start_ns="$(date +%s%N)"

  fmt_time() {
    local s="$1"
    (( s < 0 )) && s=0
    printf '%02d:%02d:%02d' $((s/3600)) $(((s%3600)/60)) $((s%60))
  }

  fmt_bytes() {
    numfmt --to=iec-i --suffix=B --format="%.1f" "$1" 2>/dev/null || echo "${1}B"
  }

  # Convert CR updates into NL lines so "read" sees them
  stdbuf -o0 tr '\r' '\n' | while IFS= read -r line; do
    # Match: (12.34/100%)
    if [[ "$line" =~ \(([0-9]+([.][0-9]+)?)\/100%\) ]]; then
      pct="${BASH_REMATCH[1]}"

      # float -> int (round)
      pct_int="$(awk -v p="$pct" 'BEGIN{printf "%d", (p<0?0:(p>100?100:p))+0.5}')"
      (( pct_int == 0 )) && pct_int=1

      # force visible start (avoid staying at 0)
      if (( pct_int == 0 )) && [[ "$pct" != "0" && "$pct" != "0.00" ]]; then
        pct_int=1
      fi

      now_ns="$(date +%s%N)"
      elapsed_s="$(awk -v a="$start_ns" -v b="$now_ns" 'BEGIN{printf "%.3f", (b-a)/1000000000}')"

      done_bytes="$(awk -v t="$total" -v p="$pct_int" 'BEGIN{printf "%.0f", (t*p)/100.0}')"
      left_bytes="$(( total - done_bytes ))"

      speed="$(awk -v d="$done_bytes" -v e="$elapsed_s" 'BEGIN{ if(e<=0) print 0; else printf "%.0f", d/e }')"
      eta="$(awk -v l="$left_bytes" -v s="$speed" 'BEGIN{ if(s<=0) print 0; else printf "%d", l/s }')"

      filled="$(( (pct_int*width)/100 ))"
      empty="$(( width - filled ))"

      # Build bar strings safely
      local bar_fill bar_empty
      bar_fill="$(printf '%*s' "$filled" '' | tr ' ' '█')"
      bar_empty="$(printf '%*s' "$empty"  '' | tr ' ' ' ')"

      printf '\r%s: %3d%%|%s%s| %s/%s [%s<%s, %s/s]' \
        "$label" "$pct_int" \
        "$bar_fill" "$bar_empty" \
        "$(fmt_bytes "$done_bytes")" "$(fmt_bytes "$total")" \
        "$(fmt_time "$(awk -v e="$elapsed_s" 'BEGIN{printf "%d", e}')" )" \
        "$(fmt_time "$eta")" \
        "$(fmt_bytes "$speed")" \
        >&2

      (( pct_int >= 100 )) && printf '\n' >&2
    else
      [[ -n "$line" ]] && echo "$line" >&2
    fi
  done
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    warn "This tool needs root for disk access/mounting."
    warn "Re-running with sudo…"
    exec sudo -E TTY="$TTY" bash "$(readlink -f "$0")" "$@"
  fi
}

pause() { read -rp "⏎ Press Enter to continue… " _ <"$TTY" || true; }

# Spinner for long operations without built-in progress
spinner() {
  local pid=$1
  local msg="${2:-Working}"
  local delay=0.1
  local spinstr='|/-\'
  
  while kill -0 "$pid" 2>/dev/null; do
    local temp=${spinstr#?}
    printf "  [%c] %s\r" "$spinstr" "$msg"
    spinstr=$temp${spinstr%"$temp"}
    sleep $delay
  done
  printf "\r\033[K"  # Clear the spinner line
}

run_with_spinner() {
  local msg="$1"
  shift
  
  "$@" &
  local pid=$!
  spinner "$pid" "$msg"
  wait "$pid"
}

# ============================================================
# Option 1: Scan and display all physical disks and partitions
# Shows: NAME, TYPE, SIZE, FSTYPE, MOUNTPOINTS, MODEL, SERIAL
# ============================================================
human_lsblk() {
  hr
  echo "🔍 Storage Inventory (disks + partitions)"
  hr
  # -e 7 = loop, -e 43 = nbd  ✅ hides nbd0/nbd1/... from inventory
  lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL -e 7,43 || true
  hr
}

# --------- partclone Integration ---------
get_partclone_tool() {
  local fstype="$1"
  case "$fstype" in
    ext4|ext3|ext2) echo "partclone.ext4" ;;
    ntfs)           echo "partclone.ntfs" ;;
    fat|vfat|fat32) echo "partclone.fat32" ;;
    exfat)          echo "partclone.exfat" ;;
    btrfs)          echo "partclone.btrfs" ;;
    xfs)            echo "partclone.xfs" ;;
    *)              echo "" ;;
  esac
}

has_partclone_for() {
  local fstype="$1"
  local tool
  tool="$(get_partclone_tool "$fstype")"
  [[ -n "$tool" ]] && command -v "$tool" >/dev/null 2>&1
}

# --------- pv Integration ---------
use_pv() {
  # Check if pv is available and we want to use it
  command -v pv >/dev/null 2>&1
}

pv_copy_with_progress() {
  local src="$1" dst="$2" size="$3"
  
  if use_pv && [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 ]]; then
    pv -s "$size" -N "Copying" "$src" > "$dst"
  else
    dd if="$src" of="$dst" bs=4M status=progress 2>&1
  fi
}

qemu_img_convert_with_tty_progress() {
  local total="$1"
  local label="$2"
  shift 2

  # If no total, just run normally
  if [[ ! "$total" =~ ^[0-9]+$ ]] || (( total <= 0 )); then
    "$@"
    return $?
  fi

  # Build safely escaped command string for script -c
  local cmd_str
  cmd_str="$(printf '%q ' "$@")"

  set +e

  # -f = flush after each write (this is the fix for "nothing shows")
  script -q -f -e -c "$cmd_str" /dev/null 2>&1 \
    | qemu_img_progress_bar "$total" "$label"

  local rc="${PIPESTATUS[0]}"

  set -e

  # 130 = Ctrl+C (SIGINT). Treat as a normal cancel, not a failure.
  if [[ "$rc" -eq 130 ]]; then
    echo >&2
    warn "$label cancelled."
    return 0
  fi

  return "$rc"
}

pick_block_device() {
  local want="${1:?disk|part}"
  local lines=()

  while IFS= read -r line; do
    lines+=("$line")
  done < <(
    # NAME TYPE SIZE MODEL SERIAL MOUNTPOINTS
    lsblk -nrpo NAME,TYPE,SIZE,MODEL,SERIAL,MOUNTPOINTS |
      awk -v w="$want" '
        $2==w {
          # exclude NBD and loop and rom devices
          if ($1 ~ "^/dev/nbd[0-9]+") next
          if ($1 ~ "^/dev/loop[0-9]+") next
          if ($2 == "rom") next
          print
        }'
  )

  ((${#lines[@]} == 0)) && die "No devices found for type: $want"

  {
    echo "🧭 Select a $want:"
    for i in "${!lines[@]}"; do
      printf "  [%d] %s\n" "$((i+1))" "${lines[$i]}"
    done
  } >&2

  local sel
  while true; do
    read -rp "➡️  Enter number (1-${#lines[@]}): " sel <"$TTY"
    [[ "$sel" =~ ^[0-9]+$ ]] || { echo "🟨 Numbers only." >&2; continue; }
    (( sel>=1 && sel<=${#lines[@]} )) || { echo "🟨 Out of range." >&2; continue; }
    break
  done

  # ONLY return the device path
  echo "${lines[$((sel-1))]}" | awk '{print $1}'
}

is_mounted() {
  local dev="$1"
  # True if any mountpoint exists for that device
  findmnt -rn --source "$dev" >/dev/null 2>&1
}

maybe_unmount() {
  local dev="$1"

  # Collect mountpoints for dev
  local targets=""
  targets="$(findmnt -rn -o TARGET -S "$dev" 2>/dev/null || true)"

  # If dev is a disk, also collect mountpoints for its partitions
  if [[ "$(lsblk -no TYPE "$dev" 2>/dev/null || true)" == "disk" ]]; then
    while IFS= read -r p; do
      targets+=$'\n'"$(findmnt -rn -o TARGET -S "$p" 2>/dev/null || true)"
    done < <(lsblk -nrpo NAME "$dev" 2>/dev/null | tail -n +2)
  fi

  # Normalize: remove empty lines
  targets="$(echo "$targets" | awk 'NF')"

  if [[ -n "$targets" ]]; then
    warn "Mounted target (or its partitions): $dev"
    while IFS= read -r line; do
      [[ -n "$line" ]] && echo "  📌 $line" >&2
    done <<< "$targets"
    read -rp "🧨 Unmount ALL related mounts now? (y/N): " ans <"$TTY"

    if [[ "${ans,,}" == "y" ]]; then
      # Unmount deepest paths first to avoid parent/child conflicts
      while IFS= read -r t; do
        if [[ -n "$t" ]]; then
          umount "$t" 2>/dev/null || true
        fi
      done < <(echo "$targets" | awk '{print length "\t" $0}' | sort -nr | cut -f2-)
      log "Unmount attempted ✅"
    else
      die "Refusing to image/overwrite a mounted device."
    fi
  fi
}

# --------- GUI (zenity) ---------
has_gui() {
  # Check if zenity exists AND we have a display
  command -v zenity >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]
}

gui_pick_file() {
  local title="${1:-Select a file}"
  local filter="${2:-*}"
  zenity --file-selection --title="$title" --file-filter="$filter" 2>/dev/null
}

gui_pick_directory() {
  local title="${1:-Select a folder}"
  zenity --file-selection --directory --title="$title" 2>/dev/null
}

gui_pick_save_file() {
  local title="${1:-Save file as}"
  local default_name="${2:-output.qcow2}"
  zenity --file-selection --save --confirm-overwrite --title="$title" --filename="$default_name" 2>/dev/null
}

gui_confirm() {
  local title="${1:-Confirm}"
  local msg="${2:-Are you sure?}"
  zenity --question --title="$title" --text="$msg" --width=400 2>/dev/null
}

gui_warn() {
  local title="${1:-Warning}"
  local msg="${2:-Something happened}"
  zenity --warning --title="$title" --text="$msg" --width=400 2>/dev/null
}

gui_error() {
  local title="${1:-Error}"
  local msg="${2:-Something went wrong}"
  zenity --error --title="$title" --text="$msg" --width=400 2>/dev/null
}

suggest_out_dir() {
  if [[ -d "$DEFAULT_OUT_DIR" ]]; then
    echo "$DEFAULT_OUT_DIR"
  else
    echo "$PWD"
  fi
}

# ✅ True if qemu-img can read it as an image
is_qemu_image() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  qemu-img info "$f" >/dev/null 2>&1
}

# ✅ Detect partition table type (GPT/MBR) and boot mode hints
detect_disk_info() {
  local dev="$1"
  [[ -b "$dev" ]] || return 1

  echo "🔍 Analyzing: $dev" >&2

  # Detect partition table type
  local pt_type
  pt_type="$(lsblk -no PTTYPE "$dev" 2>/dev/null | head -n1)"
  if [[ -n "$pt_type" ]]; then
    case "$pt_type" in
      gpt)  echo "   📋 Partition Table: GPT" >&2 ;;
      dos)  echo "   📋 Partition Table: MBR (dos)" >&2 ;;
      *)    echo "   📋 Partition Table: $pt_type" >&2 ;;
    esac
  else
    echo "   📋 Partition Table: None detected (raw filesystem?)" >&2
  fi

  # List partitions with filesystem types
  local parts
  parts="$(lsblk -nrpo NAME,SIZE,FSTYPE,PARTTYPENAME "$dev" 2>/dev/null | tail -n +2)"
  if [[ -n "$parts" ]]; then
    echo "   📦 Partitions:" >&2
    while IFS= read -r line; do
      echo "      $line" >&2
    done <<< "$parts"

    # Detect potential EFI partition (vfat + esp flag)
    if echo "$parts" | grep -qi "vfat"; then
      echo "   🔎 UEFI hint: FAT partition detected (possible EFI System Partition)" >&2
    fi
  fi
  echo >&2
}

# ✅ Verify image integrity after create/convert
verify_image() {
  local img="$1"
  [[ -f "$img" ]] || return 0

  log "🔍 Verifying image integrity…"
  local check_output
  check_output="$(qemu-img check "$img" 2>&1)"
  local rc=$?

  if [[ $rc -eq 0 ]] && ! echo "$check_output" | grep -qi "corrupt"; then
    log "Image verified ✅"
    return 0
  else
    warn "⚠️  Image has issues:"
    echo "$check_output" >&2
    return 1
  fi
}

pick_image_from_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || die "Not a directory: $dir"

  # Supported by THIS tool (qemu names): qcow2 raw vmdk vhdx vpc
  local supported_re='^(qcow2|raw|vmdk|vhdx|vpc)$'
  local ext_re='\.([Qq][Cc][Oo][Ww]2|[Rr][Aa][Ww]|[Ii][Mm][Gg]|[Vv][Mm][Dd][Kk]|[Vv][Hh][Dd][Xx]|[Vv][Hh][Dd])$'

  local files=() fmts=() vsizes=()

  # Initialize counts (so set -u never complains)
  declare -A count=(
    [qcow2]=0
    [raw]=0
    [vmdk]=0
    [vhdx]=0
    [vpc]=0
  )

  while IFS= read -r -d '' f; do
    local fmt vsize
    fmt="$(qemu-img info "$f" 2>/dev/null | awk -F': ' '/^file format:/ {print $2; exit}')"
    [[ "$fmt" =~ $supported_re ]] || continue

    vsize="$(qemu-img info "$f" 2>/dev/null | awk -F': ' '/^virtual size:/ {print $2; exit}')"

    files+=("$f")
    fmts+=("$fmt")
    vsizes+=("${vsize:-?}")

    # Safe increment
    count["$fmt"]=$(( count["$fmt"] + 1 ))
  done < <(find "$dir" -maxdepth 1 -type f -regextype posix-extended -regex ".*$ext_re" -print0 | LC_ALL=C sort -z)

  ((${#files[@]} == 0)) && die "No supported disk images found in: $dir (qcow2/raw/img/vmdk/vhdx/vhd)"

  {
    echo
    echo "📂 Disk images found in: $dir"
    echo
    echo
    echo "📄 Files: (qcow2, raw/img, vmdk, vhdx, vhd)"
    echo
    local i label
    for i in "${!files[@]}"; do
      label="${fmts[$i]}"
      [[ "$label" == "vpc" ]] && label="vhd"
      printf "  [%d] %-8s %-28s (%s)\n" "$((i+1))" "$label" "$(basename "${files[$i]}")"   "${vsizes[$i]}"
    done
    echo
  } >&2
  
  local sel
  while true; do
    read -rp "➡️  Pick a file (1-${#files[@]}): " sel <"$TTY"
    [[ "$sel" =~ ^[0-9]+$ ]] || { echo "🟨 Numbers only." >&2; continue; }
    (( sel>=1 && sel<=${#files[@]} )) || { echo "🟨 Out of range." >&2; continue; }
    break
  done

  printf "%s\n" "${files[$((sel-1))]}"
}

ask_path_existing_file() {
  local prompt="$1"
  local p=""

  # Try GUI first
  if has_gui; then
    p="$(gui_pick_file "Select a disk image" "*.qcow2 *.img *.raw *.vmdk *.vhdx *.vhd")"
    if [[ -z "$p" ]]; then
      # User cancelled GUI, fall back to terminal
      warn "GUI cancelled. Falling back to terminal input."
    elif [[ -f "$p" ]] && is_qemu_image "$p"; then
      printf "%s\n" "$p"
      return
    fi
  fi

  # Terminal fallback
  while true; do
    read -rp "$prompt" p <"$TTY"
    [[ -n "$p" ]] || { echo "🟨 Empty path not allowed." >&2; continue; }

    # If directory => show numbered selection
    if [[ -d "$p" ]]; then
      pick_image_from_dir "$p"
      return
    fi

    # If file => accept if readable by qemu-img
    if [[ -f "$p" ]]; then
      if is_qemu_image "$p"; then
        printf "%s\n" "$p"
        return
      else
        echo "🟨 Not a QEMU-readable disk image: $p" >&2
        continue
      fi
    fi

    echo "🟨 Not found: $p" >&2
  done
}

ask_path_new_file() {
  local prompt="$1"
  local p=""
  while true; do
    read -rp "$prompt" p <"$TTY"
    [[ -n "$p" ]] || { warn "Empty path not allowed."; continue; }
    local dir
    dir="$(dirname "$p")"
    [[ -d "$dir" ]] || { warn "Directory does not exist: $dir"; continue; }
    if [[ -e "$p" ]]; then
      warn "File exists: $p"
      read -rp "Overwrite it? (y/N): " ans <"$TTY"
      [[ "${ans,,}" == "y" ]] || continue
    fi
    echo "$p"
    return
  done
}

detect_img_format() {
  local img="$1"
  # best-effort parse
  qemu-img info "$img" 2>/dev/null | awk -F': ' '/file format:/ {print $2; exit}'
}

ask_compression_opts() {
  # Returns extra args for qemu-img convert
  # Usage: local extra=(); ask_compression_opts extra
  
  local -n _extra="$1"
  
  {
    echo "🗜️  Compression format:"
    echo "  [1] zlib   | Default: good compatibility, moderate compression"
    echo "  [2] zstd   | Faster + better compression (qcow2 v3+)"
    echo "  [3] none   | No compression"
    echo
  } >&2

  local sel
  while true; do
    read -rp "➡️  Enter number (1-3) [1]: " sel <"$TTY"
    sel="${sel:-1}"
    case "$sel" in
      1) _extra+=("-c"); return ;;
      2) _extra+=("-c" "-o" "compression_type=zstd"); return ;;
      3) return ;;
      *) echo "🟨 Pick 1-3." >&2 ;;
    esac
  done
}

ask_format_out() {
  {
    echo "🧩 Choose a virtual disk output format:"
    echo
    echo "  --- Recommended for QEMU/KVM ---"
    echo "  [1] qcow2  | Modern: Supports snapshots, compression, and thin-provisioning"
    echo
    echo "  --- High Performance / Simple ---"
    echo "  [2] raw    | Generic: No metadata overhead; maximum I/O performance (.img)"
    echo
    echo "  --- Hypervisor Specific ---"
    echo "  [3] vmdk   | VMware: Native for ESXi/Workstation; also supported by VirtualBox"
    echo "  [4] vhdx   | Hyper-V: Modern Windows format; supports disks up to 64TB"
    echo "  [5] vhd    | Legacy: Old Microsoft format (vpc); required for Azure uploads"
    echo
  } >&2

  local sel
  while true; do
    read -rp "➡️  Enter number (1-5): " sel <"$TTY"
    case "$sel" in
      1) printf "qcow2\n"; return;;
      2) printf "raw\n";   return;;
      3) printf "vmdk\n";  return;;
      4) printf "vhdx\n";  return;;
      5) printf "vpc\n";   return;;  # vhd
      *) echo "🟨 Pick 1-5." >&2;;
    esac
  done
}

ask_yesno() {
  local prompt="$1"
  local def="${2:-N}"
  local ans

  while true; do
    read -rp "$prompt (${def}/$( [[ "${def^^}" == "Y" ]] && echo "n" || echo "y" )): " ans <"$TTY"
    ans="${ans:-$def}"

    case "${ans^^}" in
      Y|YES) echo "true"; return 0 ;;
      N|NO)  echo "false"; return 0 ;;
      *) echo "🟨 Type y or n." >&2 ;;
    esac
  done
}

run_convert() {
  # args: src_fmt src dst_fmt dst extra_opts...
  local src_fmt="$1" src="$2" dst_fmt="$3" dst="$4"
  shift 4
  local extra=("$@")
  local _start_ts
  _start_ts="$(date +%s)"

  log "Converting…"
  echo "   📥 Source: $src ($src_fmt)"
  echo "   📤 Dest:   $dst ($dst_fmt)"
  hr

  # Fallback (non-raw sources, or pv missing)
  local total=0
  if [[ "$src_fmt" == "raw" && "$src" =~ ^/dev/ ]]; then
    total="$(blockdev --getsize64 "$src" 2>/dev/null || echo 0)"
  else
    total="$(qemu-img info "$src" 2>/dev/null | sed -n 's/.*(\([0-9]\+\) bytes).*/\1/p' | head -n1)"
  fi

  local rc=0
  if [[ -t 2 && "$total" =~ ^[0-9]+$ && "$total" -gt 0 ]]; then
    qemu_img_convert_with_tty_progress "$total" "Converting" \
      qemu-img convert -p -f "$src_fmt" -O "$dst_fmt" "${extra[@]}" "$src" "$dst" || rc=$?
  else
    qemu-img convert -p -f "$src_fmt" -O "$dst_fmt" "${extra[@]}" "$src" "$dst" || rc=$?
  fi

  if [[ $rc -ne 0 ]]; then
    # Clean up partial file if it exists
    if [[ -f "$dst" ]]; then
      warn "Conversion failed or interrupted. Removing partial output file: $dst"
      rm -f "$dst"
    fi
    die "Conversion failed (rc=$rc)"
  fi

  print_summary "Convert ($src_fmt → $dst_fmt)" "$src" "$dst" "$_start_ts"
  log "Done ✅"
}

# ============================================================
# Option 2: Create a new blank virtual disk image
# Supports: qcow2, raw, vmdk, vhdx, vhd
# Validates size format before creation
# ============================================================
create_blank_disk() {
  hr
  echo "🧱 Create a NEW blank virtual disk image"
  hr

  local outdir size fmt name fullpath compress=false
  outdir="$(suggest_out_dir)"
  read -rp "📁 Output directory [$outdir]: " tmp <"$TTY"
  outdir="${tmp:-$outdir}"
  [[ -d "$outdir" ]] || die "Directory not found: $outdir"

  read -rp "📝 File name (e.g., win11.qcow2): " name <"$TTY"
  [[ -n "$name" ]] || die "File name required."
  fullpath="$outdir/$name"

  while true; do
    read -rp "📏 Size (e.g., 120G, 500G, 50G): " size <"$TTY"
    
    if [[ -z "$size" ]]; then
      echo "🟨 Size cannot be empty." >&2
      continue
    fi
    
    # Match a number followed by an optional suffix (K, M, G, T, P, E or b)
    if [[ "$size" =~ ^[0-9]+[bBkKmMgGtTpPeE]?$ ]]; then
      break
    else
      echo "🟨 Invalid format. Use numbers followed by K, M, G, or T (e.g., 50G, 120G)." >&2
    fi
  done

  fmt="$(ask_format_out)"

  if [[ "$fmt" == "qcow2" ]]; then
    compress="$(ask_yesno "🗜️  Enable qcow2 compression? (helps size, slightly slower)" "N")"
  fi

  if [[ -e "$fullpath" ]]; then
    warn "File exists: $fullpath"
    ask_yesno "Overwrite?" "N" || die "Cancelled."
    rm -f "$fullpath"
  fi

  if [[ "$fmt" == "raw" ]]; then
    log "Creating raw sparse file…"
    truncate -s "$size" "$fullpath"
  else
    log "Creating $fmt image…"
    if [[ "$fmt" == "qcow2" && "$compress" == true ]]; then
      qemu-img create -f qcow2 "$fullpath" "$size" >/dev/null
      # compression applies on convert, not create; still ok to create plain qcow2.
    else
      qemu-img create -f "$fmt" "$fullpath" "$size" >/dev/null
    fi
  fi

  qemu-img info "$fullpath" || true
  verify_image "$fullpath" || warn "Image may have issues. Check output above."
  log "Created ✅  $fullpath"
  pause
}

# ============================================================
# Option 3: Create an image from a real disk or partition
# WARNING: Partition images are NOT bootable (data backup only)
# Includes: disk space check, compression options, verification
# ============================================================
create_image_from_device() {
  hr
  echo "🧊 Create image from a REAL disk/partition"
  hr

  echo "Pick source type:"
  echo "  [1] Whole disk  💽 (bootable clone)"
  echo "  [2] Partition   🧩 (data-only)"
  local t
  read -rp "➡️  Enter number (1-2): " t <"$TTY"

  local src=""
  case "$t" in
    1) src="$(pick_block_device disk)";;
    2) src="$(pick_block_device part)";;
    *) die "Invalid choice.";;
  esac

  # Warn if imaging a partition (won't be bootable)
  if [[ "$t" == "2" ]]; then
    echo
    warn "⚠️  You are imaging a PARTITION, not a whole disk."
    warn "   The resulting image will NOT be bootable."
    warn "   It is suitable for data backup or file recovery only."
    echo
    read -rp "Continue with partition imaging? (Y/n): " ans <"$TTY"
    [[ "${ans,,}" == "n" ]] && die "Cancelled."
  fi

  maybe_unmount "$src"

  local outdir fmt outfile dst compress=false
  outdir="$(suggest_out_dir)"

  # Try GUI directory picker
  if has_gui; then
    local gui_dir
    gui_dir="$(gui_pick_directory "Select output directory")"
    if [[ -n "$gui_dir" && -d "$gui_dir" ]]; then
      outdir="$gui_dir"
      log "Output directory: $outdir"
    fi
  fi

  # Terminal fallback/override
  read -rp "📁 Output directory [$outdir]: " tmp <"$TTY"
  outdir="${tmp:-$outdir}"
  [[ -d "$outdir" ]] || die "Directory not found: $outdir"

  fmt="$(ask_format_out)"

  read -rp "📝 Output file name (no spaces, include extension) [backup.${fmt/vpc/vhd}]: " outfile <"$TTY"
  if [[ -z "$outfile" ]]; then
    outfile="backup.${fmt/vpc/vhd}"
  fi
  dst="$outdir/$outfile"

  local extra=()
  if [[ "$fmt" == "qcow2" ]]; then
    compress="$(ask_yesno "🗜️  Compress qcow2 output? (smaller file, slower convert)" "Y")"
    if [[ "$compress" == "true" ]]; then
      ask_compression_opts extra
    fi
  fi

  if [[ -e "$dst" ]]; then
    warn "File exists: $dst"
    ask_yesno "Overwrite it?" "N" || die "Cancelled."
    rm -f "$dst"
  fi

  # ── Disk space check before imaging ──
  local src_size avail_space
  src_size="$(bytes_of_src "$src" 2>/dev/null || echo 0)"
  # Get available space in bytes (block size 1 byte)
  avail_space="$(df -B1 "$outdir" 2>/dev/null | awk 'NR==2 {print $4}')"

  if [[ "$src_size" =~ ^[0-9]+$ && "$avail_space" =~ ^[0-9]+$ && "$src_size" -gt "$avail_space" ]]; then
    echo
    err "❌ Not enough disk space!"
    warn "Source size: $(numfmt --to=iec "$src_size")"
    warn "Available:  $(numfmt --to=iec "$avail_space")"
    die "Cannot create image. Please free up space or choose a different directory."
  else
    log "💾 Space check passed ($(numfmt --to=iec "$avail_space") available)"
  fi

  run_convert raw "$src" "$fmt" "$dst" "${extra[@]}"
  qemu-img info "$dst" || true
  verify_image "$dst" || warn "Image may have issues. Check output above."
  write_image_metadata "$dst" "$src" "Created from real device via Option 3"
  pause
}

# ============================================================
# Option 4: Convert an image between formats
# Supports: qcow2 ↔ raw ↔ vmdk ↔ vhdx ↔ vhd
# Includes: compression options, verification
# ============================================================
convert_image() {
  hr
  echo "🔁 Convert an image to another format (QEMU)"
  hr

  local src dst dstfmt srcfmt extra=() compress=false
  src="$(ask_path_existing_file "📥 Enter source image path: ")"

  srcfmt="$(detect_img_format "$src")"
  [[ -n "$srcfmt" ]] || srcfmt="raw"

  echo "🧠 Detected source format: $srcfmt"
  dstfmt="$(ask_format_out)"

  local outdir
  outdir="$(suggest_out_dir)"

  # Try GUI directory picker
  if has_gui; then
    local gui_dir
    gui_dir="$(gui_pick_directory "Select output directory")"
    if [[ -n "$gui_dir" && -d "$gui_dir" ]]; then
      outdir="$gui_dir"
      log "Output directory: $outdir"
    fi
  fi

  read -rp "📁 Output directory [$outdir]: " tmp <"$TTY"
  outdir="${tmp:-$outdir}"
  [[ -d "$outdir" ]] || die "Directory not found: $outdir"

  local ext="$dstfmt"
  [[ "$dstfmt" == "vpc" ]] && ext="vhd"
  read -rp "📝 Output file name [converted.${ext}]: " name <"$TTY"
  [[ -z "$name" ]] && name="converted.${ext}"
  dst="$outdir/$name"

  if [[ "$dstfmt" == "qcow2" ]]; then
    compress="$(ask_yesno "🗜️  Compress qcow2 output?" "N")"
    [[ "$compress" == true ]] && extra+=("-c")
  fi

  if [[ -e "$dst" ]]; then
    warn "File exists: $dst"
    ask_yesno "Overwrite it?" "N" || die "Cancelled."
    rm -f "$dst"
  fi

  run_convert "$srcfmt" "$src" "$dstfmt" "$dst" "${extra[@]}"
  qemu-img info "$dst" || true
  verify_image "$dst" || warn "Image may have issues. Check output above."
  write_image_metadata "$dst" "$src" "Converted from $srcfmt to $dstfmt via Option 4"
  pause
}

pick_free_nbd() {
  # IMPORTANT: do not print anything to stdout except the final /dev/nbdX
  check_nbd_module >&2 || exit 1

  udevadm settle 2>/dev/null || true

  local dev idx size

  # ONLY /dev/nbd<number> (ignore /dev/nbd0p1 etc.)
  for dev in /dev/nbd*; do
    [[ -b "$dev" ]] || continue
    [[ "$dev" =~ ^/dev/nbd[0-9]+$ ]] || continue

    idx="${dev#/dev/nbd}"
    size="$(cat "/sys/block/nbd${idx}/size" 2>/dev/null || echo 0)"

    if [[ "${size:-0}" == "0" ]]; then
      printf '%s\n' "$dev"
      return 0
    fi
  done

  echo "🟥 No free /dev/nbdX found." >&2
  echo "🟨 Cleanup: for d in /dev/nbd[0-9]*; do qemu-nbd --disconnect \"\$d\" 2>/dev/null; done" >&2
  return 1
}

pick_partition_from_device() {
  local disk="$1"
  [[ -b "$disk" ]] || die "Not a block device: $disk"

  local parts=()
  while IFS= read -r p; do
    [[ -b "$p" ]] && parts+=("$p")
  done < <(lsblk -nrpo NAME,TYPE "$disk" | awk '$2=="part"{print $1}')

  ((${#parts[@]} == 0)) && die "No partitions found on: $disk"

  {
    echo "🧩 Select a partition to mount:"
    for i in "${!parts[@]}"; do
      # show fstypes + size
      local info
      info="$(lsblk -no SIZE,FSTYPE,MOUNTPOINTS "${parts[$i]}" 2>/dev/null | sed 's/[[:space:]]\+/ /g')"
      printf "  [%d] %s  (%s)\n" "$((i+1))" "${parts[$i]}" "${info:-?}"
    done
  } >&2

  local sel
  while true; do
    read -rp "➡️  Pick partition (1-${#parts[@]}) or type full path: " sel <"$TTY"

    # Number?
    if [[ "$sel" =~ ^[0-9]+$ ]]; then
      (( sel>=1 && sel<=${#parts[@]} )) || { echo "🟨 Out of range." >&2; continue; }
      printf "%s\n" "${parts[$((sel-1))]}"
      return 0
    fi

    # Full path?
    if [[ -b "$sel" ]]; then
      printf "%s\n" "$sel"
      return 0
    fi

    echo "🟨 Invalid input. Use a number or a /dev/... path." >&2
  done
}

# ============================================================
# Option 5: Explore/Mount an image (read-only or read-write)
# Uses qemu-nbd to attach image as block device
# Supports: ext4, ntfs, vfat, exfat, and more
# Includes: smart detection (GPT/MBR, UEFI/BIOS)
# ============================================================
explore_mount_image() {
  hr
  echo "🔎 Explore / Mount an image (READ-ONLY recommended)"
  hr

  local img part ro fstype REAL_USER MEDIA_ROOT
  nbd=""          # ✅ Global so trap can access it after function exits
  mp=""           # ✅ Global so trap can access it after function exits
  _CLEANED_UP=0   # ✅ Global so trap can access it after function exits

  img="$(ask_path_existing_file "📥 Enter image path to explore: ")"

  nbd="$(pick_free_nbd)"
  log "Using $nbd"
  [[ "$nbd" =~ ^/dev/nbd[0-9]+$ ]] || die "Bug: NBD picker returned invalid node ($nbd). Must be /dev/nbd<number>."

  mp=""
  part=""
  ro="true"

  REAL_USER="${SUDO_USER:-$USER}"
  MEDIA_ROOT="/media/$REAL_USER"

  cleanup_explore() {
    # run-once guard
    [[ "${_CLEANED_UP:-0}" -eq 1 ]] && return 0
    _CLEANED_UP=1

    # ignore signals during cleanup (prevents re-entry spam)
    trap '' INT TERM

    set +e

    if [[ -n "${mp:-}" ]]; then
      while IFS= read -r t; do
        [[ -n "$t" ]] || continue
        umount "$t" >/dev/null 2>&1 || true
      done < <(
        findmnt -rn -o TARGET |
          awk -v m="$mp" '$0 ~ "^"m {print}' |
          awk '{print length "\t" $0}' |
          sort -nr | cut -f2-
      )

      umount "$mp" >/dev/null 2>&1 || umount -l "$mp" >/dev/null 2>&1 || true
      rmdir "$mp" >/dev/null 2>&1 || true
    fi

    if [[ "${nbd:-}" =~ ^/dev/nbd[0-9]+$ ]]; then
      qemu-nbd --disconnect "$nbd" >/dev/null 2>&1 || true

      # remove from USED_NBDS so we don't touch it later
      if ((${#USED_NBDS[@]})); then
        local tmp=() x
        for x in "${USED_NBDS[@]}"; do
          [[ "$x" == "$nbd" ]] && continue
          tmp+=("$x")
        done
        USED_NBDS=("${tmp[@]}")
      fi
    fi

    # restore signal handlers to normal behavior (global EXIT trap stays as-is)
    trap - INT TERM
  }

  # run cleanup on exit / ctrl+c
  trap cleanup_explore EXIT INT TERM

  ro="$(ask_yesno "🧊 Connect read-only? (safe)" "Y")"

  if [[ "$ro" == "true" ]]; then
    qemu-nbd --read-only --connect="$nbd" "$img"
  else
    warn "Read-write can corrupt images if you mess up."
    qemu-nbd --connect="$nbd" "$img"
  fi

  # ✅ only track after successful connect
  USED_NBDS+=("$nbd")

  partprobe "$nbd" 2>/dev/null || true
  sleep 0.5

  hr
  echo "📦 Image Analysis ($nbd):"
  detect_disk_info "$nbd"
  echo
  echo "📦 Partitions inside image ($nbd):"
  lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS "$nbd" || true
  hr

  part="$(pick_partition_from_device "$nbd")"

  mkdir -p "$MEDIA_ROOT"
  mp="$MEDIA_ROOT/QEMU_$(basename "$img")_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$mp"
  chown "$REAL_USER:$REAL_USER" "$mp" 2>/dev/null || true

  log "Mounting to $mp"

  fstype="$(lsblk -no FSTYPE "$part" 2>/dev/null || true)"

  if [[ "$ro" == "true" ]]; then
    case "$fstype" in
      ext4)  mount -t ext4 -o ro,noload "$part" "$mp" ;;
      ntfs)
        uid="$(id -u "$REAL_USER")"
        gid="$(id -g "$REAL_USER")"
        mount -t ntfs3 -o ro,uid="$uid",gid="$gid" "$part" "$mp" 2>/dev/null || \
        mount -t ntfs-3g -o ro,uid="$uid",gid="$gid" "$part" "$mp"
        ;;
      vfat|fat|exfat) mount -o ro "$part" "$mp" ;;
      *)              mount -o ro "$part" "$mp" ;;
    esac
  else
    mount "$part" "$mp"
  fi

  echo
  log "Mounted ✅"
  echo "📌 Open it in your File Manager using this path:"
  echo "    $mp"
  echo "🔗 Or run:"
  echo "    xdg-open \"$mp\""
  echo
  read -rp "⏎ Press Enter to unmount + disconnect… " _ <"$TTY" || true

  cleanup_explore
  trap global_cleanup EXIT INT TERM

  log "Done ✅"
  pause
}

# ============================================================
# Option 6: Write an image back to a real disk/partition
# DESTRUCTIVE: Wipes target device completely
# Includes: size check, verification, double confirmation
# Uses low-memory mode (-m 1) for compressed images
# ============================================================
write_image_to_device() {
  hr
  echo "🧨 Write an image BACK to a real disk/partition (DESTRUCTIVE)"
  hr

  local img target t

  img="$(ask_path_existing_file "📥 Enter image path to write: ")"

  echo "Target type:"
  echo "  [1] Whole disk  💽 (wipes everything)"
  echo "  [2] Partition   🧩 (wipes only that partition)"
  read -rp "➡️  Enter number (1-2): " t <"$TTY"

  case "$t" in
    1) target="$(pick_block_device disk)";;
    2) target="$(pick_block_device part)";;
    *) die "Invalid choice.";;
  esac

  maybe_unmount "$target"

  hr
  echo "🔥 FINAL WARNING"
  echo "   Image : $img"
  echo "   Target: $target"
  echo
  echo "📌 Target details:"
  lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL "$target" 2>/dev/null || true
  hr

  echo "To continue, you must type the target EXACTLY:"
  echo "   $target"
  read -rp "✍️  Type target path to confirm: " confirm1 <"$TTY"
  [[ "$confirm1" == "$target" ]] || die "Mismatch. Aborting."

  echo "Now type: WIPE"
  read -rp "✍️  Type WIPE to confirm: " confirm2 <"$TTY"
  [[ "$confirm2" == "WIPE" ]] || die "Not confirmed. Aborting."

  # Extra GUI confirmation for destructive write
  if has_gui; then
    if ! gui_confirm "DESTRUCTIVE WRITE" "You are about to write to:\n$target\n\nThis will ERASE ALL DATA on the target.\n\nAre you absolutely sure?"; then
      die "Cancelled via GUI confirmation."
    fi
  fi
  
  # ── Size check: image vs target ──
  local img_size target_size
  img_size="$(img_virtual_bytes "$img" 2>/dev/null || echo 0)"
  target_size="$(bytes_of_src "$target" 2>/dev/null || echo 0)"

  if [[ "$img_size" =~ ^[0-9]+$ && "$target_size" =~ ^[0-9]+$ && "$img_size" -gt "$target_size" ]]; then
    echo
    warn "⚠️  Image virtual size: $(numfmt --to=iec "$img_size")"
    warn "⚠️  Target device size: $(numfmt --to=iec "$target_size")"
    echo
    warn "The image is LARGER than the target device."
    echo
    echo "  💡 Tip: Use Option 12 (Resize/Shrink Image) to reduce the image size first."
    echo "     This allows writing to smaller drives if the actual data fits."
    echo
    read -rp "Continue anyway? (y/N): " ans <"$TTY"
    [[ "${ans,,}" == "y" ]] || die "Cancelled due to size mismatch."
  fi

  log "Writing (image → raw → device)…"
    # Verify source image before writing
  if ! verify_image "$img"; then
    warn "Source image has issues. Writing a corrupted image may brick the target."
    read -rp "Continue anyway? (y/N): " ans <"$TTY"
    [[ "${ans,,}" == "y" ]] || die "Cancelled due to image verification failure."
  fi

  log "Writing (image → raw → device)…"

  # Detect if image is compressed
  local is_compressed=false
  if qemu-img info "$img" 2>/dev/null | grep -qi "compress"; then
    is_compressed=true
    log "Compressed image detected — using low-memory mode (-m 1)"
  fi

  local total
  total="$(get_total_bytes "$img" 2>/dev/null || echo 0)"
  total="${total:-0}"

  # Build qemu-img convert command
  local convert_args=(qemu-img convert -p)
  if [[ "$is_compressed" == "true" ]]; then
    convert_args+=(-m 1)
  fi
  convert_args+=(-O raw "$img" "$target")

  local rc=0
  if [[ -t 2 && "$total" =~ ^[0-9]+$ && "$total" -gt 0 ]]; then
    qemu_img_convert_with_tty_progress "$total" "Writing" "${convert_args[@]}" || rc=$?
  else
    "${convert_args[@]}" || rc=$?
  fi

  # Handle write failures with helpful hints
  if [[ $rc -ne 0 ]]; then
    err "Write failed (exit code: $rc)"
    echo
    warn "Possible causes and fixes:"
    echo "  1. If you saw 'Cannot allocate memory':"
    echo "     • Increase available RAM (WSL: edit .wslconfig → memory=...)"
    echo "     • Close other applications to free RAM"
    echo "     • Retry manually with: qemu-img convert -p -n -m 1 -O raw \"$img\" \"$target\""
    echo "  2. Check target device health and free space"
    echo "  3. Verify the source image: qemu-img check \"$img\""
    echo
    die "Write failed. Target device may be partially written."
  fi

  sync
  parent="$(lsblk -no PKNAME "$target" 2>/dev/null || true)"
  if [[ -n "$parent" ]]; then
    partprobe "/dev/$parent" 2>/dev/null || true
  else
    partprobe "$target" 2>/dev/null || true
  fi

  log "Restore complete ✅"
  lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS "$target" 2>/dev/null || true
  pause
}

# ============================================================
# Option 13: Disk Health Check
# Uses smartctl for SMART data and badblocks for sector check
# Helps users decide if a drive is safe to clone/image
# ============================================================
disk_health_check() {
  hr
  echo "🏥 Disk Health Check"
  hr

  local disk
  disk="$(pick_block_device disk)"

  # Check dependencies
  if ! command -v smartctl >/dev/null 2>&1; then
    warn "smartctl not found. Install: sudo apt install smartmontools"
    ask_yesno "Continue with badblocks only?" "Y" || die "Cancelled."
  fi

  echo
  log "Checking disk: $disk"
  echo

  # ── SMART Check ──
  if command -v smartctl >/dev/null 2>&1; then
    echo "━━━ SMART Information ━━━"
    smartctl -i "$disk" 2>/dev/null || warn "Cannot read SMART info"
    echo

    echo "━━━ SMART Health Status ━━━"
    local smart_status
    smart_status="$(smartctl -H "$disk" 2>/dev/null | grep -i "result")"
    if echo "$smart_status" | grep -qi "PASSED"; then
      success "SMART overall health: PASSED"
    elif echo "$smart_status" | grep -qi "FAILED"; then
      err "SMART overall health: FAILED — Drive may be dying!"
    else
      warn "SMART status: Unknown or not supported"
    fi
    echo

    echo "━━━ SMART Error Log ━━━"
    smartctl -l error "$disk" 2>/dev/null | tail -5 || true
    echo
  fi

  # ── Badblocks Check ──
  echo "━━━ Bad Sectors Check ━━━"
  warn "This performs a READ-ONLY scan. It may take a long time."
  ask_yesno "Run badblocks scan?" "N" || { pause; return; }

  local disk_size
  disk_size="$(blockdev --getsize64 "$disk" 2>/dev/null || echo 0)"
  log "Scanning $(numfmt --to=iec "$disk_size") …"

  local bad_count=0
  local start_ts
  start_ts="$(date +%s)"

  # Run badblocks in read-only mode, count errors
  badblocks -v -s "$disk" 2>&1 | tee /tmp/badblocks_output.txt || true

  bad_count="$(grep -c "^/" /tmp/badblocks_output.txt 2>/dev/null || echo 0)"
  rm -f /tmp/badblocks_output.txt

  local end_ts duration
  end_ts="$(date +%s)"
  duration=$((end_ts - start_ts))

  echo
  if [[ "$bad_count" -eq 0 ]]; then
    success "No bad sectors found."
  else
    err "Found $bad_count bad sectors!"
    warn "This drive may be failing. Do not use for critical data."
  fi

  echo
  log "Scan duration: $(printf '%02d:%02d:%02d' $((duration/3600)) $(((duration%3600)/60)) $((duration%60)))"
  _write_log "HEALTH" "$disk: $bad_count bad sectors, SMART: ${smart_status:-unknown}"
  pause
}

# ============================================================
# Option 14: MBR/GPT Conversion
# Uses sgdisk to convert partition tables between MBR and GPT
# WARNING: This modifies the partition table structure
# ============================================================
mbr_gpt_convert() {
  hr
  echo "🔄 MBR/GPT Partition Table Conversion"
  hr

  # Check sgdisk dependency
  if ! command -v sgdisk >/dev/null 2>&1; then
    die "sgdisk not found. Install: sudo apt install gdisk"
  fi

  local disk
  disk="$(pick_block_device disk)"
  maybe_unmount "$disk"

  # Detect current partition table type
  local current_type
  current_type="$(lsblk -no PTTYPE "$disk" 2>/dev/null | head -n1)"

  echo
  case "$current_type" in
    gpt)
      log "Current partition table: GPT"
      echo
      warn "You are converting GPT → MBR."
      warn "⚠️  This may fail if you have more than 4 primary partitions"
      warn "   or partitions larger than 2TB."
      ;;
    dos)
      log "Current partition table: MBR (dos)"
      echo
      warn "You are converting MBR → GPT."
      warn "This is generally safe but changes the partition table format."
      ;;
    "")
      warn "No partition table detected on $disk."
      ask_yesno "Create a new GPT partition table?" "N" || die "Cancelled."
      sgdisk --zap-all "$disk"
      success "GPT partition table created (empty)."
      pause
      return
      ;;
    *)
      warn "Unknown partition table type: $current_type"
      ;;
  esac

  echo
  echo "📌 Current partition layout:"
  lsblk -o NAME,TYPE,SIZE,FSTYPE "$disk" || true
  echo

  # Confirm conversion
  hr
  echo "🔥 WARNING: Partition Table Conversion"
  echo "   Target: $disk"
  echo "   Current: ${current_type:-none}"
  echo
  warn "This operation modifies the partition table."
  warn "While it attempts to preserve partitions, BACKUP YOUR DATA FIRST."
  hr

  echo "To continue, type the target EXACTLY:"
  echo "   $disk"
  read -rp "✍️  Type target path to confirm: " confirm1 <"$TTY"
  [[ "$confirm1" == "$disk" ]] || die "Mismatch. Aborting."

  echo "Now type: CONVERT"
  read -rp "✍️  Type CONVERT to confirm: " confirm2 <"$TTY"
  [[ "$confirm2" == "CONVERT" ]] || die "Not confirmed. Aborting."

  # Perform conversion
  log "Converting partition table…"

  case "$current_type" in
    gpt)
      # GPT → MBR
      sgdisk --gpttombr "$disk" || {
        err "Conversion failed."
        die "MBR conversion failed. Your data may still be intact, but the partition table is modified."
      }
      success "Converted GPT → MBR"
      ;;
    dos)
      # MBR → GPT
      sgdisk --mbrtogpt "$disk" || {
        err "Conversion failed."
        die "GPT conversion failed. Your data may still be intact, but the partition table is modified."
      }
      success "Converted MBR → GPT"
      ;;
    *)
      die "Unsupported conversion."
      ;;
  esac

  # Refresh and verify
  partprobe "$disk" 2>/dev/null || true
  sleep 1

  echo
  log "New partition layout:"
  lsblk -o NAME,TYPE,SIZE,FSTYPE "$disk" || true
  _write_log "CONVERT" "$disk: ${current_type:-none} → converted"
  pause
}

# ============================================================
# Option 12: Resize/Shrink Image
# Shrinks filesystems and partition tables inside an image
# Supports: ext2/3/4 (resize2fs), NTFS (ntfsresize)
# Use case: Write large images to smaller drives
# ============================================================
# ============================================================
# Option 12: Resize/Shrink Image
# Supports: Virtual shrink, Actual file compaction, or Both
# Uses: Square Root + User Profile strategy for size recommendation
# Supports: ext2/3/4 (resize2fs), NTFS (ntfsresize)
# ============================================================
resize_image() {
  hr
  echo "📏 Resize / Shrink Image"
  hr

  local img block_size=""
  img="$(ask_path_existing_file "📥 Enter image path to resize: ")"

  # ── Show current info ──
  local fmt vsize old_file_size
  fmt="$(detect_img_format "$img")"
  vsize="$(img_virtual_bytes "$img")"
  old_file_size="$(stat -c '%s' "$img" 2>/dev/null || echo 0)"

  echo
  log "Current image info:"
  echo "   Format:          $fmt"
  echo "   Virtual size:    $(numfmt --to=iec "$vsize")"
  echo "   Actual file size: $(numfmt --to=iec "$old_file_size")"
  echo

  if [[ "$fmt" != "qcow2" && "$fmt" != "raw" ]]; then
    die "Only qcow2 and raw images can be resized. Current format: $fmt"
  fi

  # ── Ask: Virtual / Actual / Both ──
  echo "📏 What kind of shrink do you want to perform?"
  echo
  echo "  [1] 📉 Shrink VIRTUAL Size (Internal Partitions)"
  echo "      Benefit: Allows restore to a physically smaller drive (Option 6)."
  echo "      Action:  Shrinks filesystem and partition table inside the image."
  echo
  echo "  [2] 🗜️  Shrink ACTUAL File Size (Host Disk Space)"
  echo "      Benefit: Frees up space on your physical hard drive."
  echo "      Action:  Zeroes out empty space and compacts the file."
  echo
  echo "  [3] 🔄 Do BOTH (Virtual first, then Actual)"
  echo
  read -rp "➡️  Enter choice (1-3): " mode <"$TTY"

  local do_virtual=false do_actual=false
  case "$mode" in
    1) do_virtual=true ;;
    2)
      if [[ "$fmt" == "raw" ]]; then
        die "Actual-only compaction is not supported for raw images. Use Option 1 (Virtual) instead."
      fi
      do_actual=true
      ;;
    3)
      do_virtual=true
      do_actual=true
      ;;
    *) die "Invalid choice." ;;
  esac

  local nbd new_vsize="$vsize"

  # ══════════════════════════════════════════════════════════
  # PHASE 1: VIRTUAL SHRINK
  # ══════════════════════════════════════════════════════════
  if [[ "$do_virtual" == "true" ]]; then
    echo
    hr
    echo "📉 Phase 1: Virtual Shrink"
    hr

    # Connect image via nbd
    nbd="$(pick_free_nbd)"
    log "Using $nbd"
    USED_NBDS+=("$nbd")
    qemu-nbd --connect="$nbd" "$img"
    partprobe "$nbd" 2>/dev/null || true
    sleep 1

    # Detect partitions
    local parts=()
    while IFS= read -r p; do
      [[ -b "$p" ]] && parts+=("$p")
    done < <(lsblk -nrpo NAME,TYPE "$nbd" | awk '$2=="part"{print $1}')

    if ((${#parts[@]} == 0)); then
      qemu-nbd --disconnect "$nbd" 2>/dev/null || true
      die "No partitions found in image. Cannot resize."
    fi

    echo "📦 Partitions found:"
    for i in "${!parts[@]}"; do
      local info
      info="$(lsblk -no SIZE,FSTYPE "${parts[$i]}" 2>/dev/null | sed 's/[[:space:]]\+/ /g')"
      echo "  [$((i+1))] ${parts[$i]} ($info)"
    done
    echo

    # User selects partition
    local sel
    read -rp "➡️  Select partition to shrink (1-${#parts[@]}): " sel <"$TTY"
    [[ "$sel" =~ ^[0-9]+$ ]] || { qemu-nbd --disconnect "$nbd"; die "Invalid selection."; }
    (( sel>=1 && sel<=${#parts[@]} )) || { qemu-nbd --disconnect "$nbd"; die "Out of range."; }

    local target_part="${parts[$((sel-1))]}"
    local part_num
    part_num="$(echo "$target_part" | grep -o '[0-9]*$')"
    local fstype
    fstype="$(lsblk -no FSTYPE "$target_part" 2>/dev/null | head -n1)"
    log "Selected: $target_part (filesystem: $fstype)"

    # Check filesystem support
    case "$fstype" in
      ext4|ext3|ext2)
        command -v resize2fs >/dev/null 2>&1 || { qemu-nbd --disconnect "$nbd"; die "resize2fs not found. Install: sudo apt install e2fsprogs"; }
        ;;
      ntfs)
        command -v ntfsresize >/dev/null 2>&1 || { qemu-nbd --disconnect "$nbd"; die "ntfsresize not found. Install: sudo apt install ntfs-3g"; }
        warn "⚠️  Shrinking NTFS from Linux is risky. Backup your data first!"
        local ntfs_ans
        ntfs_ans="$(ask_yesno "Continue with NTFS shrink?" "N")"
        [[ "$ntfs_ans" == "true" ]] || { qemu-nbd --disconnect "$nbd"; die "Cancelled."; }
        ;;
      *)
        qemu-nbd --disconnect "$nbd" 2>/dev/null || true
        die "Filesystem '$fstype' cannot be shrunk. Supported: ext2/3/4, ntfs."
        ;;
    esac

    # ── Scan filesystem → calculate used data ──
    echo
    log "📊 Scanning filesystem to calculate used data…"

    local min_bytes=0
    local part_total_bytes
    part_total_bytes="$(blockdev --getsize64 "$target_part" 2>/dev/null || echo 0)"

    case "$fstype" in
      ext4|ext3|ext2)
        local min_blocks
        block_size="$(dumpe2fs -h "$target_part" 2>/dev/null | grep "Block size" | awk '{print $3}')"
        min_blocks="$(resize2fs -P "$target_part" 2>/dev/null | awk '{print $NF}')"
        [[ -z "$min_blocks" || -z "$block_size" ]] && { qemu-nbd --disconnect "$nbd"; die "Cannot read filesystem info."; }
        min_bytes=$((min_blocks * block_size))
        ;;
      ntfs)
        local ntfs_used
        ntfs_used="$(ntfsresize --info "$target_part" 2>/dev/null | grep -o 'at [0-9]* bytes' | grep -o '[0-9]*')"
        [[ -z "$ntfs_used" ]] && { qemu-nbd --disconnect "$nbd"; die "Cannot read NTFS info."; }
        min_bytes="$ntfs_used"
        ;;
    esac

    local min_display
    min_display="$(numfmt --to=iec "$min_bytes")"

    echo "   Total partition size:  $(numfmt --to=iec "$part_total_bytes")"
    echo "   Used data + metadata:  $(numfmt --to=iec "$min_bytes")"
    echo "   Minimum safe size:     $min_display"
    echo

    # ── Calculate recommended size (Square Root strategy) ──
    local used_gb=$((min_bytes / 1073741824))
    ((used_gb < 1)) && used_gb=1

    # Integer square root
    local sqrt_val=1
    while ((sqrt_val * sqrt_val <= used_gb)); do
      sqrt_val=$((sqrt_val + 1))
    done
    sqrt_val=$((sqrt_val - 1))
    ((sqrt_val < 1)) && sqrt_val=1

    local base_extra_gb=$sqrt_val

    # ── User Profile selection ──
    local minimal_bytes=$((min_bytes + base_extra_gb * 1073741824))
    local standard_bytes=$((min_bytes + base_extra_gb * 3 * 1073741824))
    local generous_bytes=$((min_bytes + base_extra_gb * 5 * 1073741824))

    echo "📏 Choose how much extra space the VM should have:"
    echo
    echo "  [1] 🔒 Minimal     → +${base_extra_gb} GB  (base × 1)  → Total: $(numfmt --to=iec "$minimal_bytes")"
    echo "      Best for: Read-only VMs, testing, archives"
    echo
    echo "  [2] 🖥️  Standard    → +$((base_extra_gb * 3)) GB  (base × 3)  → Total: $(numfmt --to=iec "$standard_bytes")  ⭐ Recommended"
    echo "      Best for: Normal desktop/server use"
    echo
    echo "  [3] 📈 Generous    → +$((base_extra_gb * 5)) GB  (base × 5)  → Total: $(numfmt --to=iec "$generous_bytes")"
    echo "      Best for: Databases, heavy growth, frequent updates"
    echo
    echo "  [4] ✏️  Custom      → Enter your own size (must be ≥ $min_display)"
    echo
    read -rp "➡️  Enter choice (1-4): " profile <"$TTY"

    local new_size_bytes=0
    case "$profile" in
      1) new_size_bytes="$minimal_bytes" ;;
      2) new_size_bytes="$standard_bytes" ;;
      3) new_size_bytes="$generous_bytes" ;;
      4)
        while true; do
          local custom_size
          read -rp "📏 Enter custom size (e.g., 30G, 50G): " custom_size <"$TTY"
          if [[ "$custom_size" =~ ^[0-9]+[bBkKmMgGtTpPeE]?$ ]]; then
            new_size_bytes="$(numfmt --from=iec "$custom_size" 2>/dev/null || echo 0)"
            if ((new_size_bytes < min_bytes)); then
              warn "Size too small. Minimum safe size is $min_display. Try again."
            else
              break
            fi
          else
            warn "Invalid format. Use numbers followed by K, M, G, or T."
          fi
        done
        ;;
      *) qemu-nbd --disconnect "$nbd" 2>/dev/null || true; die "Invalid choice." ;;
    esac

    local new_size_display
    new_size_display="$(numfmt --to=iec "$new_size_bytes")"
    log "New partition size: $new_size_display"

    # ── Shrink filesystem with progress ──
    echo
    log "Shrinking filesystem on $target_part to $new_size_display …"
    echo "   ⏳ This may take several minutes. Progress is shown below."
    echo

    case "$fstype" in
      ext4|ext3|ext2)
        local fs_block_size="${block_size:-4096}"
        local new_blocks=$((new_size_bytes / fs_block_size))

        # Check if filesystem is already at or below target size
        local current_fs_blocks
        current_fs_blocks="$(dumpe2fs -h "$target_part" 2>/dev/null | grep "Block count" | awk '{print $3}')" || true

        if [[ -n "$current_fs_blocks" ]] && ((current_fs_blocks <= new_blocks)); then
          log "Filesystem already at optimal size ($(numfmt --to=iec $((current_fs_blocks * fs_block_size)))). Skipping shrink."
        else
          # Fix inconsistencies first (-f force, -y yes-to-all; do NOT use -p with -y)
          e2fsck -f -y "$target_part" 2>/dev/null || true

          resize2fs -p "$target_part" "$new_blocks" || {
            qemu-nbd --disconnect "$nbd" 2>/dev/null || true
            die "resize2fs failed."
          }
          success "Filesystem shrunk successfully."
        fi
        ;;
      ntfs)
        ntfsresize --size "$new_size_bytes" "$target_part" || {
          qemu-nbd --disconnect "$nbd" 2>/dev/null || true
          die "ntfsresize failed."
        }
        success "Filesystem shrunk successfully."
        ;;
    esac

    # ── Shrink partition table (intelligent method) ──
    local pt_type resize_ok=false
    pt_type="$(lsblk -no PTTYPE "$nbd" 2>/dev/null | head -n1)"

    local current_part_bytes
    current_part_bytes="$(blockdev --getsize64 "$target_part" 2>/dev/null || echo 0)"

    if ((current_part_bytes <= new_size_bytes)); then
      log "Partition already at optimal size ($(numfmt --to=iec "$current_part_bytes")). Skipping shrink."
      resize_ok=true
    else
      log "Shrinking partition table…"

      if [[ "$pt_type" == "gpt" ]] && command -v sgdisk >/dev/null 2>&1; then
        # ── GPT: use sgdisk ──
        log "Using sgdisk for GPT partition resize…"
        local start_sector
        start_sector="$( (sgdisk -i "$part_num" "$nbd" 2>/dev/null || true) | grep "First sector" | awk '{print $3}')" || true

        if [[ -n "$start_sector" ]]; then
          sgdisk -d "$part_num" "$nbd" 2>/dev/null || true
          sgdisk -n "${part_num}:${start_sector}:+${new_size_bytes}" "$nbd" 2>/dev/null && resize_ok=true
        fi

      elif [[ "$pt_type" == "dos" ]]; then
        # ── MBR: use sfdisk ──
        log "Using sfdisk for MBR partition resize…"
        local part_basename start_sector
        part_basename="$(basename "$target_part")"
        start_sector="$(cat "/sys/class/block/${part_basename}/start" 2>/dev/null)" || true

        if [[ -n "$start_sector" ]]; then
          log "  Start sector: $start_sector"
          local new_size_sectors=$((new_size_bytes / 512))

          local boot_flag
          boot_flag="$( (parted -s "$nbd" print 2>/dev/null || true) | awk -v p="$part_num" '$1==p {for(i=1;i<=NF;i++) if($i=="boot") print "boot"}')" || true

          echo "start=${start_sector}, size=${new_size_sectors}, type=83" | sfdisk --force -N "$part_num" "$nbd" 2>/dev/null && resize_ok=true

          if [[ "$resize_ok" == "true" && "$boot_flag" == "boot" ]]; then
            parted -s "$nbd" set "$part_num" boot on 2>/dev/null || true
          fi
        else
          warn "  Could not detect start sector. Trying resizepart fallback…"
          parted -s "$nbd" resizepart "$part_num" "${new_size_bytes}B" 2>/dev/null && resize_ok=true || true
        fi

      else
        # ── Fallback: parted resizepart ──
        log "Using parted resizepart (fallback)…"
        parted -s "$nbd" resizepart "$part_num" "${new_size_bytes}B" 2>/dev/null && resize_ok=true || true
      fi
    fi

    if [[ "$resize_ok" == "true" ]]; then
      success "Partition table OK."
    else
      warn "Partition resize may have issues. Please verify manually."
    fi

    partprobe "$nbd" 2>/dev/null || true
    sleep 1

    # ── Zero out free space (if doing Both, do it now while connected) ──
    if [[ "$do_actual" == "true" ]]; then
      echo
      log "Zeroing out free space for file compaction…"
      for zp in "${parts[@]}"; do
        local zfstype
        zfstype="$(lsblk -no FSTYPE "$zp" 2>/dev/null | head -n1)"
        local zmnt
        zmnt="$(mktemp -d)"
        if mount -o rw "$zp" "$zmnt" 2>/dev/null; then
          log "  Zeroing free space on $zp (this may take a while)…"
          dd if=/dev/zero of="$zmnt/.zero_fill" bs=1M status=progress || true
          rm -f "$zmnt/.zero_fill"
          sync
          umount "$zmnt" 2>/dev/null || true
        fi
        rmdir "$zmnt" 2>/dev/null || true
      done
      success "Free space zeroed."
    fi

    # Disconnect nbd
    qemu-nbd --disconnect "$nbd" 2>/dev/null || true
    local tmp_nbds=() x
    for x in "${USED_NBDS[@]}"; do
      [[ "$x" == "$nbd" ]] && continue
      tmp_nbds+=("$x")
    done
    USED_NBDS=("${tmp_nbds[@]}")

    # Shrink qcow2 virtual size
    if [[ "$fmt" == "qcow2" ]]; then
      local current_vsize
      current_vsize="$(img_virtual_bytes "$img" 2>/dev/null || echo 0)"
      if ((current_vsize <= new_size_bytes)); then
        log "Virtual size already at optimal size ($(numfmt --to=iec "$current_vsize")). Skipping."
      else
        log "Shrinking qcow2 virtual size…"
        qemu-img resize --shrink "$img" "$new_size_bytes" || {
          warn "qcow2 virtual size shrink failed."
        }
      fi
    fi

    new_vsize="$new_size_bytes"
    success "Virtual shrink complete."
  fi

  # ══════════════════════════════════════════════════════════
  # PHASE 2: ACTUAL FILE SHRINK (Compaction)
  # ══════════════════════════════════════════════════════════
  if [[ "$do_actual" == "true" ]]; then
    echo
    hr
    echo "🗜️  Phase 2: Actual File Shrink (Compaction)"
    hr

    # If Actual Only (no virtual shrink was done), we need to zero out free space
    if [[ "$do_virtual" == "false" ]]; then
      nbd="$(pick_free_nbd)"
      log "Using $nbd"
      USED_NBDS+=("$nbd")
      qemu-nbd --connect="$nbd" "$img"
      partprobe "$nbd" 2>/dev/null || true
      sleep 1

      local parts=()
      while IFS= read -r p; do
        [[ -b "$p" ]] && parts+=("$p")
      done < <(lsblk -nrpo NAME,TYPE "$nbd" | awk '$2=="part"{print $1}')

      if ((${#parts[@]} > 0)); then
        log "Zeroing out free space in all partitions…"
        for zp in "${parts[@]}"; do
          local zmnt
          zmnt="$(mktemp -d)"
          if mount -o rw "$zp" "$zmnt" 2>/dev/null; then
            log "  Zeroing free space on $zp (this may take a while)…"
            dd if=/dev/zero of="$zmnt/.zero_fill" bs=1M status=progress || true
            rm -f "$zmnt/.zero_fill"
            sync
            umount "$zmnt" 2>/dev/null || true
          fi
          rmdir "$zmnt" 2>/dev/null || true
        done
        success "Free space zeroed."
      fi

      qemu-nbd --disconnect "$nbd" 2>/dev/null || true
      local tmp_nbds=() x
      for x in "${USED_NBDS[@]}"; do
        [[ "$x" == "$nbd" ]] && continue
        tmp_nbds+=("$x")
      done
      USED_NBDS=("${tmp_nbds[@]}")
    fi

    # Ask where to save the new compact file
    echo
    log "📦 Creating new compact image…"

    local dst=""
    local outdir
    outdir="$(dirname "$img")"
    local default_name
    default_name="$(basename "$img")"
    default_name="${default_name%.*}_resized.${default_name##*.}"
    local default_path="$outdir/$default_name"

    # Try GUI save dialog first (handles directory + filename in one step)
    if has_gui; then
      local gui_path
      gui_path="$(gui_pick_save_file "Save compact image as" "$default_path")"
      if [[ -n "$gui_path" ]]; then
        dst="$gui_path"
        log "Output: $dst"
      fi
    fi

    # Terminal fallback: single prompt for full path
    if [[ -z "$dst" ]]; then
      echo
      echo "   Default: $default_path"
      while true; do
        read -rp "📁 Save as (full path or just filename): " tmp <"$TTY"
        if [[ -z "$tmp" ]]; then
          dst="$default_path"
          break
        fi
        # If user typed just a filename (no /), use default directory
        if [[ "$tmp" != */* ]]; then
          dst="$outdir/$tmp"
        else
          dst="$tmp"
        fi
        # Verify parent directory exists
        local parent_dir
        parent_dir="$(dirname "$dst")"
        if [[ -d "$parent_dir" ]]; then
          break
        else
          warn "Directory not found: $parent_dir — try again."
        fi
      done
    fi

    if [[ -e "$dst" ]]; then
      warn "File exists: $dst"
      local ow_ans
      ow_ans="$(ask_yesno "Overwrite it?" "N")"
      [[ "$ow_ans" == "true" ]] || die "Cancelled."
      rm -f "$dst"
    fi

    # Convert to compact file
    log "Converting to compact image: $dst"
    echo "   ⏳ This may take several minutes…"

    local total_bytes
    total_bytes="$(img_virtual_bytes "$img" 2>/dev/null || echo 0)"
    local rc=0

    if [[ -t 2 && "$total_bytes" =~ ^[0-9]+$ && "$total_bytes" -gt 0 ]]; then
      qemu_img_convert_with_tty_progress "$total_bytes" "Compacting" \
        qemu-img convert -p -O "$fmt" "$img" "$dst" || rc=$?
    else
      qemu-img convert -p -O "$fmt" "$img" "$dst" || rc=$?
    fi

    if [[ $rc -ne 0 ]]; then
      err "Convert failed (rc=$rc)"
      [[ -f "$dst" ]] && rm -f "$dst"
      die "Image compaction failed."
    fi

    # Verify new file
    log "Verifying new compact image…"
    if ! verify_image "$dst"; then
      warn "⚠️  New image has issues. Keeping old file for safety."
      warn "   Old file: $img"
      warn "   New file: $dst"
      pause
      return
    fi

    # ── Show before/after comparison ──
    local new_file_size
    new_file_size="$(stat -c '%s' "$dst" 2>/dev/null || echo 0)"
    local saved_bytes=$((old_file_size - new_file_size))

    echo
    hr
    echo "📊 Space Comparison"
    hr
    echo "   Old file:     $(numfmt --to=iec "$old_file_size")  ($(basename "$img"))"
    echo "   New file:     $(numfmt --to=iec "$new_file_size")  ($(basename "$dst"))"
    if ((saved_bytes > 0)); then
      echo -e "   ${GREEN}Saved:        $(numfmt --to=iec "$saved_bytes")  ✅${NC}"
    else
      echo "   Saved:        0 (no space reclaimed)"
    fi
    echo
    echo "   Virtual size: $(numfmt --to=iec "$new_vsize")"
    echo "   Format:       $fmt"
    hr

    _write_log "RESIZE" "$img → $dst | old=$(numfmt --to=iec "$old_file_size") new=$(numfmt --to=iec "$new_file_size") saved=$(numfmt --to=iec "$saved_bytes")"

    # ── Ask to delete old file ──
    echo
    log "The new compact image has been verified successfully."
    echo "   Old file: $img ($(numfmt --to=iec "$old_file_size"))"
    echo "   New file: $dst ($(numfmt --to=iec "$new_file_size"))"
    echo

    local del_ans
    del_ans="$(ask_yesno "🗑️  Delete the old large file?" "N")"
    if [[ "$del_ans" == "true" ]]; then
      rm -f "$img"
      success "Old file deleted: $img"
    else
      log "Old file kept: $img"
    fi

    echo
    success "Image resize and compaction complete!"
    echo "   📦 New image: $dst"
    qemu-img info "$dst" 2>/dev/null || true

  else
    # Virtual Only — no compaction, just verify and show summary
    echo
    verify_image "$img" || warn "Image may have issues after resize."

    local new_file_size
    new_file_size="$(stat -c '%s' "$img" 2>/dev/null || echo 0)"

    echo
    hr
    echo "📊 Resize Summary"
    hr
    echo "   Old virtual size:  $(numfmt --to=iec "$vsize")"
    echo "   New virtual size:  $(numfmt --to=iec "$new_vsize")"
    echo "   File size:         $(numfmt --to=iec "$new_file_size")"
    echo "   Format:            $fmt"
    hr
    echo
    info "💡 Tip: Run Option 12 again and choose [2] Actual File Size"
    info "   to compact the file and reclaim disk space."
    echo
    success "Virtual resize complete!"
    echo "   📦 Image: $img"
    qemu-img info "$img" 2>/dev/null || true
  fi

  pause
}

# ============================================================
# Option 11: Smart Data-Level Copy (used blocks only)
# Uses partclone to copy only used filesystem blocks
# Creates much smaller images than block-level copies
# Falls back to rsync if partclone is unavailable
# ============================================================
smart_data_copy() {
  hr
  echo "📦 Smart Data-Level Copy (used blocks only)"
  hr
  warn "Copies ONLY used blocks using partclone, creating smaller images."
  warn "Requires partclone to be installed for the filesystem type."
  echo

  # ── Select source partition ──
  local src
  src="$(pick_block_device part)"
  maybe_unmount "$src"

  # ── Detect filesystem ──
  local fstype
  fstype="$(lsblk -no FSTYPE "$src" 2>/dev/null | head -n1)"
  [[ -n "$fstype" ]] || die "Cannot detect filesystem type on $src"

  log "Detected filesystem: $fstype"

  # ── Check partclone availability ──
  local pc_tool
  pc_tool="$(get_partclone_tool "$fstype")"

  if [[ -z "$pc_tool" ]]; then
    die "Filesystem '$fstype' is not supported by partclone."
  fi

  if ! command -v "$pc_tool" >/dev/null 2>&1; then
    warn "partclone tool not found: $pc_tool"
    echo
    echo "Install with:"
    case "$fstype" in
      ext4|ext3|ext2) echo "  sudo apt install partclone" ;;
      ntfs)           echo "  sudo apt install partclone" ;;
      *)              echo "  sudo apt install partclone" ;;
    esac
    echo
    read -rp "Fall back to rsync copy? (Y/n): " ans <"$TTY"
    if [[ "${ans,,}" == "n" ]]; then
      die "Cancelled. Install partclone and try again."
    fi
    # Fall back to rsync-based copy
    smart_data_copy_rsync "$src" "$fstype"
    return
  fi

  # ── Output setup ──
  local outdir outfile dst
  outdir="$(suggest_out_dir)"

  if has_gui; then
    local gui_dir
    gui_dir="$(gui_pick_directory "Select output directory")"
    [[ -n "$gui_dir" && -d "$gui_dir" ]] && outdir="$gui_dir"
  fi

  read -rp "📁 Output directory [$outdir]: " tmp <"$TTY"
  outdir="${tmp:-$outdir}"
  [[ -d "$outdir" ]] || die "Directory not found: $outdir"

  read -rp "📝 Output file name [data-copy.img]: " outfile <"$TTY"
  [[ -z "$outfile" ]] && outfile="data-copy.img"
  dst="$outdir/$outfile"

  if [[ -e "$dst" ]]; then
    warn "File exists: $dst"
    ask_yesno "Overwrite it?" "N" || die "Cancelled."
    rm -f "$dst"
  fi

  # ── Perform partclone copy ──
  log "Copying used blocks from $src using $pc_tool …"
  log "This creates a sparse image containing only used data."

  local rc=0
  "$pc_tool" -c -s "$src" -o "$dst" --nocheck -L 2>&1 | tee -a "$LOG_FILE" || rc=$?

  if [[ $rc -ne 0 ]]; then
    err "partclone copy failed (rc=$rc)"
    [[ -f "$dst" ]] && rm -f "$dst"
    die "Smart data copy failed."
  fi

  # ── Compress if qcow2 requested ──
  local final_dst="$dst"
  local compress_to_qcow2
  compress_to_qcow2="$(ask_yesno "🗜️  Convert to compressed qcow2?" "Y")"

  if [[ "$compress_to_qcow2" == "true" ]]; then
    local qcow_dst="${dst%.img}.qcow2"
    log "Converting to qcow2: $qcow_dst"
    qemu-img convert -p -c -O qcow2 "$dst" "$qcow_dst" || {
      warn "qcow2 conversion failed. Keeping raw image."
      compress_to_qcow2="false"
    }
    if [[ "$compress_to_qcow2" == "true" ]]; then
      rm -f "$dst"
      final_dst="$qcow_dst"
    fi
  fi

  # ── Verify and report ──
  verify_image "$final_dst" || warn "Image may have issues."
  write_image_metadata "$final_dst" "$src" "Smart data-level copy via partclone ($pc_tool)"

  echo
  success "Smart Data-Level Copy complete!"
  echo "   📦 Output: $final_dst"
  qemu-img info "$final_dst" 2>/dev/null || ls -lh "$final_dst"
  pause
}

# Fallback rsync-based data copy
smart_data_copy_rsync() {
  local src="$1" fstype="$2"

  local outdir outfile dst
  outdir="$(suggest_out_dir)"
  read -rp "📁 Output directory [$outdir]: " tmp <"$TTY"
  outdir="${tmp:-$outdir}"
  [[ -d "$outdir" ]] || die "Directory not found: $outdir"

  read -rp "📝 Output file name [data-copy.qcow2]: " outfile <"$TTY"
  [[ -z "$outfile" ]] && outfile="data-copy.qcow2"
  dst="$outdir/$outfile"

  if [[ -e "$dst" ]]; then
    warn "File exists: $dst"
    ask_yesno "Overwrite it?" "N" || die "Cancelled."
    rm -f "$dst"
  fi

  # Mount source read-only
  local src_mnt
  src_mnt="$(mktemp -d)"
  mount -o ro "$src" "$src_mnt" || { rmdir "$src_mnt"; die "Cannot mount $src"; }

  # Calculate used space
  local used_bytes
  used_bytes="$(df -B1 "$src_mnt" | awk 'NR==2 {print $3}')"
  local img_size=$((used_bytes + 256 * 1024 * 1024))  # used + 256MB overhead

  log "Used data: $(numfmt --to=iec "$used_bytes")"
  log "Creating qcow2 with virtual size: $(numfmt --to=iec "$img_size")"

  qemu-img create -f qcow2 "$dst" "$img_size" >/dev/null

  # Format and mount qcow2
  local nbd
  nbd="$(pick_free_nbd)"
  USED_NBDS+=("$nbd")
  qemu-nbd --connect="$nbd" "$dst"
  partprobe "$nbd" 2>/dev/null || true
  sleep 1

  parted -s "$nbd" mklabel msdos
  parted -s "$nbd" mkpart primary ext4 1MiB 100%
  partprobe "$nbd" 2>/dev/null || true
  sleep 1

  local root_uuid
  root_uuid="$(blkid -s UUID -o value "$src" 2>/dev/null)"
  mkfs.ext4 -q -F -U "${root_uuid}" "${nbd}p1"

  local dst_mnt
  dst_mnt="$(mktemp -d)"
  mount "${nbd}p1" "$dst_mnt"

  log "Copying files via rsync…"
  rsync -aHAXS --numeric-ids --info=progress2 \
    --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' \
    --exclude='/run/*' --exclude='/tmp/*' --exclude='/mnt/*' \
    --exclude='/media/*' --exclude='/lost+found' \
    "$src_mnt/" "$dst_mnt/"

  umount "$dst_mnt"
  rmdir "$dst_mnt"
  umount "$src_mnt"
  rmdir "$src_mnt"

  qemu-nbd --disconnect "$nbd" 2>/dev/null || true
  local tmp_nbds=() x
  for x in "${USED_NBDS[@]}"; do
    [[ "$x" == "$nbd" ]] && continue
    tmp_nbds+=("$x")
  done
  USED_NBDS=("${tmp_nbds[@]}")

  verify_image "$dst" || warn "Image may have issues."
  write_image_metadata "$dst" "$src" "Smart data-level copy via rsync fallback"

  echo
  success "Smart Data-Level Copy (rsync fallback) complete!"
  echo "   📦 Output: $dst"
  qemu-img info "$dst" || true
  pause
}

# ============================================================
# Option 10: Smart OS Migration (bootable VM from real drive)
# Detects: root, boot, EFI partitions automatically
# Copies: data via rsync (preserving UUIDs and permissions)
# Installs: GRUB (BIOS or UEFI), virtio drivers
# Fixes: /etc/fstab for VM compatibility
# Result: A fully bootable qcow2 image
# ============================================================
smart_os_migration() {
  hr
  echo "🚀 Smart OS Migration — Bootable VM from Real Drive"
  hr
  warn "This creates a BOOTABLE qcow2 by copying files (not raw blocks)."
  warn "It detects root/boot/EFI, installs GRUB, and fixes fstab."
  echo

  # ── Check rsync dependency ──
  if ! have rsync; then
    die "rsync is required for Smart OS Migration. Install: sudo apt install rsync"
  fi

  # ── Select source disk ──
  local src_disk
  src_disk="$(pick_block_device disk)"
  maybe_unmount "$src_disk"

  # ── Scan partitions ──
  echo
  log "Scanning partitions on $src_disk …"
  local parts=() fstypes=() sizes=()
  while IFS= read -r line; do
    local p s f
    p="$(echo "$line" | awk '{print $1}')"
    s="$(echo "$line" | awk '{print $2}')"
    f="$(echo "$line" | awk '{print $3}')"
    [[ -b "$p" ]] || continue
    parts+=("$p")
    sizes+=("$s")
    fstypes+=("$f")
  done < <(lsblk -nrpo NAME,SIZE,FSTYPE "$src_disk" | awk '$1 ~ /part/')

  ((${#parts[@]} == 0)) && die "No partitions found on $src_disk"

  # ── Display partitions ──
  echo
  echo "📦 Partitions found on $src_disk:"
  for i in "${!parts[@]}"; do
    printf "  [%d] %-12s %-10s %s\n" "$((i+1))" "${parts[$i]}" "${sizes[$i]}" "${fstypes[$i]}"
  done
  echo

  # ── Detect root partition ──
  local root_part="" root_idx=-1
  echo "🔍 Detecting root partition…"
  for i in "${!parts[@]}"; do
    if [[ "${fstypes[$i]}" == "ext4" || "${fstypes[$i]}" == "btrfs" || "${fstypes[$i]}" == "xfs" ]]; then
      # Try to detect if this partition has /etc/fstab (likely root)
      local tmp_mnt
      tmp_mnt="$(mktemp -d)"
      if mount -o ro "${parts[$i]}" "$tmp_mnt" 2>/dev/null; then
        if [[ -f "$tmp_mnt/etc/fstab" ]]; then
          root_part="${parts[$i]}"
          root_idx=$i
          umount "$tmp_mnt"
          rmdir "$tmp_mnt"
          break
        fi
        umount "$tmp_mnt"
      fi
      rmdir "$tmp_mnt" 2>/dev/null
    fi
  done

  if [[ -z "$root_part" ]]; then
    warn "Could not auto-detect root partition."
    read -rp "➡️  Enter partition number for root (1-${#parts[@]}): " root_idx <"$TTY"
    root_idx=$((root_idx - 1))
    [[ $root_idx -ge 0 && $root_idx -lt ${#parts[@]} ]] || die "Invalid selection."
    root_part="${parts[$root_idx]}"
  fi

  log "Root partition detected: $root_part (${fstypes[$root_idx]})"

  # ── Detect boot/EFI partition ──
  local boot_part="" boot_idx=-1
  for i in "${!parts[@]}"; do
    [[ $i -eq $root_idx ]] && continue
    if [[ "${fstypes[$i]}" == "vfat" ]]; then
      boot_part="${parts[$i]}"
      boot_idx=$i
      log "EFI partition detected: $boot_part (vfat)"
      break
    fi
  done

  # ── Output setup ──
  local outdir fmt outfile dst
  outdir="$(suggest_out_dir)"
  read -rp "📁 Output directory [$outdir]: " tmp <"$TTY"
  outdir="${tmp:-$outdir}"
  [[ -d "$outdir" ]] || die "Directory not found: $outdir"

  read -rp "📝 Output file name [migrated-os.qcow2]: " outfile <"$TTY"
  [[ -z "$outfile" ]] && outfile="migrated-os.qcow2"
  dst="$outdir/$outfile"

  if [[ -e "$dst" ]]; then
    warn "File exists: $dst"
    ask_yesno "Overwrite it?" "N" || die "Cancelled."
    rm -f "$dst"
  fi

  # ── Calculate size ──
  local root_size
  root_size="$(bytes_of_src "$root_part")"
  local img_size=$((root_size + 512 * 1024 * 1024))  # root + 512MB overhead

  echo
  log "Creating qcow2: $dst (virtual size: $(numfmt --to=iec "$img_size"))"
  qemu-img create -f qcow2 "$dst" "$img_size" >/dev/null

  # ── Attach via nbd ──
  local nbd
  nbd="$(pick_free_nbd)"
  log "Using $nbd"
  USED_NBDS+=("$nbd")

  qemu-nbd --connect="$nbd" "$dst"
  partprobe "$nbd" 2>/dev/null || true
  sleep 1

  # ── Partition the virtual disk ──
  log "Creating partition table…"
  if [[ -n "$boot_part" ]]; then
    # UEFI layout: EFI + root
    parted -s "$nbd" mklabel gpt
    parted -s "$nbd" mkpart "EFI" fat32 1MiB 513MiB
    parted -s "$nbd" set 1 esp on
    parted -s "$nbd" mkpart "ROOT" ext4 513MiB 100%
  else
    # BIOS layout: root only
    parted -s "$nbd" mklabel msdos
    parted -s "$nbd" mkpart primary ext4 1MiB 100%
    parted -s "$nbd" set 1 boot on
  fi

  partprobe "$nbd" 2>/dev/null || true
  sleep 1

  # ── Format and copy ──
  local root_uuid
  root_uuid="$(blkid -s UUID -o value "$root_part" 2>/dev/null)"

  if [[ -n "$boot_part" ]]; then
    # UEFI: format EFI + root
    mkfs.vfat -F 32 -n EFI "${nbd}p1" >/dev/null
    mkfs.ext4 -q -F -U "$root_uuid" "${nbd}p2"

    local mnt_root mnt_boot
    mnt_root="$(mktemp -d)"
    mnt_boot="$(mktemp -d)"
    mount "${nbd}p2" "$mnt_root"
    mkdir -p "$mnt_root/boot/efi"
    mount "${nbd}p1" "$mnt_root/boot/efi"

    log "Copying root filesystem (this may take a while)…"
    rsync -aHAXS --numeric-ids --info=progress2 \
      --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' \
      --exclude='/run/*' --exclude='/tmp/*' --exclude='/mnt/*' \
      --exclude='/media/*' --exclude='/lost+found' \
      "$root_part_mount/" "$mnt_root/" 2>/dev/null || {
        # Mount source root and copy
        local src_mnt
        src_mnt="$(mktemp -d)"
        mount -o ro "$root_part" "$src_mnt"
        rsync -aHAXS --numeric-ids --info=progress2 \
          --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' \
          --exclude='/run/*' --exclude='/tmp/*' --exclude='/mnt/*' \
          --exclude='/media/*' --exclude='/lost+found' \
          "$src_mnt/" "$mnt_root/"
        umount "$src_mnt"
        rmdir "$src_mnt"
      }

    # Copy EFI partition
    local efi_src_mnt
    efi_src_mnt="$(mktemp -d)"
    mount -o ro "$boot_part" "$efi_src_mnt"
    rsync -aAX --numeric-ids "$efi_src_mnt/" "$mnt_root/boot/efi/"
    umount "$efi_src_mnt"
    rmdir "$efi_src_mnt"

  else
    # BIOS: format root only
    mkfs.ext4 -q -F -U "$root_uuid" "${nbd}p1"

    local mnt_root
    mnt_root="$(mktemp -d)"
    mount "${nbd}p1" "$mnt_root"

    log "Copying root filesystem (this may take a while)…"
    local src_mnt
    src_mnt="$(mktemp -d)"
    mount -o ro "$root_part" "$src_mnt"
    rsync -aHAXS --numeric-ids --info=progress2 \
      --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' \
      --exclude='/run/*' --exclude='/tmp/*' --exclude='/mnt/*' \
      --exclude='/media/*' --exclude='/lost+found' \
      "$src_mnt/" "$mnt_root/"
    umount "$src_mnt"
    rmdir "$src_mnt"
  fi

  # ── Fix fstab ──
  log "Fixing /etc/fstab…"
  awk -v u="$root_uuid" '
  /^[[:space:]]*#/ { print; next }
  NF >= 3 {
    if ($2 == "/") { $1 = "UUID=" u; print; next }
    if ($3 ~ /^(swap|ext2|ext3|ext4|xfs|btrfs|ntfs|vfat|exfat)$/) {
      print "#" $0; next
    }
  }
  { print }
  ' "$mnt_root/etc/fstab" > "$mnt_root/etc/fstab.new"
  mv "$mnt_root/etc/fstab.new" "$mnt_root/etc/fstab"

  # ── Add virtio drivers ──
  log "Adding virtio drivers…"
  mkdir -p "$mnt_root/etc/initramfs-tools"
  for m in virtio_pci virtio_blk virtio_net virtio_scsi; do
    grep -qx "$m" "$mnt_root/etc/initramfs-tools/modules" 2>/dev/null || echo "$m" >> "$mnt_root/etc/initramfs-tools/modules"
  done
  rm -f "$mnt_root/etc/initramfs-tools/conf.d/resume"

  # ── Install GRUB ──
  log "Installing GRUB bootloader…"
  for d in dev dev/pts proc sys run; do
    mkdir -p "$mnt_root/$d"
    mount --bind "/$d" "$mnt_root/$d"
  done

  if [[ -n "$boot_part" ]]; then
    # UEFI GRUB
    chroot "$mnt_root" /bin/bash -c "
      set -e
      export DEBIAN_FRONTEND=noninteractive
      update-initramfs -u -k all || update-initramfs -u
      grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck --force
      update-grub
    "
  else
    # BIOS GRUB
    chroot "$mnt_root" /bin/bash -c "
      set -e
      export DEBIAN_FRONTEND=noninteractive
      update-initramfs -u -k all || update-initramfs -u
      grub-install --target=i386-pc --recheck --force $nbd
      update-grub
    "
  fi

  # ── Cleanup ──
  log "Cleaning up…"
  for d in run sys proc dev/pts dev; do
    umount "$mnt_root/$d" 2>/dev/null || true
  done

  if [[ -n "$boot_part" ]]; then
    umount "$mnt_root/boot/efi" 2>/dev/null || true
  fi
  umount "$mnt_root" 2>/dev/null || true
  rmdir "$mnt_root" 2>/dev/null || true
  if [[ -n "$mnt_boot" ]]; then
    rmdir "$mnt_boot" 2>/dev/null || true
  fi

  qemu-nbd --disconnect "$nbd" 2>/dev/null || true
  # Remove from USED_NBDS
  local tmp_nbds=() x
  for x in "${USED_NBDS[@]}"; do
    [[ "$x" == "$nbd" ]] && continue
    tmp_nbds+=("$x")
  done
  USED_NBDS=("${tmp_nbds[@]}")

  # ── Verify ──
  verify_image "$dst" || warn "Image may have issues."

  echo
  log "🎉 Smart OS Migration complete!"
  echo "   📦 Output: $dst"
  qemu-img info "$dst" || true
  pause
}

# ============================================================
# Option 9: Direct Clone (disk/partition → disk/partition)
# DESTRUCTIVE: Wipes target device completely
# No intermediate image file needed
# Supports: pv for faster raw copies, size validation
# ============================================================
direct_clone() {
  hr
  echo "📀 Direct Clone (disk/partition → disk/partition)"
  hr

  local src target t

  # ── Pick source ──
  echo "Source type:"
  echo "  [1] Whole disk  💽"
  echo "  [2] Partition   🧩"
  read -rp "➡️  Enter number (1-2): " t <"$TTY"

  case "$t" in
    1) src="$(pick_block_device disk)";;
    2) src="$(pick_block_device part)";;
    *) die "Invalid choice.";;
  esac

  maybe_unmount "$src"

  # ── Pick target ──
  echo
  echo "Target type:"
  echo "  [1] Whole disk  💽 (wipes everything)"
  echo "  [2] Partition   🧩 (wipes only that partition)"
  read -rp "➡️  Enter number (1-2): " t <"$TTY"

  case "$t" in
    1) target="$(pick_block_device disk)";;
    2) target="$(pick_block_device part)";;
    *) die "Invalid choice.";;
  esac

  # Prevent cloning to self
  if [[ "$src" == "$target" ]]; then
    die "Source and target are the same device. Aborting."
  fi

  maybe_unmount "$target"

  # ── Size check ──
  local src_size target_size
  src_size="$(bytes_of_src "$src" 2>/dev/null || echo 0)"
  target_size="$(bytes_of_src "$target" 2>/dev/null || echo 0)"

  if [[ "$src_size" =~ ^[0-9]+$ && "$target_size" =~ ^[0-9]+$ && "$src_size" -gt "$target_size" ]]; then
    echo
    warn "⚠️  Source size: $(numfmt --to=iec "$src_size")"
    warn "⚠️  Target size: $(numfmt --to=iec "$target_size")"
    echo
    warn "Source is LARGER than target. Clone will fail."
    read -rp "Continue anyway? (y/N): " ans <"$TTY"
    [[ "${ans,,}" == "y" ]] || die "Cancelled due to size mismatch."
  fi

  # ── Final confirmation ──
  hr
  echo "🔥 FINAL WARNING — DIRECT CLONE"
  echo "   Source: $src ($(numfmt --to=iec "$src_size"))"
  echo "   Target: $target ($(numfmt --to=iec "$target_size"))"
  echo
  echo "📌 Target details:"
  lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL "$target" 2>/dev/null || true
  hr

  echo "To continue, type the target EXACTLY:"
  echo "   $target"
  read -rp "✍️  Type target path to confirm: " confirm1 <"$TTY"
  [[ "$confirm1" == "$target" ]] || die "Mismatch. Aborting."

  echo "Now type: CLONE"
  read -rp "✍️  Type CLONE to confirm: " confirm2 <"$TTY"
  [[ "$confirm2" == "CLONE" ]] || die "Not confirmed. Aborting."

  # ── Perform clone ──
  log "Cloning $src → $target …"

  local total="$src_size"
  local rc=0
  local use_pv_method=false

  # Ask if user wants pv (faster for raw copies)
  if use_pv; then
    use_pv_method="$(ask_yesno "🚀 Use pv for faster raw copy? (recommended)" "Y")"
  fi

  if [[ "$use_pv_method" == "true" ]]; then
    log "Using pv for block-level copy…"
    pv -s "$total" -N "Cloning $src → $target" "$src" > "$target" || rc=$?
  else
    if [[ -t 2 && "$total" =~ ^[0-9]+$ && "$total" -gt 0 ]]; then
      qemu_img_convert_with_tty_progress "$total" "Cloning" \
        qemu-img convert -p -f raw -O raw "$src" "$target" || rc=$?
    else
      qemu-img convert -p -f raw -O raw "$src" "$target" || rc=$?
    fi
  fi

  if [[ $rc -ne 0 ]]; then
    err "Clone failed (rc=$rc)"
    die "Clone operation failed. Target may be partially written."
  fi

  sync
  local parent
  parent="$(lsblk -no PKNAME "$target" 2>/dev/null || true)"
  if [[ -n "$parent" ]]; then
    partprobe "/dev/$parent" 2>/dev/null || true
  else
    partprobe "$target" 2>/dev/null || true
  fi

  log "Clone complete ✅"
  lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS "$target" 2>/dev/null || true
  pause
}

delete_image_file() {
  hr
  echo "🗑️ Delete an image file (safe prompt)"
  hr

  local f
  f="$(ask_path_existing_file "📦 Enter file path to delete: ")"

  hr
  echo "File:"
  echo "  $f"
  echo "Size:"
  du -h "$f" | awk '{print "  " $1}'
  hr

  echo "Type DELETE to remove it:"
  read -rp "✍️  Confirm: " c <"$TTY"
  [[ "$c" == "DELETE" ]] || die "Not confirmed. Aborting."

  rm -f -- "$f"
  log "Deleted ✅"
  pause
}



image_info() {
  hr
  echo "ℹ️ Image info"
  hr
  local f
  f="$(ask_path_existing_file "📦 Enter image path: ")"
  qemu-img info "$f" || true
  pause
}

global_cleanup() {
  set +e

  # Disconnect all used nbd devices
  for d in "${USED_NBDS[@]}"; do
    [[ "$d" =~ ^/dev/nbd[0-9]+$ ]] || continue

    local idx sz
    idx="${d#/dev/nbd}"
    sz="$(cat "/sys/block/nbd${idx}/size" 2>/dev/null || echo 0)"

    # Only disconnect if it still looks connected
    [[ "${sz:-0}" != "0" ]] || continue
    qemu-nbd --disconnect "$d" >/dev/null 2>&1 || true
  done

  # Clear the USED_NBDS array
  USED_NBDS=()

  # Wait for disconnects to settle
  sleep 0.5

  # Check if ANY nbd device is still in use
  local any_in_use=0
  for dev in /sys/block/nbd*; do
    [[ -d "$dev" ]] || continue
    local sz
    sz="$(cat "$dev/size" 2>/dev/null || echo 0)"
    if [[ "${sz:-0}" != "0" ]]; then
      any_in_use=1
      break
    fi
  done

  # If no nbd devices are in use, unload the module
  if [[ "$any_in_use" -eq 0 ]]; then
    modprobe -r nbd 2>/dev/null || true
    NBD_LOADED_BY_US=0
  fi
}
trap global_cleanup EXIT INT TERM

write_image_metadata() {
  local img="$1"
  local src="${2:-unknown}"
  local notes="${3:-}"
  
  local info_file="${img}.info"
  local fmt vsize dsize
  fmt="$(detect_img_format "$img" 2>/dev/null || echo "unknown")"
  vsize="$(qemu-img info "$img" 2>/dev/null | awk -F': ' '/^virtual size:/ {print $2; exit}')"
  dsize="$(stat -c '%s' "$img" 2>/dev/null || echo "0")"
  
  cat > "$info_file" 2>/dev/null <<METAEOF
# QEMU Disk Tool — Image Metadata
# Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')

[Image]
File: $(basename "$img")
Format: ${fmt}
Virtual_Size: ${vsize:-unknown}
Disk_Size_Bytes: ${dsize}

[Source]
Device: ${src}
Hostname: $(hostname 2>/dev/null || echo "unknown")
User: ${SUDO_USER:-$USER}

[Partition_Info]
$(if [[ -b "$src" ]]; then
  lsblk -nrpo NAME,SIZE,FSTYPE "$src" 2>/dev/null | head -20 || echo "  (unable to read partition info)"
else
  echo "  (source is not a block device)"
fi)

[Notes]
${notes:-No additional notes}
METAEOF

  if [[ -f "$info_file" ]]; then
    log "📝 Metadata saved: $info_file"
    _write_log "METADATA" "Created $info_file for $img"
  fi
}

print_summary() {
  local op="$1" src="$2" dst="$3" start_ts="$4"
  local end_ts duration src_size dst_size
  
  end_ts="$(date +%s)"
  duration=$((end_ts - start_ts))
  
  src_size="$( [[ -b "$src" ]] && blockdev --getsize64 "$src" 2>/dev/null || stat -c '%s' "$src" 2>/dev/null || echo 0 )"
  dst_size="$( [[ -b "$dst" ]] && blockdev --getsize64 "$dst" 2>/dev/null || stat -c '%s' "$dst" 2>/dev/null || echo 0 )"
  
  echo
  hr
  echo "📊 Operation Summary"
  hr
  echo "   Operation: $op"
  echo "   Source:    $src ($(numfmt --to=iec "${src_size:-0}"))"
  echo "   Dest:      $dst ($(numfmt --to=iec "${dst_size:-0}"))"
  echo "   Duration:  $(printf '%02d:%02d:%02d' $((duration/3600)) $(((duration%3600)/60)) $((duration%60)))"
  hr
  _write_log "SUMMARY" "$op | $src -> $dst | ${duration}s"
}

# ============================================================
# Option 15: Repair Image / Disk / Partition
# Comprehensive diagnostic and repair tool.
# Handles: filesystem corruption, size mismatches,
#          partition table issues, qcow2 integrity,
#          boot flags, and filesystem expansion.
# Supports: ext2/3/4, NTFS, qcow2, raw, physical disks.
# ============================================================
repair_target() {
  hr
  echo "🔧 Repair Image / Disk / Partition"
  hr
  warn "Diagnoses and repairs filesystem, partition, and image issues."
  echo

  # ── Step 1: Ask what to repair ──
  echo "  What do you want to repair?"
  echo
  echo "  [1] 📦 Image file (qcow2, raw, etc.)"
  echo "  [2] 💽 Physical disk"
  echo "  [3] 📂 Physical partition"
  echo
  local target_type
  read -rp "➡️  Enter choice (1-3): " target_type <"$TTY"

  local img="" nbd="" target_disk="" is_image=false

  case "$target_type" in
    1)
      is_image=true
      img="$(ask_path_existing_file "📥 Enter image path to repair: ")"
      local fmt
      fmt="$(detect_img_format "$img")"
      log "Image: $img (format: $fmt)"

      # Check qcow2 integrity first
      if [[ "$fmt" == "qcow2" ]]; then
        echo
        log "Checking qcow2 image integrity…"
        local check_output
        check_output="$(qemu-img check "$img" 2>&1)" || true
        echo "$check_output"
        if ! echo "$check_output" | grep -qi "No errors"; then
          warn "qcow2 image has errors. Attempting repair…"
          qemu-img check -r all "$img" 2>&1 || true
          log "qcow2 repair attempted."
        else
          success "qcow2 image structure is healthy."
        fi
      fi

      # Connect via nbd
      nbd="$(pick_free_nbd)"
      log "Using $nbd"
      USED_NBDS+=("$nbd")
      qemu-nbd --connect="$nbd" "$img"
      partprobe "$nbd" 2>/dev/null || true
      sleep 1
      target_disk="$nbd"
      ;;
    2)
      target_disk="$(pick_block_device disk)"
      maybe_unmount "$target_disk"
      log "Physical disk: $target_disk"
      ;;
    3)
      local target_part_direct
      target_part_direct="$(pick_block_device part)"
      maybe_unmount "$target_part_direct"
      log "Physical partition: $target_part_direct"
      # For single partition repair, we handle it directly
      _repair_single_partition "$target_part_direct"
      pause
      return
      ;;
    *)
      die "Invalid choice."
      ;;
  esac

  # ── Step 2: Detect all partitions ──
  local parts=()
  while IFS= read -r p; do
    [[ -b "$p" ]] && parts+=("$p")
  done < <(lsblk -nrpo NAME,TYPE "$target_disk" | awk '$2=="part"{print $1}')

  if ((${#parts[@]} == 0)); then
    warn "No partitions found."
    if [[ "$is_image" == "true" ]]; then
      qemu-nbd --disconnect="$nbd" 2>/dev/null || true
      local tmp_nbds=() x
      for x in "${USED_NBDS[@]}"; do
        [[ "$x" == "$nbd" ]] && continue
        tmp_nbds+=("$x")
      done
      USED_NBDS=("${tmp_nbds[@]}")
    fi
    die "Cannot repair: no partitions found."
  fi

  echo
  echo "📦 Partitions found:"
  for i in "${!parts[@]}"; do
    local info
    info="$(lsblk -no SIZE,FSTYPE "${parts[$i]}" 2>/dev/null | sed 's/[[:space:]]\+/ /g')"
    echo "  [$((i+1))] ${parts[$i]} ($info)"
  done
  echo

  # ── Step 3: Run diagnostics on all partitions ──
  log "🔍 Running diagnostics on all partitions…"
  echo

  local issues_found=0
  local -a issue_list=()
  local -a fix_commands=()

  for i in "${!parts[@]}"; do
    local part="${parts[$i]}"
    local fstype
    fstype="$(lsblk -no FSTYPE "$part" 2>/dev/null | head -n1)"
    local part_size_bytes
    part_size_bytes="$(blockdev --getsize64 "$part" 2>/dev/null || echo 0)"

    echo "━━━ Partition $((i+1)): $part ($fstype) ━━━"

    case "$fstype" in
      ext4|ext3|ext2)
        local fs_block_size fs_blocks part_blocks
        fs_block_size="$(dumpe2fs -h "$part" 2>/dev/null | grep "Block size" | awk '{print $3}')" || true
        fs_blocks="$(dumpe2fs -h "$part" 2>/dev/null | grep "Block count" | awk '{print $3}')" || true
        fs_block_size="${fs_block_size:-4096}"
        part_blocks=$((part_size_bytes / fs_block_size))

        echo "   Filesystem blocks:  ${fs_blocks:-unknown}"
        echo "   Partition blocks:   $part_blocks"
        echo "   Filesystem size:    $(numfmt --to=iec $((${fs_blocks:-0} * fs_block_size)) 2>/dev/null || echo 'unknown')"
        echo "   Partition size:     $(numfmt --to=iec "$part_size_bytes")"

        # Check 1: Filesystem > Partition (corruption)
        if [[ -n "$fs_blocks" ]] && ((fs_blocks > part_blocks)); then
          echo -e "   ${RED}❌ ISSUE: Filesystem is LARGER than partition by $((fs_blocks - part_blocks)) blocks${NC}"
          issue_list+=("P$((i+1)): Filesystem larger than partition → will shrink filesystem to match")
          fix_commands+=("resize2fs -f '$part' '$part_blocks'")
          issues_found=$((issues_found + 1))
        # Check 2: Filesystem < Partition (unexpanded)
        elif [[ -n "$fs_blocks" ]] && ((fs_blocks < part_blocks - 1024)); then
          echo -e "   ${YELLOW}⚠️  NOTE: Filesystem is smaller than partition (may need expansion)${NC}"
          issue_list+=("P$((i+1)): Filesystem smaller than partition → can expand to fill")
          fix_commands+=("resize2fs '$part'")
          issues_found=$((issues_found + 1))
        else
          echo -e "   ${GREEN}✅ Filesystem size matches partition${NC}"
        fi

        # Check 3: Filesystem integrity (dry run)
        echo "   Running e2fsck dry-run check…"
        local e2fsck_output
        e2fsck_output="$(e2fsck -n -f "$part" 2>&1)" || true
        if echo "$e2fsck_output" | grep -qi "error\|corrupt\|invalid\|bad"; then
          echo -e "   ${RED}❌ ISSUE: Filesystem has errors${NC}"
          issue_list+=("P$((i+1)): Filesystem errors detected → will run e2fsck -f -y")
          fix_commands+=("e2fsck -f -y '$part'")
          issues_found=$((issues_found + 1))
        else
          echo -e "   ${GREEN}✅ Filesystem integrity: clean${NC}"
        fi
        ;;

      ntfs)
        echo "   Partition size: $(numfmt --to=iec "$part_size_bytes")"

        # Check NTFS integrity
        echo "   Running ntfsfix dry-run check…"
        local ntfsfix_output
        ntfsfix_output="$(ntfsfix -n "$part" 2>&1)" || true
        if echo "$ntfsfix_output" | grep -qi "error\|corrupt\|fail"; then
          echo -e "   ${RED}❌ ISSUE: NTFS has errors${NC}"
          issue_list+=("P$((i+1)): NTFS errors detected → will run ntfsfix")
          fix_commands+=("ntfsfix '$part'")
          issues_found=$((issues_found + 1))
        else
          echo -e "   ${GREEN}✅ NTFS integrity: clean${NC}"
        fi

        # Check NTFS size
        local ntfs_used
        ntfs_used="$(ntfsresize --info "$part" 2>/dev/null | grep -o 'at [0-9]* bytes' | grep -o '[0-9]*')" || true
        if [[ -n "$ntfs_used" ]]; then
          echo "   Used data: $(numfmt --to=iec "$ntfs_used")"
        fi
        ;;

      "")
        echo -e "   ${YELLOW}⚠️  No filesystem detected (may be swap, LVM, or unformatted)${NC}"
        ;;

      *)
        echo "   Filesystem type: $fstype (no repair support for this type)"
        ;;
    esac
    echo
  done

  # ── Step 4: Check partition table ──
  echo "━━━ Partition Table Check ━━━"
  local pt_type
  pt_type="$(lsblk -no PTTYPE "$target_disk" 2>/dev/null | head -n1)"
  echo "   Partition table type: ${pt_type:-none}"

  if [[ -z "$pt_type" ]]; then
    echo -e "   ${RED}❌ ISSUE: No partition table detected${NC}"
    issue_list+=("Disk: No partition table detected")
    issues_found=$((issues_found + 1))
  else
    echo -e "   ${GREEN}✅ Partition table present${NC}"
  fi
  echo

  # ── Step 5: Show summary and ask to fix ──
  if ((issues_found == 0)); then
    success "🎉 No issues found. Everything looks healthy!"
    if [[ "$is_image" == "true" ]]; then
      qemu-nbd --disconnect "$nbd" 2>/dev/null || true
      local tmp_nbds=() x
      for x in "${USED_NBDS[@]}"; do
        [[ "$x" == "$nbd" ]] && continue
        tmp_nbds+=("$x")
      done
      USED_NBDS=("${tmp_nbds[@]}")
    fi
    pause
    return
  fi

  hr
  echo "🔧 Issues Found: $issues_found"
  hr
  for i in "${!issue_list[@]}"; do
    echo "  [$((i+1))] ${issue_list[$i]}"
  done
  echo

  local fix_ans
  fix_ans="$(ask_yesno "🔧 Fix all detected issues?" "Y")"
  if [[ "$fix_ans" != "true" ]]; then
    log "Repair cancelled by user."
    if [[ "$is_image" == "true" ]]; then
      qemu-nbd --disconnect "$nbd" 2>/dev/null || true
      local tmp_nbds=() x
      for x in "${USED_NBDS[@]}"; do
        [[ "$x" == "$nbd" ]] && continue
        tmp_nbds+=("$x")
      done
      USED_NBDS=("${tmp_nbds[@]}")
    fi
    pause
    return
  fi

  # ── Step 6: Apply fixes ──
  echo
  log "Applying fixes…"
  local fix_success=0 fix_fail=0

  for i in "${!fix_commands[@]}"; do
    echo
    log "Fix $((i+1))/${#fix_commands[@]}: ${issue_list[$i]}"
    if eval "${fix_commands[$i]}" 2>&1; then
      success "Fix applied successfully."
      fix_success=$((fix_success + 1))
    else
      err "Fix failed: ${fix_commands[$i]}"
      fix_fail=$((fix_fail + 1))
    fi
  done

  # ── Step 7: Post-repair verification ──
  echo
  log "🔍 Running post-repair verification…"
  echo

  for i in "${!parts[@]}"; do
    local part="${parts[$i]}"
    local fstype
    fstype="$(lsblk -no FSTYPE "$part" 2>/dev/null | head -n1)"

    case "$fstype" in
      ext4|ext3|ext2)
        local verify_output
        verify_output="$(e2fsck -n -f "$part" 2>&1)" || true
        if echo "$verify_output" | grep -qi "error\|corrupt"; then
          echo -e "   ${RED}❌ $part still has issues${NC}"
        else
          echo -e "   ${GREEN}✅ $part is clean${NC}"
        fi
        ;;
      ntfs)
        echo -e "   ${GREEN}✅ $part (NTFS repair applied)${NC}"
        ;;
    esac
  done

  # ── Step 8: Cleanup ──
  if [[ "$is_image" == "true" ]]; then
    qemu-nbd --disconnect "$nbd" 2>/dev/null || true
    local tmp_nbds=() x
    for x in "${USED_NBDS[@]}"; do
      [[ "$x" == "$nbd" ]] && continue
      tmp_nbds+=("$x")
    done
    USED_NBDS=("${tmp_nbds[@]}")

    # Verify image after repair
    verify_image "$img" || warn "Image may still have issues."
  fi

  # ── Step 9: Summary ──
  echo
  hr
  echo "📊 Repair Summary"
  hr
  echo "   Issues found:    $issues_found"
  echo -e "   Fixes applied:   ${GREEN}$fix_success succeeded${NC}"
  if ((fix_fail > 0)); then
    echo -e "   Fixes failed:    ${RED}$fix_fail failed${NC}"
  fi
  hr

  _write_log "REPAIR" "Target: ${img:-$target_disk} | Issues: $issues_found | Fixed: $fix_success | Failed: $fix_fail"

  success "Repair complete!"
  pause
}

# ── Helper: Repair a single partition directly ──
_repair_single_partition() {
  local part="$1"
  local fstype
  fstype="$(lsblk -no FSTYPE "$part" 2>/dev/null | head -n1)"

  echo
  log "Repairing partition: $part (filesystem: $fstype)"

  case "$fstype" in
    ext4|ext3|ext2)
      local fs_block_size fs_blocks part_size_bytes part_blocks
      fs_block_size="$(dumpe2fs -h "$part" 2>/dev/null | grep "Block size" | awk '{print $3}')" || true
      fs_blocks="$(dumpe2fs -h "$part" 2>/dev/null | grep "Block count" | awk '{print $3}')" || true
      fs_block_size="${fs_block_size:-4096}"
      part_size_bytes="$(blockdev --getsize64 "$part" 2>/dev/null || echo 0)"
      part_blocks=$((part_size_bytes / fs_block_size))

      echo "   Filesystem blocks: ${fs_blocks:-unknown}"
      echo "   Partition blocks:  $part_blocks"

      # Fix size mismatch
      if [[ -n "$fs_blocks" ]] && ((fs_blocks > part_blocks)); then
        warn "Filesystem larger than partition. Shrinking filesystem…"
        resize2fs -f "$part" "$part_blocks" || { err "Shrink failed."; return; }
        success "Filesystem shrunk to match partition."
      elif [[ -n "$fs_blocks" ]] && ((fs_blocks < part_blocks - 1024)); then
        log "Filesystem smaller than partition. Expanding…"
        resize2fs "$part" || { err "Expand failed."; return; }
        success "Filesystem expanded to fill partition."
      fi

      # Fix corruption
      log "Running e2fsck…"
      e2fsck -f -y "$part" 2>&1 || true
      success "Filesystem check complete."
      ;;
    ntfs)
      log "Running ntfsfix…"
      ntfsfix "$part" 2>&1 || { err "ntfsfix failed."; return; }
      success "NTFS fix complete."
      ;;
    *)
      warn "Filesystem '$fstype' is not supported for repair."
      ;;
  esac
}

show_help() {
  hr
  echo "🧰 QEMU Disk Tool — Help"
  hr
  echo
  echo "  [1] 🔍 Scan disks/partitions"
  echo "      List all physical disks and partitions with details."
  echo
  echo "  [2] 🧱 Create NEW blank VM disk image"
  echo "      Create an empty qcow2/raw/vmdk/vhdx/vhd file."
  echo
  echo "  [3] 🧊 Create image from real disk/partition"
  echo "      Clone a physical disk or partition into an image file."
  echo "      ⚠️  Partition images are NOT bootable."
  echo
  echo "  [4] 🔁 Convert image format"
  echo "      Convert between qcow2, raw, vmdk, vhdx, vhd."
  echo
  echo "  [5] 🔎 Explore/Mount an image (read-only)"
  echo "      Mount an image to browse files."
  echo
  echo "  [6] 🧨 Write image to disk/partition (restore)"
  echo "      Restore an image file back to a physical disk/partition."
  echo "      ⚠️  DESTRUCTIVE."
  echo
  echo "  [7] ℹ️  Show image info"
  echo "      Display detailed image information."
  echo
  echo "  [8] 🗑️  Delete an image file"
  echo "      Safely delete an image file."
  echo
  echo "  [9] 📀 Direct Clone"
  echo "      Clone disk/partition directly to another disk/partition."
  echo "      ⚠️  DESTRUCTIVE."
  echo
  echo "  [10] 🚀 Smart OS Migration"
  echo "      Create a bootable VM from a physical Linux drive."
  echo "      Auto-detects root/boot/EFI, installs GRUB."
  echo
  echo "  [11] 📦 Smart Data-Level Copy"
  echo "      Copy ONLY used blocks using partclone."
  echo "      Creates smaller images than block-level copies."
  echo
  echo "  [12] 📏 Resize/Shrink Image"
  echo "      Shrink filesystems/partitions to fit smaller drives."
  echo "      Supports ext2/3/4 and NTFS."
  echo
  echo "  [13] 🏥 Disk Health Check"
  echo "      SMART analysis and bad sector scanning."
  echo "      Recommended before cloning old drives."
  echo
  echo "  [14] 🔄 MBR/GPT Conversion"
  echo "      Convert partition tables between MBR and GPT."
  echo "      ⚠️  Backup data first."
  echo
  echo "  [15] 🔧 Repair Image / Disk / Partition"
  echo "      Diagnose and fix filesystem corruption, size mismatches,"
  echo "      partition table issues, and image errors."
  echo
  echo "  [16] ❓ Help"
  echo "      Show this help message."
  echo
  echo "  [17] 🚪 Exit"
  echo "      Quit the tool."
  echo
  hr
}

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
      16) show_help; pause ;;
      17) log "Bye 👋"; exit 0 ;;
      *) warn "Pick 1-17."; pause ;;
    esac
  done
}

# --------- Start ---------
need_root "$@"
preflight_check
main_menu
