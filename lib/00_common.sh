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
CLEANUP_HOOKS=()    # LIFO: functions to run on exit (register_cleanup pushes)

check_nbd_module() {
  [[ "${_NBD_CHECKED:-0}" -eq 1 ]] && return 0
  echo
  echo "🧩 Kernel module check: nbd"

  command -v modprobe >/dev/null 2>&1 || {
    echo "  🚫 modprobe not found (install kmod)."
    return 1
  }

  if [[ -d /sys/module/nbd ]]; then
    if [[ "${NBD_LOADED_BY_US:-0}" -eq 1 ]]; then
      echo "  🔌 nbd module loaded by this script."
    else
      echo "  🔗 nbd module already loaded (not by us)."
      NBD_LOADED_BY_US=0
    fi
  else
    modprobe nbd max_part=16 nbds_max="${NBD_MAX:-16}" 2>/dev/null || \
    modprobe nbd max_part=16 2>/dev/null || true

    [[ -d /sys/module/nbd ]] || {
      echo "  🚫 nbd module is not loaded and could not be loaded."
      return 1
    }
    NBD_LOADED_BY_US=1
    echo "  🔌 nbd module loaded by this script."
  fi

  local mp nb
  mp="$(cat /sys/module/nbd/parameters/max_part 2>/dev/null || echo 0)"
  nb="$(cat /sys/module/nbd/parameters/nbds_max 2>/dev/null || echo "?")"

  [[ "$mp" =~ ^[0-9]+$ ]] || mp=0

  if (( mp == 0 )); then
    echo "  🚫 nbd loaded but partition support looks disabled (max_part=$mp)."
    echo "     Fix: sudo rmmod nbd && sudo modprobe nbd max_part=16"
    return 1
  fi

  if (( mp < 16 )); then
    echo "  🚫 nbd max_part too low: $mp (need >= 16)."
    echo "     Fix: sudo rmmod nbd && sudo modprobe nbd max_part=16"
    return 1
  fi

  if (( mp != 16 )); then
    echo "  🧩 nbd loaded (nbds_max=$nb) and max_part=$mp."
    echo "     That's OK (many kernels round 16 → 31)."
  else
    echo "  🔌 nbd loaded (nbds_max=$nb) and max_part=$mp."
  fi

  _NBD_CHECKED=1
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

  local required=(qemu-img qemu-nbd lsblk findmnt mount umount mountpoint partprobe dd truncate modprobe udevadm blockdev numfmt script rsync sgdisk ntfs-3g smartctl resize2fs mkfs.ext4 mkfs.vfat partclone.ext4 partclone.ntfs)
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
    local ans opt_pkgs install_ms_sys tmp_dir cwd_save

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
      opt_pkgs=()
      install_ms_sys=false
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
        resize2fs|mkfs.ext4)            pkgs+=("e2fsprogs") ;;
        mkfs.vfat)                      pkgs+=("dosfstools") ;;
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
# ALL human-facing messages go to stderr by design:
# any helper can then be safely called inside $(…) — stdout stays
# reserved exclusively for return values (paths, sizes, booleans).
log()     { echo -e "${BLUE}⚙️  $*${NC}" >&2;    _write_log "INFO"    "$*"; }
warn()    { echo -e "${YELLOW}⚠️  $*${NC}" >&2;  _write_log "WARN"    "$*"; }
err()     { echo -e "${RED}❌ $*${NC}" >&2;      _write_log "ERROR"   "$*"; }
die()     { err "$*"; exit 1; }
success() { echo -e "${GREEN}✅ $*${NC}" >&2;    _write_log "SUCCESS" "$*"; }
info()    { echo -e "${CYAN}ℹ️  $*${NC}" >&2;    _write_log "INFO"    "$*"; }
tip()     { echo -e "${CYAN}💡 Tip: $*${NC}" >&2; _write_log "INFO"    "TIP: $*"; }

