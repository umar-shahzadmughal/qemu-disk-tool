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
DEFAULT_OUT_DIR="/"
NBD_MAX=16
USED_NBDS=()

check_nbd_module() {
  echo
  echo "🧩 Kernel module check: nbd"

  command -v modprobe >/dev/null 2>&1 || {
    echo "  ❌ modprobe not found (install kmod)."
    return 1
  }

  # Try to load with sensible defaults (won't change params if already loaded)
  modprobe nbd max_part=16 nbds_max="${NBD_MAX:-16}" 2>/dev/null || \
  modprobe nbd max_part=16 2>/dev/null || true

  [[ -d /sys/module/nbd ]] || {
    echo "  ❌ nbd module is not loaded and could not be loaded."
    return 1
  }

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

  # Root is enforced by need_root() before preflight_check is called

  # Detect distro (we'll support Debian/Ubuntu only for auto-install)
  source /etc/os-release 2>/dev/null || true
  local dist="${ID:-unknown}"

  if [[ "$dist" != "ubuntu" && "$dist" != "debian" ]]; then
    echo "🟨 Auto-install supported on Ubuntu/Debian only. Detected: $dist"
  fi

  # Required and optional tools
  # required: core tool paths used in your menus
  local required=(qemu-img qemu-nbd lsblk findmnt mount umount mountpoint partprobe dd truncate modprobe udevadm blockdev numfmt script)
  # optional: used for nicer UX / NTFS / GPT fixes / progress
  local optional=(pv sgdisk ntfs-3g)

  echo "🔎 Checking required tools…"
  local missing=()
  for c in "${required[@]}"; do
    if have "$c"; then
      printf "  ✅ %-10s %s\n" "$c" "$(ver "$c")"
    else
      printf "  ❌ %-10s missing\n" "$c"
      missing+=("$c")
    fi
  done

  echo
  echo "🧩 Checking optional tools…"
  for c in "${optional[@]}"; do
    if have "$c"; then
      printf "  ✅ %-10s %s\n" "$c" "$(ver "$c")"
    else
      printf "  ⚠️  %-10s missing (optional)\n" "$c"
    fi
  done

  # If nothing missing, done
  if ((${#missing[@]} == 0)); then
      check_nbd_module >&2 || exit 1
      echo
      echo "🟩 Preflight: OK — all required tools are installed."
      hr
      return 0
    fi

# Auto-install on Ubuntu/Debian
  if [[ "$dist" == "ubuntu" || "$dist" == "debian" ]]; then
    echo
    echo "🟨 Missing required tools. Auto-install will run now…"

    local pkgs=()
    for c in "${missing[@]}"; do
      case "$c" in
        qemu-img|qemu-nbd)         pkgs+=("qemu-utils") ;;
        partprobe)                pkgs+=("parted") ;;
        lsblk|findmnt|mount|umount|mountpoint|losetup)
                                  pkgs+=("util-linux") ;;
        dd|truncate)              pkgs+=("coreutils") ;;
        modprobe|modinfo)         pkgs+=("kmod") ;;
        udevadm)                  pkgs+=("udev") ;;
        *)                        pkgs+=("$c") ;;
      esac
    done

    pkgs+=("pv" "gdisk" "ntfs-3g")

    local uniq_pkgs=()
    local seen=" "
    for p in "${pkgs[@]}"; do
      [[ "$seen" == *" $p "* ]] || { uniq_pkgs+=("$p"); seen+=" $p "; }
    done

    echo "📦 Installing packages: ${uniq_pkgs[*]}"
    read -rp "🛠️  Install missing tools now? (y/N): " ans <"$TTY"
    [[ "${ans,,}" == "y" ]] || { echo "🟥 Install cancelled." >&2; exit 1; }

    apt-get update
    apt-get install -y "${uniq_pkgs[@]}"

    echo
    echo "🔁 Re-check after install…"
    for c in "${required[@]}"; do
      if have "$c"; then
        printf "  ✅ %-10s %s\n" "$c" "$(ver "$c")"
      else
        printf "  ❌ %-10s still missing\n" "$c"
        echo "🟥 Preflight failed. Something didn’t install correctly."
        exit 1
      fi
    done

    check_nbd_module || exit 1

    echo
    echo "🟩 Preflight: OK — tools installed and verified."
    hr
    return 0
  fi

  echo
  echo "🟥 Missing required tools, and auto-install isn't supported on this distro."
  echo "   Install manually then re-run."
  exit 1
}

# --------- Helpers ---------
log()  { echo "🟦 $*"; }
warn() { echo "🟨 $*"; }
err()  { echo "🟥 $*" >&2; }
die()  { err "$*"; exit 1; }

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

