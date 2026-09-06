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

  if [[ -d /sys/module/nbd ]]; then
    if [[ "${NBD_LOADED_BY_US:-0}" -eq 1 ]]; then
      echo "  ✅ nbd module loaded by this script."
    else
      echo "  ✅ nbd module already loaded (not by us)."
      NBD_LOADED_BY_US=0
    fi
  else
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

  source /etc/os-release 2>/dev/null || true
  local dist="${ID:-unknown}"

  if [[ "$dist" != "ubuntu" && "$dist" != "debian" ]]; then
    echo "🟨 Auto-install supported on Ubuntu/Debian only. Detected: $dist"
  fi

  local required=(qemu-img qemu-nbd lsblk findmnt mount umount mountpoint partprobe dd truncate modprobe udevadm blockdev numfmt script rsync sgdisk ntfs-3g smartctl resize2fs partclone.ext4 partclone.ntfs)
  local optional=(pv zenity ms-sys)

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

  offer_optional_install() {
    ((${#missing_optional[@]} > 0)) || return 0
    [[ "$dist" == "ubuntu" || "$dist" == "debian" ]] || return 0

    echo
    echo "🟨 Missing optional tools:"
    for c in "${missing_optional[@]}"; do
      case "$c" in
        pv)     echo "     • pv      → Faster progress bars for raw copies" ;;
        zenity) echo "     • zenity  → GUI file/folder pickers (needs graphical display)" ;;
        ms-sys) echo "     • ms-sys  → Windows MBR/PBR boot repair (compiled from source)" ;;
        *)      echo "     • $c" ;;
      esac
    done
    echo
    read -rp "🛠️  Install missing optional tools now? (y/N): " ans <"$TTY"
    if [[ "${ans,,}" == "y" ]]; then
      local opt_pkgs=()
      local install_ms_sys=false
      for c in "${missing_optional[@]}"; do
        case "$c" in
          pv)     opt_pkgs+=("pv") ;;
          zenity) opt_pkgs+=("zenity") ;;
          ms-sys) install_ms_sys=true ;;
          *)      opt_pkgs+=("$c") ;;
        esac
      done
      
      if ((${#opt_pkgs[@]} > 0)); then
        echo "📦 Installing optional packages: ${opt_pkgs[*]}"
        apt-get install -y "${opt_pkgs[@]}" || warn "Some optional packages failed to install."
      fi
      
      if [[ "$install_ms_sys" == "true" ]]; then
        echo "📦 Installing ms-sys from source (not in Ubuntu 24.04+ repos)…"
        if ! command -v gcc >/dev/null 2>&1 || ! command -v make >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
          echo "   Installing build tools…"
          apt-get install -y build-essential unzip wget >/dev/null 2>&1 || true
        fi
        
        local tmp_dir cwd_save
        tmp_dir="$(mktemp -d)"
        cwd_save="$PWD"
        
        if cd "$tmp_dir" && wget -q -O ms-sys.zip "https://github.com/pbatard/ms-sys/archive/refs/heads/master.zip"; then
          unzip -q ms-sys.zip
          if cd ms-sys-master 2>/dev/null; then
            echo "   Compiling ms-sys (this takes a few seconds)…"
            make >/dev/null 2>&1 || true
            if [[ -f "bin/ms-sys" ]]; then
              cp bin/ms-sys /usr/local/bin/ms-sys 2>/dev/null || true
              if command -v ms-sys >/dev/null 2>&1; then
                success "ms-sys installed successfully."
              else
                warn "Compiled but could not copy ms-sys."
              fi
            else
              warn "Compilation of ms-sys failed."
            fi
          fi
        else
          warn "Failed to download ms-sys source."
        fi
        
        cd "$cwd_save" >/dev/null 2>&1 || true
        rm -rf "$tmp_dir"
      fi
    else
      log "Skipping optional tools. Some features will use terminal fallback."
    fi
  }

  if ((${#missing[@]} == 0)); then
    echo
    echo "🟩 Preflight: OK — all required tools are installed."
    hr
    offer_optional_install
    return 0
  fi

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
        ms-sys)                          pkgs+=("ms-sys") ;;
        *)                              pkgs+=("$c") ;;
      esac
    done

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

have(){ command -v "$1" >/dev/null 2>&1; }
ver(){
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

# ============================================================
# GLOBAL PROGRESS BAR ENGINE — Polished Monochrome Dashboard
# ============================================================

_pb_sectors_written() {            # $1=/dev/xxx → stat field 7
  local name="${1#/dev/}" f="" d
  if [[ -r "/sys/block/$name/stat" ]]; then f="/sys/block/$name/stat"
  else
    for d in /sys/block/*; do [[ -r "$d/$name/stat" ]] && { f="$d/$name/stat"; break; }; done
  fi
  [[ -n "$f" ]] || return 1
  local s
  read -r _ _ _ _ _ _ s _ < "$f" || return 1
  [[ "$s" =~ ^[0-9]+$ ]] || return 1
  echo "$s"
}

_pb_now_ms() {                     # fork-free clock via /proc/uptime
  local u s c
  if read -r u _ < /proc/uptime 2>/dev/null && [[ "$u" == *.* ]]; then
    s=${u%.*}; c=${u#*.}; c=${c:0:2}
    echo $(( 10#$s * 1000 + 10#$c * 10 ))
  else
    echo $(( $(date +%s%N) / 1000000 ))
  fi
}

_pb_human() {                      # $1 bytes → $PB_H (no forks)
  local b=$1
  if   (( b >= 1073741824 )); then printf -v PB_H '%d.%dGiB' $(( b/1073741824 )) $(( (b%1073741824)*10/1073741824 ))
  elif (( b >= 1048576 ));    then printf -v PB_H '%d.%dMiB' $(( b/1048576 ))    $(( (b%1048576)*10/1048576 ))
  elif (( b >= 1024 ));       then printf -v PB_H '%d.%dKiB' $(( b/1024 ))       $(( (b%1024)*10/1024 ))
  else printf -v PB_H '%dB' "$b"; fi
}

_pb_hms() {                        # $1 seconds → $PB_T (no forks)
  printf -v PB_T '%02d:%02d:%02d' $(( $1/3600 )) $(( ($1%3600)/60 )) $(( $1%60 ))
}

run_with_progress_bar() {
  local description="$1"; shift
  local total=0
  [[ "${1:-}" =~ ^[0-9]+$ ]] && { total="$1"; shift; }
  local cmd=("$@")

  local plog="/tmp/progress_$$.log"; : > "$plog"
  log "$description"; echo

  # ── geometry: auto-fit terminal (capped at 100 cells) ──
  local cols="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  local bar_width=$(( (cols - 14) / 2 ))         # 2-char cells + "  [ XX% ] " prefix + "▌"
  (( bar_width >= 20 )) || bar_width=20
  (( bar_width > 100 )) && bar_width=100
  local DIM=$'\033[90m' WHT=$'\033[97m' BLD=$'\033[1;97m' RST=$'\033[0m'

  # ── progress source ──
  local tot="${PB_TOTAL:-$total}"
  [[ "$tot" =~ ^[0-9]+$ ]] || tot=0
  local have_dev=0 s0=0
  if [[ -n "${PB_DEV:-}" && -b "${PB_DEV}" && "$tot" -gt 0 ]]; then
    s0="$(_pb_sectors_written "$PB_DEV" 2>/dev/null || echo X)"
    [[ "$s0" =~ ^[0-9]+$ ]] && have_dev=1
  fi

  # ── header: centered action sentence with breathing room ──
  local emo="${PB_EMOJI:-}"
  local action
  case "$description" in
    *Writ*|*estor*) emo="${emo:-📥}"; action="Writing" ;;
    *Convert*)      emo="${emo:-🔁}"; action="Converting" ;;
    *Clon*)         emo="${emo:-📀}"; action="Cloning" ;;
    *Cop*|*igrat*)  emo="${emo:-📦}"; action="Copying" ;;
    *)              emo="${emo:-🧰}"; action="Processing" ;;
  esac
  local hdr="${PB_HEADER:-$description}" src="" dst=""
  if [[ "$hdr" == *" → "* ]]; then src="${hdr%% → *}"; dst="${hdr##* → }"; else src="$hdr"; fi
  local maxw=$(( (cols - 18) / 2 )); (( maxw < 10 )) && maxw=10
  (( ${#src} > maxw )) && src="…${src: -maxw}"
  (( ${#dst} > maxw )) && dst="${dst:0:maxw}…"
  
  local vis_len=$(( ${#action} + ${#src} + ${#dst} + 8 ))
  local pad_left=$(( (cols - vis_len) / 2 )); (( pad_left < 1 )) && pad_left=1
  local pad_spaces=""; for ((i=0; i<pad_left; i++)); do pad_spaces+=" "; done

  echo
  if [[ -n "$dst" ]]; then
    printf '%s%s %s%s%s %s%s%s  %s→%s  %s%s%s\n' "$pad_spaces" "$emo" "$BLD" "$action" "$RST" "$WHT" "$src" "$RST" "$DIM" "$RST" "$WHT" "$dst" "$RST"
  else
    printf '%s%s %s%s%s %s%s%s\n' "$pad_spaces" "$emo" "$BLD" "$action" "$RST" "$WHT" "$src" "$RST"
  fi
  echo

  "${cmd[@]}" </dev/null >"$plog" 2>&1 &
  local pid=$!

  local t0 now_ms prev_ms=0
  t0="$(_pb_now_ms)"
  local ms_prev=$t0 bytes_prev=0 speed=0
  local last_p=0 last_t=$t0 rate=0
  local eta_base=-1 eta_at=0 eta_rev=0 eta_cd=0
  local -a FR=("" "▏" "▎" "▍" "▌" "▋" "▊" "▉")
  local now ms written=0 pct=0 chunk content

  while kill -0 "$pid" 2>/dev/null; do
    now="$(_pb_now_ms)"; ms=$(( now - t0 ))
    
    # Monotonic time guard
    (( ms < prev_ms )) && ms=$prev_ms
    prev_ms=$ms

    if (( have_dev )); then
      local s; s="$(_pb_sectors_written "$PB_DEV" 2>/dev/null || echo "$s0")"
      [[ "$s" =~ ^[0-9]+$ ]] || s=$s0
      written=$(( (s - s0) * 512 )); (( written < 0 )) && written=0
      pct=$(( written * 10000 / tot ))
    else
      content="$(<"$plog")" 2>/dev/null || content=""
      chunk="${content: -400}"
      chunk="${chunk//$'\r'/$'\n'}"
      local np="" bytes_now=-1 p100=-1
      if   [[ "$chunk" =~ .*\(([0-9]+(\.[0-9]+)?)/100%\) ]]; then np="${BASH_REMATCH[1]}"
      elif [[ "$tot" -gt 0 && "$chunk" =~ ([0-9]+)[[:space:]]bytes.*copied ]]; then bytes_now=${BASH_REMATCH[1]}
      elif [[ "$chunk" =~ ([0-9]+(\.[0-9]+)?)% ]]; then np="${BASH_REMATCH[1]}"
      fi
      if (( bytes_now >= 0 )); then
        p100=$(( bytes_now * 10000 / tot ))
      elif [[ -n "$np" ]]; then
        if [[ "$np" == *.* ]]; then
          local ip=${np%%.*} fp=${np#*.}; fp=${fp:0:2}
          (( ${#fp} == 1 )) && fp+=0
          p100=$(( 10#$ip * 100 + 10#$fp ))
        else
          p100=$(( 10#$np * 100 ))
        fi
      fi
      if (( p100 > last_p )); then
        rate=$(( (p100 - last_p) * 1000 / (now - last_t + 1) ))
        last_p=$p100; last_t=$now
      fi
      (( now - last_t > 5000 )) && rate=0
      pct=$(( last_p + rate * (now - last_t) / 1000 ))
      (( pct > last_p + 200 )) && pct=$(( last_p + 200 ))
      (( tot > 0 )) && written=$(( tot * pct / 10000 ))
    fi
    (( pct < 0 )) && pct=0
    (( pct > 9999 )) && pct=9999

    # ── speed EMA (unclamped) ──
    local dms=$(( now - ms_prev ))
    if (( dms >= 200 )); then
      local db=$(( written - bytes_prev )); (( db < 0 )) && db=0
      local inst=$(( db * 1000 / dms ))
      speed=$(( (speed*7 + inst*3) / 10 ))
      ms_prev=$now; bytes_prev=$written
    fi

    # ── draw (gapped cells) ──
    local eighths=$(( pct * bar_width * 8 / 10000 ))
    local full=$(( eighths / 8 )) rem=$(( eighths % 8 ))
    local fill="" empty="" i
    for ((i=0; i<full; i++)); do fill+="█ "; done
    if (( rem > 0 )); then fill+="${FR[$rem]} "; fi
    local used=$(( full + (rem > 0) ))
    for ((i=used; i<bar_width; i++)); do empty+="─ "; done

    # ── time logic (countdown ETA) ──
    local elapsed_s=$(( ms / 1000 ))
    if (( eta_base < 0 )); then
      if (( written > 0 )); then
        local avg0=$(( written * 1000 / (ms + 1) ))
        if (( avg0 > 0 )); then
          eta_base=$(( (tot - written) / avg0 ))
          eta_at=$elapsed_s
          eta_rev=$elapsed_s
          eta_cd=$eta_base
        fi
      fi
    else
      eta_cd=$(( eta_base - (elapsed_s - eta_at) ))
      if (( elapsed_s - eta_rev >= 5 && written > 0 )); then
        eta_rev=$elapsed_s
        local avg=$(( written * 1000 / ms ))
        if (( avg > 0 )); then
          local est=$(( (tot - written) / avg ))
          if (( est < eta_cd )); then
            local drop=$(( eta_cd - est )); (( drop > 30 )) && drop=30
            eta_base=$(( est + drop )); eta_at=$elapsed_s
          elif (( est > eta_cd + eta_cd / 10 )); then
            eta_base=$(( eta_cd + eta_cd / 10 )); eta_at=$elapsed_s
          fi
        fi
      fi
    fi
    (( eta_cd < 0 )) && eta_cd=0

    local pctstr; printf -v pctstr '%d.%02d' $((pct/100)) $((pct%100))
    _pb_human "$speed";   local spd_s="$PB_H"
    _pb_human "$written"; local wr_s="$PB_H"
    _pb_human "$tot";     local tot_s="$PB_H"
    _pb_hms "$elapsed_s"; local el_s="$PB_T"
    _pb_hms "$eta_cd";    local et_s="$PB_T"

    local pct_fmt; printf -v pct_fmt '%3d%%' $((pct/100))
    local l1="  ${DIM}[${RST} ${BLD}${pct_fmt}${RST} ${DIM}]${RST} ${WHT}${fill}${DIM}${empty}▌${RST}"
    local stats="${pctstr}% · ${spd_s}/s · ${wr_s}/${tot_s} · ⏱ ${el_s} · ETA ${et_s}"
    local l2="${BLD}${pctstr}%${RST} ${DIM}·${RST} ${spd_s}/s ${DIM}·${RST} ${wr_s}/${tot_s} ${DIM}·${RST} ⏱ ${el_s} ${DIM}·${RST} ETA ${et_s}"
    local pad=$(( (2 * bar_width + 12) - ${#stats} )); (( pad < 0 )) && pad=0
    printf '\r\033[K%s\n\033[K%*s%s\033[A' "$l1" "$pad" "" "$l2"
    sleep 0.2
  done

  local rc=0; wait "$pid" || rc=$?
  now_ms="$(_pb_now_ms)"
  local elapsed_s=$(( (now_ms - t0) / 1000 ))
  (( elapsed_s < prev_ms / 1000 )) && elapsed_s=$(( prev_ms / 1000 ))
  
  local fill="" i; for ((i=0; i<bar_width; i++)); do fill+="█ "; done
  _pb_human "$tot"; local tot_s="$PB_H"
  _pb_hms "$elapsed_s"; local el_s="$PB_T"

  # Re-declare colors for final status safety
  local DIM=$'\033[90m' WHT=$'\033[97m' BLD=$'\033[1;97m' RST=$'\033[0m'

  if (( rc == 130 )); then
    printf '\r\033[K  %sCancelled after %s%s\n' "$DIM" "$el_s" "$RST"
  elif (( rc == 0 )); then
    _pb_human "$speed"; local spd_s="$PB_H"
    local stats="100.00% · ${spd_s}/s · ${tot_s}/${tot_s} · ⏱ ${el_s} · ETA 00:00:00"
    local l2="${BLD}100.00%${RST} ${DIM}·${RST} ${spd_s}/s ${DIM}·${RST} ${tot_s}/${tot_s} ${DIM}·${RST} ⏱ ${el_s} ${DIM}·${RST} ETA 00:00:00"
    local pad=$(( (2 * bar_width + 12) - ${#stats} )); (( pad < 0 )) && pad=0
    printf '\r\033[K  %s[%s 100%%%s %s]%s %s%s%s%s▌%s\n\033[K%*s%s\n' \
      "$DIM" "$RST" "$BLD" "$RST" "$DIM" "$RST" "$WHT" "$fill" "$DIM" "$RST" "$pad" "" "$l2"
  else
    printf '\r\033[K  %sFAILED%s (exit %d) after %s\n' "$BLD" "$RST" "$rc" "$el_s"
  fi
  rm -f "$plog"
  return $rc
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
  local img="$1"
  qemu-img info "$img" 2>/dev/null | sed -n 's/.*(\([0-9]\+\) bytes).*/\1/p' | head -n1
}

get_total_bytes() {
  local src="$1"
  if [[ -b "$src" ]]; then
    lsblk -bno SIZE "$src" 2>/dev/null | head -n1
    return 0
  fi
  qemu-img info "$src" 2>/dev/null |
    awk -F'[()]' '/^virtual size:/ {gsub(/[^0-9]/,"",$2); print $2; exit}'
}

# Legacy pty progress bar (kept for compatibility with un-updated options)
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

  stdbuf -o0 tr '\r' '\n' | while IFS= read -r line; do
    if [[ "$line" =~ \(([0-9]+([.][0-9]+)?)\/100%\) ]]; then
      pct="${BASH_REMATCH[1]}"
      pct_int="$(awk -v p="$pct" 'BEGIN{printf "%d", (p<0?0:(p>100?100:p))+0.5}')"
      (( pct_int == 0 )) && pct_int=1
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
  printf "\r\033[K"
}

run_with_spinner() {
  local msg="$1"
  shift
  "$@" &
  local pid=$!
  spinner "$pid" "$msg"
  wait "$pid"
}

qemu_img_convert_with_tty_progress() {
  local total="$1"
  local label="$2"
  shift 2

  if [[ ! "$total" =~ ^[0-9]+$ ]] || (( total <= 0 )); then
    "$@"
    return $?
  fi

  local cmd_str
  cmd_str="$(printf '%q ' "$@")"

  set +e
  script -q -f -e -c "$cmd_str" /dev/null 2>&1 \
    | qemu_img_progress_bar "$total" "$label"

  local rc="${PIPESTATUS[0]}"
  set -e

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
    lsblk -nrpo NAME,TYPE,SIZE,MODEL,SERIAL,MOUNTPOINTS | sed 's/\\x20/ /g' |
      awk -v w="$want" '
        $2==w {
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

  echo "${lines[$((sel-1))]}" | awk '{print $1}'
}

is_mounted() {
  local dev="$1"
  findmnt -rn --source "$dev" >/dev/null 2>&1
}

maybe_unmount() {
  local dev="$1"

  local targets=""
  targets="$(findmnt -rn -o TARGET -S "$dev" 2>/dev/null || true)"

  if [[ "$(lsblk -no TYPE "$dev" 2>/dev/null || true)" == "disk" ]]; then
    while IFS= read -r p; do
      targets+=$'\n'"$(findmnt -rn -o TARGET -S "$p" 2>/dev/null || true)"
    done < <(lsblk -nrpo NAME "$dev" 2>/dev/null | tail -n +2)
  fi

  targets="$(echo "$targets" | awk 'NF')"

  if [[ -n "$targets" ]]; then
    warn "Mounted target (or its partitions): $dev"
    while IFS= read -r line; do
      [[ -n "$line" ]] && echo "  📌 $line" >&2
    done <<< "$targets"
    read -rp "🧨 Unmount ALL related mounts now? (y/N): " ans <"$TTY"

    if [[ "${ans,,}" == "y" ]]; then
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

is_qemu_image() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  qemu-img info "$f" >/dev/null 2>&1
}

detect_disk_info() {
  local dev="$1"
  [[ -b "$dev" ]] || return 1

  echo "🔍 Analyzing: $dev" >&2

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

  local parts
  parts="$(lsblk -nrpo NAME,SIZE,FSTYPE,PARTTYPENAME "$dev" 2>/dev/null | tail -n +2)"
  if [[ -n "$parts" ]]; then
    echo "   📦 Partitions:" >&2
    while IFS= read -r line; do
      echo "      $line" >&2
    done <<< "$parts"

    if echo "$parts" | grep -qi "vfat"; then
      echo "   🔎 UEFI hint: FAT partition detected (possible EFI System Partition)" >&2
    fi
  fi
  echo >&2
}

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

  local supported_re='^(qcow2|raw|vmdk|vhdx|vpc)$'
  local ext_re='\.([Qq][Cc][Oo][Ww]2|[Rr][Aa][Ww]|[Ii][Mm][Gg]|[Vv][Mm][Dd][Kk]|[Vv][Hh][Dd][Xx]|[Vv][Hh][Dd])$'

  local files=() fmts=() vsizes=()

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

  if has_gui; then
    p="$(gui_pick_file "Select a disk image" "*.qcow2 *.img *.raw *.vmdk *.vhdx *.vhd")"
    if [[ -z "$p" ]]; then
      warn "GUI cancelled. Falling back to terminal input."
    elif [[ -f "$p" ]] && is_qemu_image "$p"; then
      printf "%s\n" "$p"
      return
    fi
  fi

  while true; do
    read -rp "$prompt" p <"$TTY"
    [[ -n "$p" ]] || { echo "🟨 Empty path not allowed." >&2; continue; }

    if [[ -d "$p" ]]; then
      pick_image_from_dir "$p"
      return
    fi

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
  qemu-img info "$img" 2>/dev/null | awk -F': ' '/file format:/ {print $2; exit}'
}

ask_compression_opts() {
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
    echo
    echo "🧩 Choose output format:"
    echo
    echo "  [1] qcow2   ⭐ Best for QEMU/KVM — snapshots, compression, thin-provisioning"
    echo "  [2] raw     ⚡ Maximum I/O performance — no metadata overhead (.img)"
    echo "  [3] vmdk    🟦 VMware — ESXi / Workstation / VirtualBox"
    echo "  [4] vhdx    🟩 Hyper-V — modern Windows format, up to 64 TB"
    echo "  [5] vhd     🟨 Legacy Microsoft (vpc) — required for Azure"
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
      5) printf "vpc\n";   return;;
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
  local in_fmt="$1"
  local src="$2"
  local out_fmt="$3"
  local dst="$4"
  shift 4
  local extra_opts=("$@")

  local cmd=(qemu-img convert -p -f "$in_fmt" -O "$out_fmt")
  if ((${#extra_opts[@]} > 0)); then
    cmd+=("${extra_opts[@]}")
  fi
  cmd+=("$src" "$dst")

  run_with_progress_bar "Converting $src → $dst" "${cmd[@]}"
}

pick_free_nbd() {
  check_nbd_module >&2 || exit 1

  udevadm settle 2>/dev/null || true

  local dev idx size

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
      local info
      info="$(lsblk -no SIZE,FSTYPE,MOUNTPOINTS "${parts[$i]}" 2>/dev/null | sed 's/[[:space:]]\+/ /g')"
      printf "  [%d] %s  (%s)\n" "$((i+1))" "${parts[$i]}" "${info:-?}"
    done
  } >&2

  local sel
  while true; do
    read -rp "➡️  Pick partition (1-${#parts[@]}) or type full path: " sel <"$TTY"

    if [[ "$sel" =~ ^[0-9]+$ ]]; then
      (( sel>=1 && sel<=${#parts[@]} )) || { echo "🟨 Out of range." >&2; continue; }
      printf "%s\n" "${parts[$((sel-1))]}"
      return 0
    fi

    if [[ -b "$sel" ]]; then
      printf "%s\n" "$sel"
      return 0
    fi

    echo "🟨 Invalid input. Use a number or a /dev/... path." >&2
  done
}

global_cleanup() {
  set +e

  for d in "${USED_NBDS[@]}"; do
    [[ "$d" =~ ^/dev/nbd[0-9]+$ ]] || continue

    local idx sz
    idx="${d#/dev/nbd}"
    sz="$(cat "/sys/block/nbd${idx}/size" 2>/dev/null || echo 0)"

    [[ "${sz:-0}" != "0" ]] || continue
    qemu-nbd --disconnect "$d" >/dev/null 2>&1 || true
  done

  USED_NBDS=()

  sleep 0.5

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

  if [[ "$any_in_use" -eq 0 ]]; then
    modprobe -r nbd 2>/dev/null || true
    NBD_LOADED_BY_US=0
  fi
}

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