have(){ command -v "$1" >/dev/null 2>&1; }
ver() {
  local out
  out="$("$1" --version 2>/dev/null | head -n1)"
  [[ -n "$out" ]] && { echo "$out"; return; }
  out="$("$1" -V 2>/dev/null | head -n1)"
  [[ -n "$out" ]] && { echo "$out"; return; }
  echo "(installed)"
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

_pb_sectors_read() {               # $1=/dev/xxx → stat field 3 (sectors READ)
  local name="${1#/dev/}" f="" d
  if [[ -r "/sys/block/$name/stat" ]]; then f="/sys/block/$name/stat"
  else
    for d in /sys/block/*; do [[ -r "$d/$name/stat" ]] && { f="$d/$name/stat"; break; }; done
  fi
  [[ -n "$f" ]] || return 1
  local s
  read -r _ _ s _ < "$f" || return 1
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
  local have_dev=0 s0=0 dev_mode=""
  if [[ -n "${PB_DEV:-}" && -b "${PB_DEV}" && "$tot" -gt 0 ]]; then
    s0="$(_pb_sectors_written "$PB_DEV" 2>/dev/null || echo X)"
    [[ "$s0" =~ ^[0-9]+$ ]] && { have_dev=1; dev_mode="write"; }
  elif [[ -n "${PB_SRC:-}" && -b "${PB_SRC}" && "$tot" -gt 0 ]]; then
    s0="$(_pb_sectors_read "$PB_SRC" 2>/dev/null || echo X)"
    [[ "$s0" =~ ^[0-9]+$ ]] && { have_dev=1; dev_mode="read"; }
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
  
  # centering helper: fills global _PB_PAD with left padding
  _pb_pad() {
    local w="$1" n="$2" p i out=""
    p=$(( (w - n) / 2 )); (( p < 1 )) && p=1
    for ((i=0; i<p; i++)); do out+=" "; done
    printf -v _PB_PAD '%s' "$out"
  }

  echo
  if [[ -n "$dst" ]]; then
    _pb_pad "$cols" $(( ${#action} + 3 ))
    printf '%s%s %s%s%s\n' "$_PB_PAD" "$emo" "$BLD" "$action" "$RST"
    _pb_pad "$cols" $(( ${#src} + ${#dst} + 5 ))
    printf '%s%s%s%s  %s→%s  %s%s%s\n' "$_PB_PAD" "$WHT" "$src" "$RST" "$DIM" "$RST" "$WHT" "$dst" "$RST"
    if [[ -n "${PB_SUBLINE:-}" ]]; then
      _pb_pad "$cols" $(( ${#PB_SUBLINE} ))
      printf '%s%s%s%s\n' "$_PB_PAD" "$DIM" "$PB_SUBLINE" "$RST"
    fi
  else
    _pb_pad "$cols" $(( ${#src} + 3 ))
    printf '%s%s %s%s%s %s%s%s\n' "$_PB_PAD" "$emo" "$BLD" "$action" "$RST" "$WHT" "$src" "$RST"
  fi
  echo

  local pgid_kill=0
  if have setsid; then
    setsid "${cmd[@]}" </dev/null >"$plog" 2>&1 &
    pgid_kill=1
  else
    "${cmd[@]}" </dev/null >"$plog" 2>&1 &
  fi
  local pid=$!
  if (( pgid_kill )); then
    _PB_LAST_PGD="$pid"
    cleanup_unregister _pb_kill_last 2>/dev/null
    register_cleanup _pb_kill_last
  fi
  # signal helper: whole group when setsid, else pid-tree
  _pb_signal() {
    if (( pgid_kill )); then kill -"$1" -"$pid" 2>/dev/null || kill_tree "$pid" "$1"
    else kill_tree "$pid" "$1"; fi
  }

  local t0 now_ms prev_ms=0
  t0="$(_pb_now_ms)"
  
  # Graceful interrupt: kill the WHOLE tree (script → sh → qemu-img),
  # or cancelled runs leave orphan readers/writers starving later runs
  local _pb_interrupted=0 _pb_int_at=0 _pb_escalated=0
  local _pb_prev_trap; _pb_prev_trap="$(trap -p INT TERM HUP)"
  trap '_pb_interrupted=1; _pb_int_at=$(( $(_pb_now_ms) - t0 )); _pb_signal INT' INT TERM HUP
  
  local ms_prev=$t0 bytes_prev=0 speed=0
  local last_p=0 last_t=$t0 rate=0
  local eta_base=-1 eta_at=0 eta_rev=0 eta_cd=0
  local -a FR=("" "▏" "▎" "▍" "▌" "▋" "▊" "▉")
  local now ms written=0 pct=0 chunk content
  local stall_warned=0 last_advance=$t0 prev_written=0

  while kill -0 "$pid" 2>/dev/null; do
    now="$(_pb_now_ms)"; ms=$(( now - t0 ))
    
    # Monotonic time guard
    (( ms < prev_ms )) && ms=$prev_ms
    prev_ms=$ms
    # Space-watchdog flag → treat exactly like Ctrl+C (signal-free, race-free)
    if (( ! _pb_interrupted )) && [[ -f "/run/qemu-disk-tool/space-watchdog.$$" ]]; then
      _pb_interrupted=1; _pb_int_at=$ms; _pb_signal INT
    fi
    # Cancel requested but child still alive after 3s → escalate to KILL (once)
    if (( _pb_interrupted )) && (( ! _pb_escalated )) && (( ms - _pb_int_at > 3000 )); then
      _pb_escalated=1
      _pb_signal KILL
      local _w=0
      while kill -0 "$pid" 2>/dev/null && (( _w < 30 )); do sleep 0.1; _w=$(( _w + 1 )); done
    fi

    if (( have_dev )); then
      local s
      if [[ "$dev_mode" == "read" ]]; then
        s="$(_pb_sectors_read "$PB_SRC" 2>/dev/null || echo "$s0")"
      else
        s="$(_pb_sectors_written "$PB_DEV" 2>/dev/null || echo "$s0")"
      fi
      [[ "$s" =~ ^[0-9]+$ ]] || s=$s0
      written=$(( (s - s0) * 512 )); (( written < 0 )) && written=0
      pct=$(( written * 10000 / tot ))
    else
      # Use grep to find the latest progress percentage reliably
      local np=""
      np="$(grep -o '([0-9.]\+/100%)' "$plog" 2>/dev/null | tail -n1 | tr -d '()' | cut -d'/' -f1 || true)"
      local p100=-1
      if [[ -n "$np" ]]; then
        if [[ "$np" == *.* ]]; then
          local ip=${np%%.*} fp=${np#*.}; fp=${fp:0:2}
          (( ${#fp} == 1 )) && fp+=0
          p100=$(( 10#$ip * 100 + 10#$fp ))
        else
          p100=$(( 10#$np * 100 ))
        fi
      fi
      # Fallback for "bytes copied" style output (dd, rsync, etc.)
      if (( p100 < 0 && tot > 0 )); then
        local bytes_now
        bytes_now="$(grep -oE '[0-9]+ bytes.*copied' "$plog" 2>/dev/null | tail -n1 | awk '{print $1}' || true)"
        if [[ "$bytes_now" =~ ^[0-9]+$ ]]; then
          p100=$(( bytes_now * 10000 / tot ))
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

    # ── stall watchdog: alive but nothing moving → show WHY ──
    if (( written > prev_written )); then prev_written=$written; last_advance=$now; fi
    if (( ! stall_warned && now - last_advance > 180000 )); then
      stall_warned=1
      { echo
        echo "   ⚠️  No progress for 3 minutes — last command output:"
        tr '\r' '\n' < "$plog" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 5 | sed 's/^/   │ /'
        echo "   (still waiting… Ctrl+C cancels and cleans up)"
      } >&2
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
    _pb_human "$speed"; local spd_s="$PB_H"

    local display_written="$written"
    if (( tot > 0 && display_written > tot )); then
      display_written="$tot"
    fi

    _pb_human "$display_written"; local wr_s="$PB_H"
    _pb_human "$tot";             local tot_s="$PB_H"
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

  local rc=0
  if (( _pb_interrupted )); then
    wait "$pid" 2>/dev/null || true
    rc=130
  else
    wait "$pid" || rc=$?
  fi
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
    if [[ -s "$plog" ]]; then
      local tail_n=8; (( rc == 11 )) && tail_n=3   # caller prints a tailored diagnosis for 11
      echo "   ── last command output ──"
      tr '\r' '\n' < "$plog" | grep -v '^[[:space:]]*$' | tail -n "$tail_n" | sed 's/^/   │ /'
    fi
  fi
  _pb_signal KILL                # belt-and-braces: no survivors
  local _w2=0
  while kill -0 "$pid" 2>/dev/null && (( _w2 < 30 )); do sleep 0.1; _w2=$(( _w2 + 1 )); done
  _PB_LAST_PGD=""
  if (( rc == 0 || rc == 130 )); then
    rm -f "$plog"; _PB_LAST_LOG=""
  else
    _PB_LAST_LOG="$plog"         # kept for caller diagnostics (next run truncates it)
  fi
  if [[ -n "$_pb_prev_trap" ]]; then eval "$_pb_prev_trap"; else trap 'exit 130' INT TERM HUP; fi
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

# Engine backstop: kill the last engine process GROUP on any exit (terminal close, Ctrl+C, crash)
_PB_LAST_PGD=""
_PB_LAST_LOG=""   # engine keeps the child's output log here after a FAILED run
_pb_kill_last() {
  [[ -n "${_PB_LAST_PGD:-}" ]] && kill -KILL -"$_PB_LAST_PGD" 2>/dev/null
  _PB_LAST_PGD=""
}

# ── Space watchdog: stops the tool BEFORE ENOSPC destroys a multi-hour run ──
# ── Space watchdog: sets a flag when free space drops below a threshold ──
#
# The engine polls ONE shared per-run flag. Multiple watchdog instances may
# watch different filesystems (for example outer destination + inner qcow2
# filesystem) and they all use the same flag. The first trigger records the
# reason in the flag file; the caller can read it after run_with_progress_bar.
#
# $1 = directory / mountpoint to watch
# $2 = threshold bytes
# $3 = optional human-readable label, e.g. "outer destination" / "inner target"
start_space_watchdog() {
  local dir="$1"
  local thr="$2"
  local label="${3:-filesystem}"
  local me="$$" f pid flag wd_pid

  [[ -n "$dir" ]] || return 1
  [[ "$thr" =~ ^[0-9]+$ ]] || return 1

  flag="/run/qemu-disk-tool/space-watchdog.$me"

  # Clean stale flags left behind by SIGKILLed runs.
  for f in /run/qemu-disk-tool/space-watchdog.*; do
    [[ -f "$f" ]] || continue
    pid="${f##*.}"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      continue
    fi
    rm -f "$f"
  done

  mkdir -p /run/qemu-disk-tool 2>/dev/null || return 1

  (
    local avail
    while :; do
      sleep 2

      # Parent script disappeared: terminate quietly.
      kill -0 "$me" 2>/dev/null || exit 0

      avail="$(df -B1 -- "$dir" 2>/dev/null | awk 'NR==2 {print $4}')"
      avail="${avail:-0}"

      if (( avail < thr )); then
        # First watchdog to fire wins. Preserve its diagnostic information.
        if [[ ! -f "$flag" ]]; then
          printf '%s\n' \
            "label=$label" \
            "dir=$dir" \
            "free_bytes=$avail" \
            "threshold_bytes=$thr" \
            > "$flag"
        fi

        warn "Space watchdog [$label]: only $(numfmt --to=iec "$avail") left on $dir — stopping the copy before ENOSPC."
        exit 0
      fi
    done
  ) >/dev/null &

  wd_pid=$!
  echo "$wd_pid"
}

# Kill a process and ALL its descendants (pty children included)
kill_tree() {
  local pid="$1" sig="${2:-INT}" c
  for c in $(pgrep -P "$pid" 2>/dev/null); do kill_tree "$c" "$sig"; done
  kill -"$sig" "$pid" 2>/dev/null || true
}

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
  local prev_trap
  prev_trap="$(trap -p INT TERM HUP)"
  "$@" &
  local pid=$!
  trap 'kill_tree "$pid" INT 2>/dev/null' INT TERM HUP
  spinner "$pid" "$msg"
  wait "$pid"
  local rc=$?
  if [[ -n "$prev_trap" ]]; then
    eval "$prev_trap"
  else
    trap 'exit 130' INT TERM HUP
  fi
  return $rc
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
    return 130
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
          if ($1 ~ "^/dev/(nbd|loop|nullb|zram|ram)[0-9]*") next
          if ($2 == "rom") next
          if ($3 ~ /^0(\.0+)?[BKMGTPEZ]?$/) next   # empty card readers / no medium
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

# ── Read-only mount with journal-safe fallbacks (dirty journals, xfs/btrfs) ──
mount_ro_fs() {   # $1=device $2=mountpoint $3=quiet(true|false, default false)
  local dev="$1" mp="$2" quiet="${3:-false}"
  mount -o ro "$dev" "$mp" 2>/dev/null && return 0
  mount -t ext4 -o ro,noload "$dev" "$mp" 2>/dev/null && return 0
  if [[ "$quiet" == "true" ]]; then
    mount -o ro,norecovery "$dev" "$mp" 2>/dev/null
  else
    mount -o ro,norecovery "$dev" "$mp"
  fi
}

is_mounted() {
  local dev="$1"
  findmnt -rn --source "$dev" >/dev/null 2>&1
}

maybe_unmount() {
  local dev="$1"
  local targets="" ans line p t

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
      local unmount_failed=0
      while IFS= read -r t; do
        if [[ -n "$t" ]]; then
          if ! umount "$t" 2>/dev/null; then
            # Check if it's actually still mounted (might have been already unmounted)
            if mountpoint -q "$t" 2>/dev/null || findmnt -rn --target "$t" >/dev/null 2>&1; then
              warn "Failed to unmount: $t (device busy?)"
              unmount_failed=1
            fi
          fi
        fi
      done < <(echo "$targets" | awk '{print length "\t" $0}' | sort -nr | cut -f2-)
      
      if (( unmount_failed )); then
        warn "Cannot proceed: some mounts could not be released."
        return 1
      fi
      log "Unmount successful ✅"
    else
      warn "Refusing to touch a mounted device. Operation cancelled."
      return 1
    fi
  fi
  return 0
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

  # Single merged view: tree + partition type names + mountpoints
  lsblk -o NAME,TYPE,SIZE,FSTYPE,PARTTYPENAME,MOUNTPOINTS "$dev" >&2 || true

  local parts
  parts="$(lsblk -nrpo NAME,FSTYPE "$dev" 2>/dev/null | tail -n +2)"
  if [[ -n "$parts" ]] && echo "$parts" | grep -qi "vfat"; then
    echo "   🔎 UEFI hint: FAT partition detected (possible EFI System Partition)" >&2
  fi
  echo >&2
}

verify_image() {
  local img="$1"
  [[ -f "$img" ]] || return 0

  local fmt
  fmt="$(detect_img_format "$img")"
  
  # Raw and some other formats don't support integrity checks
  if [[ "$fmt" == "raw" || "$fmt" == "vmdk" || "$fmt" == "vpc" || "$fmt" == "vhdx" ]]; then
    info "Image format $fmt does not support integrity checks (skipped)."
    return 0
  fi

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
    info "Opening file picker to select source image…"
    p="$(gui_pick_file "Select a disk image" "*.qcow2 *.img *.raw *.vmdk *.vhdx *.vhd")"
    if [[ -z "$p" ]]; then
      warn "GUI cancelled. Falling back to terminal input." >&2
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
  local p="" ans=""
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
  local ans=""

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

# ── Canonical convert wrapper: pty + total + env hygiene ──
run_convert_engine() {
  local src_fmt="$1" src="$2" dst_fmt="$3" dst="$4"
  shift 4
  local total=0
  [[ "${1:-}" =~ ^[0-9]+$ ]] && { total="$1"; shift; }   # optional explicit total
  local -a extra=("$@")

  # Progress total = bytes qemu-img will READ (device size / virtual size)
  (( total > 0 )) || total="$(get_total_bytes "$src" 2>/dev/null || echo 0)"
  [[ "$total" =~ ^[0-9]+$ ]] || total=0

  local -a cmd=(qemu-img convert -p -f "$src_fmt" -O "$dst_fmt")
  ((${#extra[@]} > 0)) && cmd+=("${extra[@]}")
  cmd+=("$src" "$dst")

  # qemu-img -p prints progress ONLY on a TTY → run inside a pty so the
  # engine's log parser receives (NN.NN/100%) lines
  local cmd_str
  cmd_str="$(printf '%q ' "${cmd[@]}")"

  PB_TOTAL="$total"
  PB_HEADER="$src → $dst"              # full paths in the header line
  [[ -b "$src" ]] && PB_SRC="$src"     # real-time kernel READ counters

  # Detail subline: drive model · size · output format/compression
  local comp="" model="" sub=""
  [[ " ${extra[*]} " == *" -c "* ]] && comp="compressed"
  [[ " ${extra[*]} " == *"compression_type=zstd"* ]] && comp="zstd-compressed"
  if [[ -b "$src" ]]; then
    model="$(lsblk -no MODEL "$src" 2>/dev/null | head -n1)"
    model="${model#"${model%%[![:space:]]*}"}"; model="${model%"${model##*[![:space:]]}"}"
    _pb_human "$total"
    sub="${model:-disk} · $PB_H · $dst_fmt${comp:+ ($comp)}"
  else
    sub="$dst_fmt${comp:+ ($comp)}"
  fi
  PB_SUBLINE="$sub"

  run_with_progress_bar "Converting $src → $dst" "$total" \
    script -q -f -e -c "$cmd_str" /dev/null
  local rc=$?
  unset PB_TOTAL PB_HEADER PB_SRC PB_SUBLINE
  return $rc
}

# ── Canonical clone wrapper: kernel WRITE counters on target + 3-line header ──
run_clone_engine() {   # $1=src $2=target $3=total $4=use_pv(true|false)
  local src="$1" target="$2" total="$3" usepv="${4:-false}"
  local -a cmd
  if [[ "$usepv" == "true" ]]; then
    local sh_cmd
    sh_cmd="$(printf 'pv -s %q -N Cloning %q > %q' "$total" "$src" "$target")"
    cmd=(bash -c "$sh_cmd")
    log "Using pv for block-level copy…"
  else
    cmd=(qemu-img convert -p -f raw -O raw "$src" "$target")
  fi

  local smodel tmodel
  smodel="$(lsblk -no MODEL "$src" 2>/dev/null | head -n1)"
  smodel="${smodel#"${smodel%%[![:space:]]*}"}"; smodel="${smodel%"${smodel##*[![:space:]]}"}"
  tmodel="$(lsblk -no MODEL "$target" 2>/dev/null | head -n1)"
  tmodel="${tmodel#"${tmodel%%[![:space:]]*}"}"; tmodel="${tmodel%"${tmodel##*[![:space:]]}"}"
  _pb_human "$total"

  PB_EMOJI="📀"
  PB_DEV="$target"
  PB_TOTAL="$total"
  PB_HEADER="$src → $target"
  PB_SUBLINE="${smodel:-disk} ($PB_H) → ${tmodel:-disk}"
  run_with_progress_bar "Cloning $src → $target…" "$total" "${cmd[@]}"
  local rc=$?
  unset PB_EMOJI PB_DEV PB_TOTAL PB_HEADER PB_SUBLINE
  return $rc
}

# ── Canonical device-write wrapper: kernel counters + 3-line header ──
run_write_engine() {   # $1=img $2=target $3=total_bytes $4=compressed(true|false)
  local img="$1" target="$2" total="$3" compressed="${4:-false}"
  local -a cmd=(qemu-img convert -p)
  if [[ "$compressed" == "true" ]]; then
    cmd+=(-m 1)
    log "Compressed image detected — using low-memory mode (-m 1)"
  fi
  cmd+=(-O raw "$img" "$target")

  local fmt model tgt_size
  fmt="$(detect_img_format "$img")"
  model="$(lsblk -no MODEL "$target" 2>/dev/null | head -n1)"
  model="${model#"${model%%[![:space:]]*}"}"; model="${model%"${model##*[![:space:]]}"}"
  tgt_size="$(bytes_of_src "$target" 2>/dev/null || echo 0)"
  _pb_human "$tgt_size"

  PB_EMOJI="🧨"
  PB_DEV="$target"
  PB_TOTAL="$total"
  PB_HEADER="$(basename "$img") → $target"
  PB_SUBLINE="$fmt${compressed:+ (compressed)} · $(numfmt --to=iec "$total") → ${model:-disk} · $PB_H"
  run_with_progress_bar "Writing (image → raw → device)…" "$total" "${cmd[@]}"
  local rc=$?
  unset PB_EMOJI PB_DEV PB_TOTAL PB_HEADER PB_SUBLINE
  return $rc
}

# Legacy alias (same arg order: in_fmt src out_fmt dst [total] [extra...])
run_convert() { run_convert_engine "$@"; }

pick_free_nbd() {
  check_nbd_module >&2 || return 1

  udevadm settle 2>/dev/null || true

  local dev idx size

  for dev in /dev/nbd*; do
    [[ -b "$dev" ]] || continue
    [[ "$dev" =~ ^/dev/nbd[0-9]+$ ]] || continue

    idx="${dev#/dev/nbd}"
    size="$(cat "/sys/block/nbd${idx}/size" 2>/dev/null || echo 0)"

    if [[ "${size:-0}" == "0" ]] && ! _nbd_owned_by_other "$idx"; then
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
  [[ -b "$disk" ]] || { warn "Not a block device: $disk"; return 1; }

  local parts=()
  while IFS= read -r p; do
    [[ -b "$p" ]] && parts+=("$p")
  done < <(lsblk -nrpo NAME,TYPE "$disk" | awk '$2=="part"{print $1}')

  ((${#parts[@]} == 0)) && { warn "No partitions found on: $disk"; return 1; }

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

  # Run registered cleanup hooks (LIFO)
  for ((i=${#CLEANUP_HOOKS[@]}-1; i>=0; i--)); do
    "${CLEANUP_HOOKS[$i]}" 2>/dev/null || true
  done
  CLEANUP_HOOKS=()

  # Disconnect all used nbd devices
  for d in "${USED_NBDS[@]}"; do
    [[ "$d" =~ ^/dev/nbd[0-9]+$ ]] || continue
    _nbd_unstamp "$d"

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

  # Unload ONLY if WE loaded it AND nobody (any terminal) is using it
  if [[ "$any_in_use" -eq 0 && "${NBD_LOADED_BY_US:-0}" -eq 1 ]]; then
    timeout 5 modprobe -r nbd 2>/dev/null || true   # never block exit on a stuck module
    NBD_LOADED_BY_US=0
  fi
}

# ── Register global cleanup traps ──
trap global_cleanup EXIT
trap 'exit 130' INT TERM HUP   # HUP = terminal closed → still clean up



write_image_metadata() {
  local img="$1"
  local src="${2:-unknown}"
  local notes="${3:-No additional notes}"
  
  local info_file="${img}.info"
  local fmt vsize dsize hostname_str user_str gen_time
  local part_info
  
  fmt="$(detect_img_format "$img" 2>/dev/null || echo "unknown")"
  vsize="$(qemu-img info "$img" 2>/dev/null | awk -F': ' '/^virtual size:/ {print $2; exit}')"
  dsize="$(stat -c '%s' "$img" 2>/dev/null || echo "0")"
  hostname_str="$(hostname 2>/dev/null || echo "unknown")"
  user_str="${SUDO_USER:-$USER}"
  gen_time="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  
  if [[ -b "$src" ]]; then
    part_info="$(lsblk -nrpo NAME,SIZE,FSTYPE "$src" 2>/dev/null | head -20 || echo "  (unable to read partition info)")"
  else
    part_info="  (source is not a block device)"
  fi
  
  # Safe: quoted heredoc prevents command injection
  cat > "$info_file" 2>/dev/null <<'METAEOF'
# QEMU Disk Tool — Image Metadata
METAEOF
  
  # Append dynamic content safely using printf
  {
    printf '# Generated: %s\n\n' "$gen_time"
    printf '[Image]\n'
    printf 'File: %s\n' "$(basename "$img")"
    printf 'Format: %s\n' "${fmt:-unknown}"
    printf 'Virtual_Size: %s\n' "${vsize:-unknown}"
    printf 'Disk_Size_Bytes: %s\n' "$dsize"
    printf '\n[Source]\n'
    printf 'Device: %s\n' "$src"
    printf 'Hostname: %s\n' "$hostname_str"
    printf 'User: %s\n' "$user_str"
    printf '\n[Partition_Info]\n%s\n' "$part_info"
    printf '\n[Notes]\n%s\n' "$notes"
  } >> "$info_file" 2>/dev/null

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

# ============================================================
# NEW PHASE 1 HELPERS (Appended safely)
# ============================================================

# ── Neutral cancel (info + return 1, NOT die) ──
user_cancel() { info "${1:-Cancelled.}"; return 1; }

# ── Hook registry ──
register_cleanup() { CLEANUP_HOOKS+=("$1"); }
cleanup_unregister() {
  local fn="$1" tmp=()
  for x in "${CLEANUP_HOOKS[@]}"; do [[ "$x" != "$fn" ]] && tmp+=("$x"); done
  CLEANUP_HOOKS=("${tmp[@]}")
}

# ── Typed confirmation with retry + optional cancel keywords ──
confirm_typed() {
  local word="$1" prompt="${2:-Type $word to confirm:}" allow_empty="${3:-false}"
  local ans
  while true; do
    read -rp "✍️  $prompt " ans <"$TTY"
    if [[ "$ans" == "$word" ]]; then return 0; fi
    if [[ "$allow_empty" == "true" && -z "$ans" ]]; then user_cancel "Aborted (empty input)."; return 1; fi
    case "${ans,,}" in cancel|q|quit|c|abort) user_cancel "Aborted by user."; return 1 ;; esac
    warn "Mismatch! Please type exactly: $word"
  done
}

# ── Format → extension ──
fmt_to_ext() {
  case "$1" in
    qcow2) echo "qcow2" ;; raw) echo "img" ;; vmdk) echo "vmdk" ;;
    vhdx) echo "vhdx" ;; vpc|vhd) echo "vhd" ;; *) echo "img" ;;
  esac
}

# ── Bounded size input ──
ask_size() {
  local prompt="${1:-📏 Size (e.g., 20G)}" min="${2:-1048576}" max="${3:-70368744177664}"
  local size bytes
  while true; do
    read -rp "$prompt: " size <"$TTY"
    [[ -n "$size" ]] || { warn "Size cannot be empty."; continue; }
    [[ "$size" =~ ^[0-9]+[bBkKmMgGtTpPeE]?$ ]] || { warn "Invalid format. Use number + K/M/G/T."; continue; }
    bytes="$(numfmt --from=auto "$size" 2>/dev/null)" || { warn "Could not parse size."; continue; }
    (( bytes < min )) && { warn "Too small (min $(numfmt --to=iec "$min"))."; continue; }
    (( bytes > max )) && { warn "Too large (max $(numfmt --to=iec "$max"))."; continue; }
    echo "$size"; return
  done
}

# ── Free-space check ──
check_free_space() {
  local dir="$1" need="$2"
  local avail; avail="$(df -B1 "$dir" 2>/dev/null | awk 'NR==2 {print $4}')"
  avail="${avail:-0}"
  (( avail >= need )) || {
    err "Not enough space in $dir"; echo "   Need:      $(numfmt --to=iec "$need")"; echo "   Available: $(numfmt --to=iec "$avail")"; return 1
  }; return 0
}

# ── Save path with GUI fallback, auto-ext, dir/overwrite/space checks ──
# $4 = protected_path (e.g., source file) which MUST NOT be overwritten.
ask_save_path() {
  local default_path="$1" ext="${2:-}" est_bytes="${3:-0}" protected_path="${4:-}" defer_existing="${5:-false}"
  local remembered_path="$default_path" try_gui=true dst="" tmp outdir parent_dir
  outdir="$(dirname "$default_path")"

  while true; do
    dst=""
    if [[ "$try_gui" == "true" ]] && has_gui; then
      local gui_path
      info "Opening file picker to choose save location…"
      gui_path="$(gui_pick_save_file "Save as" "$remembered_path" || true)"
      if [[ -n "$gui_path" ]]; then dst="$gui_path"
      else info "GUI cancelled. Falling back to terminal input." >&2; fi
      try_gui=false
    fi
    if [[ -z "$dst" ]]; then
      echo >&2
      echo "   📁 Current path: $remembered_path" >&2
      if has_gui; then echo "   💡 Type a path, 'gui' for picker, or 'cancel' to abort." >&2
      else echo "   💡 Type a path or 'cancel' to abort." >&2; fi
      read -rp "   ➡️  Save as: " tmp <"$TTY" || { user_cancel >&2; return 1; }
      case "${tmp,,}" in
        cancel|q|quit|abort) user_cancel >&2; return 1 ;;
        gui)  try_gui=true; continue ;;
        "")   dst="$remembered_path" ;;
        */*)  dst="$tmp" ;;
        *)    dst="$outdir/$tmp" ;;
      esac
    fi
    [[ -n "$ext" && "$dst" != *".$ext" ]] && dst="${dst}.${ext}"
    remembered_path="$dst"

    parent_dir="$(dirname "$dst")"
    [[ -d "$parent_dir" ]] || { warn "Directory not found: $parent_dir" >&2; continue; }

    if [[ -e "$dst" && "$defer_existing" != "true" ]]; then
      # Guard against overwriting a protected file (e.g., the source image)
      if [[ -n "$protected_path" ]]; then
        local dst_real prot_real
        dst_real="$(realpath -m "$dst" 2>/dev/null || echo "$dst")"
        prot_real="$(realpath -m "$protected_path" 2>/dev/null || echo "$protected_path")"
        if [[ "$dst_real" == "$prot_real" ]]; then
          err "Refusing to overwrite the protected source file: $protected_path" >&2
          continue
        fi
      fi

      warn "File exists: $dst" >&2
      local ow; ow="$(ask_yesno "Overwrite it?" "N")"
      [[ "$ow" == "true" ]] || continue
      rm -f "$dst"
    fi

    (( est_bytes > 0 )) && { check_free_space "$parent_dir" "$est_bytes" >&2 || continue; }

    success "Output confirmed: $dst" >&2
    echo "$dst"          # ← the ONLY stdout output
    return 0
  done
}

