# ============================================================
# Option 13: Disk Health Check (HD Sentinel Algorithm)
# Multiplicative health, SSD wear, lifetime estimation, TBW.
# ============================================================
disk_health_check() {
  hr
  echo "🏥 Disk Health Check"
  hr

  local disk
  disk="$(pick_block_device disk)"

  if ! command -v smartctl >/dev/null 2>&1; then
    die "smartctl not found. Install: sudo apt install smartmontools"
  fi

  echo
  log "Analyzing disk: $disk ..."

  # ── Auto-detect device type (handles USB bridges) ──
  local smart_flags=""
  local types=("" "-d sat" "-d sat,12" "-d auto" "-d sntjmicron" "-d sntrealtek")
  for t in "${types[@]}"; do
    if smartctl -i $t "$disk" >/dev/null 2>&1; then
      smart_flags="$t"
      break
    fi
  done

  if ! smartctl -i $smart_flags "$disk" >/dev/null 2>&1; then
     if smartctl -i "$disk" 2>&1 | grep -q "Unknown USB bridge"; then
         warn "USB bridge detected. SMART data is blocked by the enclosure."
         warn "Try connecting the drive directly to SATA/M.2 if possible."
     else
         warn "Cannot read SMART data from this device."
     fi
     pause
     return
  fi

  # ── Get SMART data ──
  local smart_out info_out health_out
  smart_out="$(smartctl -a $smart_flags "$disk" 2>/dev/null || true)"
  info_out="$(smartctl -i $smart_flags "$disk" 2>/dev/null || true)"
  health_out="$(smartctl -H $smart_flags "$disk" 2>/dev/null || true)"

  local model serial fw cap health_res
  model="$(echo "$info_out" | (grep -iE "Device Model|Model Number|Product" || true) | awk -F: '{print $2}' | xargs)"
  serial="$(echo "$info_out" | (grep -iE "Serial Number|Serial number" || true) | awk -F: '{print $2}' | xargs)"
  fw="$(echo "$info_out" | (grep -iE "Firmware Version|Revision" || true) | awk -F: '{print $2}' | xargs)"
  cap="$(echo "$info_out" | (grep -iE "User Capacity|Total NVM Capacity|Namespace 1 Size" || true) | awk -F: '{print $2}' | sed -n 's/.*\[\(.*\)\].*/\1/p' | head -n1 | xargs)"
  [[ -z "$cap" ]] && cap="$(echo "$info_out" | (grep -iE "User Capacity|Total NVM Capacity|Namespace 1 Size" || true) | awk -F: '{print $2}' | awk '{print $1, $2}' | xargs)"
  health_res="$(echo "$health_out" | (grep -i "result" || true) | awk -F: '{print $2}' | xargs)"

  # ── HD SENTINEL AWK ENGINE ──
  local awk_script='
  BEGIN {
    # HD Sentinel weights and limits (default method)
    w[5]=1;    L[5]=70
    w[7]=0.5;  L[7]=20
    w[10]=3;   L[10]=60
    w[196]=0.6; L[196]=30
    w[197]=0.6; L[197]=48
    w[198]=1;  L[198]=70

    hdd_health = 100.0
    is_ssd = 0
    wear = 100
    hours = 0
    temp = -1
    crc = 0
    realloc_raw = 0; pending_raw = 0; uncorrect_raw = 0
    spin_retry_raw = 0; realloc_event_raw = 0
    tbw_raw_241 = -1; tbw_raw_225 = -1
    in_table = 0
  }

  /ID# ATTRIBUTE_NAME/ {
    in_table = 1
    iName = index($0, "ATTRIBUTE_NAME")
    iFlag = index($0, "FLAG")
    iVal  = index($0, "VALUE")
    iWorst = index($0, "WORST")
    iThresh = index($0, "THRESH")
    iType = index($0, "TYPE")
    iWhen = index($0, "WHEN_FAILED")
    iRaw  = index($0, "RAW_VALUE")
    next
  }

  in_table && /^[[:space:]]*$/ { in_table = 0; next }

  in_table {
    if (length($0) < iRaw) next

    id_str = substr($0, 1, iName - 1)
    gsub(/^[ \t]+|[ \t]+$/, "", id_str)
    id = id_str + 0
    if (id <= 0) next

    name = substr($0, iName, iFlag - iName)
    gsub(/^[ \t]+|[ \t]+$/, "", name)

    val_str = substr($0, iVal, iWorst - iVal)
    gsub(/^[ \t]+|[ \t]+$/, "", val_str)
    value = val_str + 0

    raw_str = substr($0, iRaw)
    gsub(/^[ \t]+|[ \t]+$/, "", raw_str)
    match(raw_str, /-?[0-9]+/)
    raw = (RSTART > 0) ? substr(raw_str, RSTART, RLENGTH) + 0 : 0

    # Power-On Hours
    if (id == 9) hours = raw

    # Temperature
    if (id == 194 || id == 190) { if (temp < 0) temp = raw }

    # CRC errors
    if (id == 199) crc = raw

    # TBW attributes
    if (id == 241) tbw_raw_241 = raw
    if (id == 225) tbw_raw_225 = raw

    # Store raw values for reasons
    if (id == 5)   realloc_raw = raw
    if (id == 197) pending_raw = raw
    if (id == 198) uncorrect_raw = raw
    if (id == 10)  spin_retry_raw = raw
    if (id == 196) realloc_event_raw = raw

    # SSD wear attributes (normalized VALUE counts down from 100)
    if (id == 177 || id == 233 || id == 231 || id == 209 || id == 246) {
      is_ssd = 1
      if (value < wear) wear = value
    }

    # HD Sentinel multiplicative health (critical attributes only)
    if (id in w) {
      r = raw % 65536  # lower 16-bit mask
      # Seagate vendor exclusion: skip #7 if raw > 1000 (encoded rate)
      if (id == 7 && r > 1000) next
      if (r > 0) {
        pen = r * w[id]
        if (pen > L[id]) pen = L[id]
        hdd_health *= (100 - pen) / 100
      }
    }
  }

  END {
    # SSD health = min(wear, hdd_health)
    if (is_ssd) {
      health = (wear < hdd_health) ? wear : hdd_health
    } else {
      health = hdd_health
    }
    if (health < 0) health = 0
    if (health > 100) health = 100
    health = int(health)

    # Performance (no penalty without history DB)
    perf = 100

    # Lifetime estimation: (1825 - days) * (health/100)^2
    days = hours / 24
    if (health >= 100) {
      lifetime = 1001  # means "more than 1000"
    } else {
      calc = (1825 - days) * (health / 100) * (health / 100)
      if (calc <= 0 && health < 100) calc = health
      lifetime = int(calc)
      if (lifetime > 1000) lifetime = 1001
      if (lifetime < 0) lifetime = 0
    }

    # TBW
    tbw = -1
    if (is_ssd) {
      if (tbw_raw_241 >= 0) tbw = tbw_raw_241 * 512 / 1099511627776
      else if (tbw_raw_225 >= 0) tbw = tbw_raw_225 * 33554432 / 1099511627776
    }

    # Output as parseable lines
    print "HEALTH=" health
    print "PERF=" perf
    print "LIFETIME=" lifetime
    print "HOURS=" hours
    print "TEMP=" temp
    print "CRC=" crc
    print "IS_SSD=" is_ssd
    print "WEAR=" wear
    print "TBW=" tbw
    print "REALLOC=" realloc_raw
    print "PENDING=" pending_raw
    print "UNCORRECT=" uncorrect_raw
    print "SPIN_RETRY=" spin_retry_raw
    print "REALLOC_EVENT=" realloc_event_raw
  }'

  local smart_data
  smart_data="$(echo "$smart_out" | awk "$awk_script")"

  # Parse awk output into variables
  local health_pct perf lifetime hours temp crc is_ssd wear tbw
  local realloc_raw pending_raw uncorrect_raw spin_retry_raw realloc_event_raw

  health_pct="$(echo "$smart_data" | (grep "^HEALTH=" || true) | cut -d= -f2)"
  perf="$(echo "$smart_data" | (grep "^PERF=" || true) | cut -d= -f2)"
  lifetime="$(echo "$smart_data" | (grep "^LIFETIME=" || true) | cut -d= -f2)"
  hours="$(echo "$smart_data" | (grep "^HOURS=" || true) | cut -d= -f2)"
  temp="$(echo "$smart_data" | (grep "^TEMP=" || true) | cut -d= -f2)"
  crc="$(echo "$smart_data" | (grep "^CRC=" || true) | cut -d= -f2)"
  is_ssd="$(echo "$smart_data" | (grep "^IS_SSD=" || true) | cut -d= -f2)"
  wear="$(echo "$smart_data" | (grep "^WEAR=" || true) | cut -d= -f2)"
  tbw="$(echo "$smart_data" | (grep "^TBW=" || true) | cut -d= -f2)"
  realloc_raw="$(echo "$smart_data" | (grep "^REALLOC=" || true) | cut -d= -f2)"
  pending_raw="$(echo "$smart_data" | (grep "^PENDING=" || true) | cut -d= -f2)"
  uncorrect_raw="$(echo "$smart_data" | (grep "^UNCORRECT=" || true) | cut -d= -f2)"
  spin_retry_raw="$(echo "$smart_data" | (grep "^SPIN_RETRY=" || true) | cut -d= -f2)"
  realloc_event_raw="$(echo "$smart_data" | (grep "^REALLOC_EVENT=" || true) | cut -d= -f2)"

  # Fallbacks
  [[ "$health_pct" =~ ^[0-9]+$ ]] || health_pct=100
  [[ "$perf" =~ ^[0-9]+$ ]] || perf=100
  [[ "$lifetime" =~ ^[0-9]+$ ]] || lifetime=1001
  [[ "$hours" =~ ^[0-9]+$ ]] || hours=0
  [[ "$temp" =~ ^-?[0-9]+$ ]] || temp=-1
  [[ "$is_ssd" =~ ^[0-9]+$ ]] || is_ssd=0
  [[ "$wear" =~ ^[0-9]+$ ]] || wear=100

  # Override if SMART overall test FAILED
  if echo "$health_res" | grep -qi "FAILED"; then
    health_pct=0
  fi

  # ── Build health reasons ──
  local reasons=()
  if (( realloc_raw > 0 )); then reasons+=("$realloc_raw reallocated sectors"); fi
  if (( pending_raw > 0 )); then reasons+=("$pending_raw pending sectors"); fi
  if (( uncorrect_raw > 0 )); then reasons+=("$uncorrect_raw uncorrectable sectors"); fi
  if (( spin_retry_raw > 0 )); then reasons+=("$spin_retry_raw spin retries"); fi
  if (( realloc_event_raw > 0 )); then reasons+=("$realloc_event_raw reallocation events"); fi
  if (( is_ssd == 1 && wear < 100 )); then reasons+=("NAND wear ($wear% remaining)"); fi

  # ── Visual Health Bar ──
  local bar_len=20
  local filled=$(( (health_pct * bar_len) / 100 ))
  local empty=$((bar_len - filled))
  local bar_fill="" bar_empty=""
  for ((i=0; i<filled; i++)); do bar_fill+="█"; done
  for ((i=0; i<empty; i++)); do bar_empty+="░"; done

  local health_color=""
  if ((health_pct >= 91)); then health_color="\033[1;32m"
  elif ((health_pct >= 81)); then health_color="\033[0;32m"
  elif ((health_pct >= 71)); then health_color="\033[1;33m"
  elif ((health_pct >= 61)); then health_color="\033[0;33m"
  elif ((health_pct >= 51)); then health_color="\033[38;5;208m"
  elif ((health_pct >= 41)); then health_color="\033[38;5;202m"
  elif ((health_pct >= 31)); then health_color="\033[0;31m"
  else health_color="\033[1;31m"
  fi

  # ── Assessment ──
  local assess="🟢 Excellent"
  local assess_msg="The drive is healthy and performing well."
  if ((health_pct == 0)) || echo "$health_res" | grep -qi "FAILED"; then
    assess="🔴 Critical"; assess_msg="Drive is failing. Replace immediately."
  elif ((health_pct < 50)); then
    assess="🔴 Poor"; assess_msg="Drive health is severely degraded. Backup and replace."
  elif ((health_pct < 80)); then
    assess="🟡 Caution"; assess_msg="Drive health is degrading. Backup recommended."
  elif ((health_pct < 95)); then
    assess="🟢 Good"; assess_msg="Drive is in good condition."
  fi

  # ── Format lifetime ──
  local lifetime_str
  if (( lifetime >= 1001 )); then
    lifetime_str="More than 1000 days"
  else
    lifetime_str="$lifetime days"
  fi

  # ── Format power-on time ──
  local power_str
  if (( hours > 0 )); then
    local years days
    years="$(awk "BEGIN {printf \"%.1f\", $hours / 8760}")"
    days=$((hours / 24))
    power_str="$hours hours (~$years years / $days days)"
  else
    power_str="N/A"
  fi

  # ── Display ──
  echo
  hr
  echo "  💽 ${model:-Unknown Drive} ($cap)"
  hr
  printf "  %-20s %s\n" "Serial:" "${serial:-N/A}"
  printf "  %-20s %s\n" "Firmware:" "${fw:-N/A}"
  printf "  %-20s %s\n" "Power On:" "$power_str"
  if (( temp >= 0 )); then
    printf "  %-20s %s °C\n" "Temperature:" "$temp"
  else
    printf "  %-20s %s\n" "Temperature:" "N/A"
  fi
  echo
  echo "  ━━━ Health & Performance ━━━"
  printf "  %-20s ${health_color}%d%% [%s%s]${NC}\n" "Health:" "$health_pct" "$bar_fill" "$bar_empty"
  printf "  %-20s %d%%\n" "Performance:" "$perf"
  printf "  %-20s %s\n" "Overall Test:" "${health_res:-Unknown}"
  printf "  %-20s %s\n" "Est. Lifetime:" "$lifetime_str"

  if (( is_ssd == 1 )); then
    if awk "BEGIN {exit ($tbw >= 0) ? 0 : 1}" 2>/dev/null; then
      local tbw_fmt
      tbw_fmt="$(awk "BEGIN {printf \"%.2f\", $tbw}")"
      printf "  %-20s %s TB\n" "Lifetime Writes:" "$tbw_fmt"
    fi
    printf "  %-20s %d%%\n" "NAND Wear:" "$wear"
  fi

  if (( crc > 0 )); then
    echo
    printf "  %-20s %s (old errors, not penalized)\n" "CRC Errors:" "$crc"
  fi

  if ((${#reasons[@]} > 0)); then
    echo
    echo "  ━━━ Health Factors ━━━"
    for r in "${reasons[@]}"; do
      echo "   • $r"
    done
  fi

  echo
  echo "  ━━━ Assessment ━━━"
  echo "  $assess  $assess_msg"
  hr

  # ── Surface Scan ──
  echo
  warn "Surface scan reads the entire disk. This can take hours."
  warn "If Health is 100%, this scan is usually unnecessary."
  echo
  local bb_ans
  read -rp "🔍 Run surface scan anyway? (y/N): " bb_ans <"$TTY"
  bb_ans="${bb_ans:-N}"

  if [[ "${bb_ans,,}" == "y" || "${bb_ans,,}" == "yes" ]]; then
    log "Scanning $disk for bad blocks (Read-Only)…"
    local disk_size
    disk_size="$(blockdev --getsize64 "$disk" 2>/dev/null || echo 0)"
    log "Disk size: $(numfmt --to=iec "$disk_size")"
    echo

    local bad_count=0 start_ts
    start_ts="$(date +%s)"

    local bb_stderr="/tmp/badblocks_stderr_$$.txt"
    local bb_stdout="/tmp/badblocks_stdout_$$.txt"

    badblocks -v -s "$disk" >"$bb_stdout" 2>"$bb_stderr" &
    local bb_pid=$!

    local last_pct=-1
    local bar_width=40
    local bar_fill="" bar_empty=""
    for ((i=0; i<bar_width; i++)); do bar_empty+="░"; done

    while kill -0 "$bb_pid" 2>/dev/null; do
      local pct pct_display
      pct_display="$(tail -c 500 "$bb_stderr" 2>/dev/null | tr '\r' '\n' | (grep -oE '[0-9]+\.[0-9]+% done' || true) | tail -n1 | (grep -oE '[0-9]+\.[0-9]+' || true) | head -n1)"
      pct_display="${pct_display:-0.0}"
      pct="${pct_display%%.*}"
      [[ "$pct" =~ ^[0-9]+$ ]] || pct=0

      local elapsed_str eta_str
      local now elapsed
      now="$(date +%s)"
      elapsed=$((now - start_ts))
      elapsed_str="$(printf '%02d:%02d:%02d' $((elapsed/3600)) $(((elapsed%3600)/60)) $((elapsed%60)))"

      if ((pct > 0)); then
        local eta=$(( (elapsed * 100 / pct) - elapsed ))
        eta_str="$(printf '%02d:%02d:%02d' $((eta/3600)) $(((eta%3600)/60)) $((eta%60)))"
      else
        eta_str="--:--:--"
      fi

      if [[ "$pct" != "$last_pct" ]]; then
        last_pct="$pct"
        local filled_blocks=$(( (pct * bar_width) / 100 ))
        local empty_blocks=$((bar_width - filled_blocks))
        bar_fill="" bar_empty=""
        for ((i=0; i<filled_blocks; i++)); do bar_fill+="█"; done
        for ((i=0; i<empty_blocks; i++)); do bar_empty+="░"; done
      fi

      printf "\r  [%s%s] %5s%%  Elapsed: %s  ETA: %s  " \
        "$bar_fill" "$bar_empty" "$pct_display" "$elapsed_str" "$eta_str"

      sleep 0.5
    done

    wait "$bb_pid" 2>/dev/null || true
    printf "\r  [%s] 100%%  Done!                              \n" "$(printf '█%.0s' $(seq 1 $bar_width))"

    bad_count="$(grep -cE '^[0-9]+$' "$bb_stdout" 2>/dev/null || true)"
    bad_count="${bad_count:-0}"
    rm -f "$bb_stderr" "$bb_stdout"

    local end_ts duration
    end_ts="$(date +%s)"
    duration=$((end_ts - start_ts))

    echo
    hr
    echo "  📊 Surface Scan Results"
    hr
    echo "   Bad sectors: $bad_count"
    echo "   Duration:    $(printf '%02d:%02d:%02d' $((duration/3600)) $(((duration%3600)/60)) $((duration%60)))"
    if [[ "$bad_count" -gt 0 ]]; then
      err "⚠️  Bad sectors found! Drive is failing."
    else
      success "✅ No bad sectors found."
    fi
    hr
  fi

  _write_log "HEALTH" "$disk: $assess ($health_pct%)"
  pause
}