human_lsblk() {
  hr
  echo "🔍 Storage Inventory (disks + partitions)"
  hr
  # -e 7 = loop, -e 43 = nbd  ✅ hides nbd0/nbd1/... from inventory
  lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL -e 7,43 || true
  hr
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

  [[ "$rc" -eq 0 ]] || die "$label failed (rc=$rc)"
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
      N|NO)  echo "false"; return 1 ;;
      *) echo "🟨 Type y or n." >&2 ;;
    esac
  done
}

run_convert() {
  # args: src_fmt src dst_fmt dst extra_opts...
  local src_fmt="$1" src="$2" dst_fmt="$3" dst="$4"
  shift 4
  local extra=("$@")

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

  if [[ -t 2 && "$total" =~ ^[0-9]+$ && "$total" -gt 0 ]]; then
    qemu_img_convert_with_tty_progress "$total" "Converting" \
      qemu-img convert -p -f "$src_fmt" -O "$dst_fmt" "${extra[@]}" "$src" "$dst"
  else
    qemu-img convert -p -f "$src_fmt" -O "$dst_fmt" "${extra[@]}" "$src" "$dst"
  fi
  hr
  log "Done ✅"
}

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

  read -rp "📏 Size (e.g., 120G, 500G, 50G): " size <"$TTY"
  [[ -n "$size" ]] || die "Size required."

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
  log "Created ✅  $fullpath"
  pause
}

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

  maybe_unmount "$src"

  local outdir fmt outfile dst compress=false
  outdir="$(suggest_out_dir)"
  read -rp "📁 Output directory [$outdir]: " tmp <"$TTY"
  outdir="${tmp:-$outdir}"
  [[ -d "$outdir" ]] || die "Directory not found: $outdir"

  fmt="$(ask_format_out)"

  read -rp "📝 Output file name (no spaces, include extension) [backup.${fmt/vpc/vhd}]: " outfile <"$TTY"
  if [[ -z "$outfile" ]]; then
    outfile="backup.${fmt/vpc/vhd}"
  fi
  dst="$outdir/$outfile"

  if [[ "$fmt" == "qcow2" ]]; then
    compress="$(ask_yesno "🗜️  Compress qcow2 output? (smaller file, slower convert)" "Y")"
  fi

  if [[ -e "$dst" ]]; then
    warn "File exists: $dst"
    ask_yesno "Overwrite it?" "N" || die "Cancelled."
    rm -f "$dst"
  fi

  local extra=()
  if [[ "$fmt" == "qcow2" && "$compress" == true ]]; then
    extra+=("-c")
  fi

  run_convert raw "$src" "$fmt" "$dst" "${extra[@]}"
  qemu-img info "$dst" || true
  pause
}

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

explore_mount_image() {
  hr
  echo "🔎 Explore / Mount an image (READ-ONLY recommended)"
  hr

  local img nbd mp part ro fstype REAL_USER MEDIA_ROOT
  local _CLEANED_UP=0   # ✅ MUST be local, or next runs will skip cleanup

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
    [[ "$_CLEANED_UP" -eq 1 ]] && return 0
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

    if [[ "$nbd" =~ ^/dev/nbd[0-9]+$ ]]; then
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
  trap - EXIT INT TERM

  log "Done ✅"
  pause
}

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

  log "Writing (image → raw → device)…"

  local total
  total="$(get_total_bytes "$img" 2>/dev/null || echo 0)"
  total="${total:-0}"

  if [[ -t 2 && "$total" =~ ^[0-9]+$ && "$total" -gt 0 ]]; then
    qemu_img_convert_with_tty_progress "$total" "Writing" \
      qemu-img convert -p -O raw "$img" "$target"
  else
    qemu-img convert -p -O raw "$img" "$target"
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

  for d in "${USED_NBDS[@]}"; do
    [[ "$d" =~ ^/dev/nbd[0-9]+$ ]] || continue

    local idx sz
    idx="${d#/dev/nbd}"
    sz="$(cat "/sys/block/nbd${idx}/size" 2>/dev/null || echo 0)"

    # Only disconnect if it still looks connected
    [[ "${sz:-0}" != "0" ]] || continue
    qemu-nbd --disconnect "$d" >/dev/null 2>&1 || true
  done
}
trap global_cleanup EXIT INT TERM

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
    echo "  [9] 🚪 Exit"
    echo

    read -rp "➡️  Enter choice (1-9): " c <"$TTY"
    case "$c" in
      1) human_lsblk; pause ;;
      2) create_blank_disk ;;
      3) create_image_from_device ;;
      4) convert_image ;;
      5) explore_mount_image ;;
      6) write_image_to_device ;;
      7) image_info ;;
      8) delete_image_file ;;
      9) log "Bye 👋"; exit 0 ;;
      *) warn "Pick 1-9."; pause ;;
    esac
  done
}

# --------- Start ---------
need_root "$@"
preflight_check
main_menu