# ── Build the EXACT rsync exclude list used by Option 10 ──
# $1 = boot_part
# $2 = source_is_live (0|1)
# $3 = nameref receiving the array
_migration_build_rsync_excludes() {
  local boot_part="$1"
  local src_is_live="$2"
  local -n _out="$3"

  _out=(
    --exclude='/proc/*'
    --exclude='/sys/*'
    --exclude='/dev/*'
    --exclude='/run/*'
    --exclude='/tmp/*'
    --exclude='/mnt/*'
    --exclude='/media/*'
    --exclude='/lost+found'
    --exclude='/.migration-src-id'
  )

  [[ -n "$boot_part" ]] && _out+=(--exclude='/boot/efi/*')

  # These are LIVE-source exclusions only. Do not duplicate them in the
  # base list; the same helper is used by dry-run, resume probe, and copy.
  if (( src_is_live )); then
    _out+=(
      --exclude='/var/log/journal/*'
      --exclude='/var/cache/*'
      --exclude='/var/tmp/*'
      --exclude='/var/crash/*'
      --exclude='/var/spool/abrt/*'
      --exclude='/home/*/.cache/*'
      --exclude='/root/.cache/*'
    )
  fi
}

# ── Measure the actual rsync transfer set before creating a fresh image ──
# Prints ONLY the measured transfer bytes on stdout.
# Returns 1 if the measurement cannot be obtained.
_migration_measure_transfer() {
  local root_part="$1"
  local boot_part="$2"
  local src_is_live="$3"

  local src_mp src_here=0
  local used_bytes=""

  src_mp="$(findmnt -rn -o TARGET -S "$root_part" 2>/dev/null | head -n1)"

  if [[ -z "$src_mp" ]]; then
    src_mp="$(mktemp -d)" || return 1

    if ! mount_ro_fs "$root_part" "$src_mp" true; then
      rmdir "$src_mp" 2>/dev/null || true
      return 1
    fi

    src_here=1
  fi

  # Measure ACTUAL allocated filesystem space, not logical file size.
  # This is important for sparse VM images, databases, containers, etc.
  #
  # We cd into $src_mp in a subshell so du --exclude patterns match correctly
  # against relative paths (./proc instead of /tmp/tmp.xxx/proc).
  # -x prevents traversal into separately mounted filesystems.
  local -a du_ex=(
    --exclude='./proc'
    --exclude='./sys'
    --exclude='./dev'
    --exclude='./run'
    --exclude='./tmp'
    --exclude='./mnt'
    --exclude='./media'
    --exclude='./lost+found'
    --exclude='./.migration-src-id'
  )

  [[ -n "$boot_part" ]] && \
    du_ex+=(--exclude='./boot/efi')

  if (( src_is_live )); then
    du_ex+=(
      --exclude='./var/log/journal'
      --exclude='./var/cache'
      --exclude='./var/tmp'
      --exclude='./var/crash'
      --exclude='./var/spool/abrt'
      --exclude='./home/*/.cache'
      --exclude='./root/.cache'
    )
  fi

  used_bytes="$(
    (
      cd "$src_mp" 2>/dev/null || exit 1
      du -sx -B1 \
        "${du_ex[@]}" \
        . 2>/dev/null |
        awk 'NR==1 {print $1}'
    )
  )"

  if [[ ! "$used_bytes" =~ ^[0-9]+$ ]]; then
    if (( src_here )); then
      umount "$src_mp" 2>/dev/null || true
      rmdir "$src_mp" 2>/dev/null || true
    fi

    warn "Could not measure allocated source space safely."
    return 1
  fi

  if (( src_here )); then
    umount "$src_mp" 2>/dev/null || true
    rmdir "$src_mp" 2>/dev/null || true
  fi

  printf '%s\n' "$used_bytes"
}

# ── Probe an existing qcow2 for resumability ──
# Returns 0 if resumable; prints reason to stderr on refusal.
# Args: $1=image path, $2=source disk (for marker check), $3=boot_part (empty=BIOS), $4=root_part
_migration_can_resume() {
  local img="$1" src_disk="$2" boot_part="$3" root_part="$4"
  _MIG_RESUME_DELTA=0

  [[ -f "$img" ]] || return 1

  local fmt
  fmt="$(
    LC_ALL=C qemu-img info "$img" 2>/dev/null |
      sed -n 's/^file format: //p' |
      head -n1
  )"

  [[ "$fmt" == "qcow2" ]] || return 1

  local nbd="" probe_root="" probe_mp="" probe_src_mp="" src_here=0
  local src_tmp="" src_is_live=0
  local src_serial="" marker=""
  local dry_out="" dry_need="" dry_created=""
  local target_free="" target_ifree=""
  local dry_rc=0 verdict=1

  if ! nbd="$(nbd_attach "$img" true 2>/dev/null)"; then
    return 1
  fi

  if [[ -n "$boot_part" ]]; then
    local probe_efi="${nbd}p1"
    probe_root="${nbd}p2"

    if [[ ! -b "$probe_efi" || ! -b "$probe_root" ]]; then
      nbd_release "$nbd" 2>/dev/null || true
      return 1
    fi
  else
    probe_root="${nbd}p1"

    if [[ ! -b "$probe_root" || -b "${nbd}p2" ]]; then
      nbd_release "$nbd" 2>/dev/null || true
      return 1
    fi
  fi

  if ! e2fsck -fn "$probe_root" >/dev/null 2>&1; then
    nbd_release "$nbd" 2>/dev/null || true
    return 1
  fi

  probe_mp="$(mktemp -d)" || {
    nbd_release "$nbd" 2>/dev/null || true
    return 1
  }

  if ! mount -o ro "$probe_root" "$probe_mp" 2>/dev/null; then
    rmdir "$probe_mp" 2>/dev/null || true
    nbd_release "$nbd" 2>/dev/null || true
    return 1
  fi

  if [[ ! -f "$probe_mp/etc/fstab" ]]; then
    umount "$probe_mp" 2>/dev/null || true
    rmdir "$probe_mp" 2>/dev/null || true
    nbd_release "$nbd" 2>/dev/null || true
    return 1
  fi

  src_serial="$(
    lsblk -no SERIAL "$src_disk" 2>/dev/null |
      head -n1 |
      tr -d ' '
  )"

  if [[ -s "$probe_mp/.migration-src-id" && -n "$src_serial" ]]; then
    marker="$(
      tr -d '\r\n' < "$probe_mp/.migration-src-id" 2>/dev/null || true
    )"

    if [[ "$marker" != "$src_serial" ]]; then
      umount "$probe_mp" 2>/dev/null || true
      rmdir "$probe_mp" 2>/dev/null || true
      nbd_release "$nbd" 2>/dev/null || true
      return 1
    fi
  fi

  probe_src_mp="$(
    findmnt -rn -o TARGET -S "$root_part" 2>/dev/null |
      head -n1
  )"

  if [[ -n "$probe_src_mp" ]]; then
    src_is_live=1
  else
    src_tmp="$(mktemp -d)" || {
      umount "$probe_mp" 2>/dev/null || true
      rmdir "$probe_mp" 2>/dev/null || true
      nbd_release "$nbd" 2>/dev/null || true
      return 1
    }

    probe_src_mp="$src_tmp"

    if ! mount_ro_fs "$root_part" "$probe_src_mp" true; then
      rmdir "$src_tmp" 2>/dev/null || true
      umount "$probe_mp" 2>/dev/null || true
      rmdir "$probe_mp" 2>/dev/null || true
      nbd_release "$nbd" 2>/dev/null || true
      return 1
    fi

    src_here=1
  fi

  local -a rs_ex=()
  _migration_build_rsync_excludes "$boot_part" "$src_is_live" rs_ex

  if dry_out="$(
    LC_ALL=C rsync -aHAXSx --numeric-ids --dry-run --stats \
      "${rs_ex[@]}" \
      "$probe_src_mp/" "$probe_mp/" 2>&1
  )"; then
    dry_rc=0
  else
    dry_rc=$?
  fi

  dry_need="$(
    sed -n \
      's/^Total transferred file size: *\([0-9,]*\) bytes.*/\1/p' \
      <<<"$dry_out" |
      tr -d ',' |
      head -n1
  )"

  dry_created="$(
    sed -n \
      's/^Number of created files: *\([0-9,]*\).*/\1/p' \
      <<<"$dry_out" |
      tr -d ',' |
      head -n1
  )"

  target_free="$(
    df -B1 "$probe_mp" 2>/dev/null |
      awk 'NR==2 {print $4}'
  )"

  target_ifree="$(
    df -Pi "$probe_mp" 2>/dev/null |
      awk 'NR==2 {print $4}'
  )"

  target_free="${target_free:-0}"
  target_ifree="${target_ifree:-0}"

  if [[ "$dry_need" =~ ^[0-9]+$ &&
        "$target_free" =~ ^[0-9]+$ ]]; then

    local byte_need=$(( dry_need + 256*1024*1024 ))

    if (( target_free >= byte_need )); then
      if [[ "$target_ifree" =~ ^[0-9]+$ &&
            "$target_ifree" -gt 0 ]]; then

        if [[ "$dry_created" =~ ^[0-9]+$ ]]; then
          local inode_need=$(( dry_created + dry_created/20 + 1024 ))

          if (( target_ifree >= inode_need )); then
            verdict=0
            _MIG_RESUME_DELTA="$dry_need"    # global: caller reads this AFTER the function returns
          fi
        else
          verdict=0
          _MIG_RESUME_DELTA="$dry_need"
          warn "Resume probe could not parse rsync's created-file count; byte/inode zero checks passed."
        fi
      fi
    fi
  fi

  if (( dry_rc != 0 )) && [[ "$dry_need" =~ ^[0-9]+$ ]]; then
    warn "Resume rsync dry-run returned exit $dry_rc, but produced usable statistics."
  fi

  if (( src_here )); then
    umount "$probe_src_mp" 2>/dev/null || true
    rmdir "$probe_src_mp" 2>/dev/null || true
  fi

  umount "$probe_mp" 2>/dev/null || true
  rmdir "$probe_mp" 2>/dev/null || true

  nbd_release "$nbd" 2>/dev/null || true

  if (( verdict != 0 )); then
    _MIG_RESUME_DELTA=0
    return 1
  fi

  return 0
}

# ── Smart size estimation ──
estimate_image_size() {
  local src="$1" fmt="${2:-qcow2}" compressed="${3:-false}"
  local src_size; src_size="$(bytes_of_src "$src" 2>/dev/null || echo 0)"
  [[ "$fmt" == "raw" ]] && { echo "$src_size"; return 0; }

  # Build list of filesystems to measure: partitions, or bare device
  local -a targets=()
  if [[ -b "$src" && "$(lsblk -no TYPE "$src" 2>/dev/null)" == "part" ]]; then
    targets=("$src")
  elif [[ -b "$src" ]]; then
    while IFS= read -r p; do [[ -b "$p" ]] && targets+=("$p"); done \
      < <(lsblk -nrpo NAME,TYPE "$src" 2>/dev/null | awk '$2=="part"{print $1}')
  fi
  (( ${#targets[@]} == 0 )) && [[ -b "$src" ]] && targets=("$src")

  local used=0 measured=0 counted=0
  local p fsz pused mnt
  for p in "${targets[@]}"; do
    fsz="$(blockdev --getsize64 "$p" 2>/dev/null || echo 0)"

    # 1) already mounted → read df directly
    if mountpoint -q "$p" 2>/dev/null; then
      pused="$(df -B1 "$p" 2>/dev/null | awk 'NR==2 {print $3}')"
      if [[ "$pused" =~ ^[0-9]+$ && "$pused" -gt 0 ]]; then
        used=$((used + pused)); counted=$((counted + 1)); continue
      fi
    fi

    # 2) not mounted → temporary READ-ONLY probe mount
    mnt="$(mktemp -d)"
    if mount_ro_fs "$p" "$mnt" true; then
      pused="$(df -B1 "$mnt" 2>/dev/null | awk 'NR==2 {print $3}')"
      umount "$mnt" 2>/dev/null || true
      rmdir "$mnt" 2>/dev/null || true
      if [[ "$pused" =~ ^[0-9]+$ && "$pused" -gt 0 ]]; then
        used=$((used + pused)); counted=$((counted + 1)); continue
      fi
    else
      umount "$mnt" 2>/dev/null || true
      rmdir "$mnt" 2>/dev/null || true
    fi

    # 3) unmeasurable (swap/LVM/unknown fs) → conservative: count full size
    used=$((used + fsz)); counted=$((counted + 1))
  done

  if (( counted > 0 && used > 0 )); then
    local unit="partition"; (( counted > 1 )) && unit="partitions"
    echo -e "${CYAN}📊 $src: $(numfmt --to=iec "$used") of actual data found on $counted $unit (+15% overhead)${NC}" >&2
    echo $(( used * 115 / 100 ))
  elif [[ "$compressed" == "true" ]]; then
    warn "Could not measure used space; using compressed-format estimate (40%)." >&2
    echo $(( src_size * 40 / 100 ))
  else
    warn "Could not measure used space; using format estimate (70%)." >&2
    echo $(( src_size * 70 / 100 ))
  fi
}

# ── Per-session nbd slot ownership (safe across parallel terminals) ──
_nbd_stamp() {
  local idx="${1#/dev/nbd}"
  mkdir -p /run/qemu-disk-tool 2>/dev/null || return 0
  echo "$$ ${TTY:-?} $(date +%s)" > "/run/qemu-disk-tool/nbd${idx}.owner" 2>/dev/null || true
}
_nbd_unstamp() {
  local idx="${1#/dev/nbd}"
  rm -f "/run/qemu-disk-tool/nbd${idx}.owner" 2>/dev/null || true
}
_nbd_owned_by_other() {   # true if a LIVE process (another session) claims this slot
  local idx="${1#/dev/nbd}" f pid rest
  f="/run/qemu-disk-tool/nbd${idx}.owner"
  [[ -f "$f" ]] || return 1
  read -r pid rest < "$f" 2>/dev/null || return 1
  [[ "$pid" =~ ^[0-9]+$ ]] || { rm -f "$f"; return 1; }
  (( pid == $$ )) && return 1
  kill -0 "$pid" 2>/dev/null
}

# ── NBD attach + release helpers ──
nbd_attach() {
  local img="$1" ro="${2:-false}"
  local nbd; nbd="$(pick_free_nbd)" || return 1
  if [[ "$ro" == "true" ]]; then qemu-nbd --read-only --connect="$nbd" "$img" || { err "qemu-nbd connect failed"; return 1; }
  else qemu-nbd --connect="$nbd" "$img" || { err "qemu-nbd connect failed"; return 1; }; fi
  # Lost when called via $(…) — such callers MUST also do USED_NBDS+=("$nbd").
  # Kept as the safety net for bare (non-subshell) call sites.
  USED_NBDS+=("$nbd")
  _nbd_stamp "$nbd"
  log "Using $nbd (session PID $$ — other terminals will skip this slot)"
  udevadm settle 2>/dev/null || sleep 0.5
  partprobe "$nbd" 2>/dev/null || true
  udevadm settle 2>/dev/null || sleep 0.3
  echo "$nbd"
}
nbd_release() {
  local nbd="$1"; [[ -n "$nbd" && "$nbd" =~ ^/dev/nbd[0-9]+$ ]] || return 0
  qemu-nbd --disconnect "$nbd" >/dev/null 2>&1 || true
  _nbd_unstamp "$nbd"
  local tmp=() x
  for x in "${USED_NBDS[@]}"; do [[ "$x" != "$nbd" ]] && tmp+=("$x"); done
  USED_NBDS=("${tmp[@]}")
}

# ── Emergency nbd release: kill the server so pending writeback errors out fast ──
# Use ONLY when the image is being discarded (cancel): no flush guaranteed.
nbd_kill() {
  local nbd="$1" p
  [[ -n "$nbd" && "$nbd" =~ ^/dev/nbd[0-9]+$ ]] || return 0
  for p in $(pgrep -f "qemu-nbd.*--connect=${nbd}([[:space:]]|$)" 2>/dev/null); do kill -9 "$p" 2>/dev/null || true; done
  _nbd_unstamp "$nbd"
  local tmp=() x
  for x in "${USED_NBDS[@]}"; do [[ "$x" != "$nbd" ]] && tmp+=("$x"); done
  USED_NBDS=("${tmp[@]}")
}

# Resolve any block device (part/LVM/RAID/mapper) to underlying physical disk(s)
phys_disks_of() {
  local dev="${1#/dev/}"
  local -a stack=("$dev") out=()
  while (( ${#stack[@]} )); do
    local cur="${stack[-1]}"; unset 'stack[-1]'
    local sl="/sys/block/$cur/slaves"
    if [[ -d "$sl" && -n "$(ls -A "$sl" 2>/dev/null)" ]]; then
      local s
      for s in "$sl"/*; do stack+=("$(basename "$s")"); done
    else
      local d="$cur" pk
      pk="$(lsblk -no PKNAME "/dev/$d" 2>/dev/null | head -n1)"
      [[ -n "$pk" ]] && d="$pk"
      out+=("$d")
    fi
  done
  printf '%s\n' "${out[@]}" | sort -u
}

# ── Guard: refuse to write an image onto a filesystem backed by the source device ──
assert_dst_not_on_src() {   # $1=src block device  $2=dst file path
  local src="$1" dst="$2" fs_dev
  fs_dev="$(findmnt -no SOURCE --target "$(dirname "$dst")" 2>/dev/null || true)"
  [[ -b "$fs_dev" ]] || return 0
  local -a sd fd shared
  mapfile -t sd < <(phys_disks_of "$src")
  mapfile -t fd < <(phys_disks_of "$fs_dev")
  mapfile -t shared < <(comm -12 <(printf '%s\n' "${sd[@]}") <(printf '%s\n' "${fd[@]}"))
  if (( ${#shared[@]} )); then
    err "Refusing: destination sits on the same physical disk(s) being read: ${shared[*]}"
    warn "Writing an image onto its own source device causes a runaway self-copy loop."
    return 1
  fi
  return 0
}

# ── Clone-specific overlap guard: part→part on same disk allowed, all real overlap refused ──
assert_clone_safe() {
  local src="$1" target="$2"
  [[ "$src" != "$target" ]] || { err "Source and target are the same device."; return 1; }

  # Containment: either device inside the other (disk → its own partition, etc.)
  local a b pair
  for pair in "$src $target" "$target $src"; do
    a="${pair%% *}"; b="${pair##* }"
    if lsblk -nrpo NAME "$a" 2>/dev/null | grep -Fqx "$b"; then
      err "Refusing: $b is contained inside $a."
      return 1
    fi
  done

  # Physical overlap (LVM/RAID/mapper aware)
  local -a sd td shared
  mapfile -t sd < <(phys_disks_of "$src")
  mapfile -t td < <(phys_disks_of "$target")
  mapfile -t shared < <(comm -12 <(printf '%s\n' "${sd[@]}") <(printf '%s\n' "${td[@]}"))
  if (( ${#shared[@]} )); then
    local st tt
    st="$(lsblk -no TYPE "$src" 2>/dev/null | head -n1)"
    tt="$(lsblk -no TYPE "$target" 2>/dev/null | head -n1)"
    if [[ "$st" == "part" && "$tt" == "part" ]]; then
      warn "Source and target are partitions on the SAME physical disk (${shared[*]})."
      warn "Allowed, but expect slow speeds (read+write on one disk)."
    else
      err "Refusing: source and target overlap on physical disk(s): ${shared[*]}"
      return 1
    fi
  fi
  return 0
}

# ── Assert two devices don't overlap ──
assert_disjoint_devices() {
  local src="$1" target="$2"
  
  # Direct equality check
  [[ "$src" != "$target" ]] || die "Source and target are the same device."
  
  # Precise partition check: one is a partition of the other
  local src_base="${src##*/}" target_base="${target##*/}"
  # /dev/sda → /dev/sda1  (digit suffix)   or   /dev/nbd0 → /dev/nbd0p1  (p-digit suffix)
  if [[ "$target_base" == "${src_base}"[0-9]* || "$target_base" == "${src_base}p"[0-9]* ]]; then
    die "Refusing to operate: $target is a partition of $src."
  fi
  if [[ "$src_base" == "${target_base}"[0-9]* || "$src_base" == "${target_base}p"[0-9]* ]]; then
    die "Refusing to operate: $src is a partition of $target."
  fi
  
  # Parent disk comparison (two partitions on same disk)
  local src_disk target_disk
  src_disk="$(lsblk -no PKNAME "$src" 2>/dev/null || true)"
  target_disk="$(lsblk -no PKNAME "$target" 2>/dev/null || true)"
  
  # If both have the same parent disk, they overlap
  if [[ -n "$src_disk" && -n "$target_disk" && "$src_disk" == "$target_disk" ]]; then
    die "Refusing to operate: $src and $target are on the same physical disk ($src_disk)."
  fi
}

# ── Zero-fill free space on partitions ──
zero_fill_parts() {
  local -a parts=("$@")
  for zp in "${parts[@]}"; do
    local zmnt; zmnt="$(mktemp -d)"
    if mount -o rw "$zp" "$zmnt" 2>/dev/null; then
      log "  Zeroing free space on $zp…"
      dd if=/dev/zero of="$zmnt/.zero_fill" bs=1M status=progress 2>&1 || true
      rm -f "$zmnt/.zero_fill"; sync
      umount "$zmnt" 2>/dev/null || true
    fi
    rmdir "$zmnt" 2>/dev/null || true
  done
}

# ── Partition table backup ──
backup_partition_table() {
  local disk="$1"
  local backup_path="/tmp/pt_backup_$(basename "$disk")_$(date +%s).sgdisk"
  if command -v sgdisk >/dev/null 2>&1; then
    sgdisk -b "$backup_path" "$disk" 2>/dev/null && { echo "$backup_path"; return 0; }
  fi
  return 1
}

# ── Failure hints for device writes ──
print_write_failure_hints() {
  local img="$1" target="$2"
  err "Write failed. Possible causes:"
  echo "  1. If 'Cannot allocate memory': close apps, increase RAM, or use -m 1"
  echo "     Manual: qemu-img convert -p -n -m 1 -O raw \"$img\" \"$target\""
  echo "  2. Check target device health and free space"
  echo "  3. Verify source: qemu-img check \"$img\""
}

# ── Standard operation ending ──
std_ending() {
  local op="$1" src="$2" dst="$3" start_ts="${4:-$(date +%s)}"
  
  # Skip verify on partial images (marked with .incomplete sidecar)
  if [[ -f "${dst}.incomplete" ]]; then
    warn "Image is INCOMPLETE (copy was cancelled or failed)."
    warn "Do not use this image as a VM — it is missing data."
    info "To resume or retry, delete ${dst}.incomplete and re-run the option."
  else
    verify_image "$dst" || warn "Image may have issues."
  fi
  
  write_image_metadata "$dst" "$src" "$op"
  print_summary "$op" "$src" "$dst" "$start_ts"
  pause
}

