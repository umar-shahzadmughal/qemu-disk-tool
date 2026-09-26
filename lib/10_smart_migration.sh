# ============================================================
# Option 10: Smart OS Migration (bootable VM from real drive)
# Detects root/EFI, copies via rsync, installs GRUB, fixes fstab
# Supports incremental resume from a prior partial image
# ============================================================
smart_os_migration() {
  hr
  echo "🚀 Smart OS Migration — Bootable VM from Real Drive"
  hr
  warn "This creates a BOOTABLE qcow2 by copying files (not raw blocks)."
  warn "It detects root/boot/EFI, installs GRUB, and fixes fstab."
  echo

  local tool missing_tool=""
  for tool in qemu-img qemu-nbd rsync parted mkfs.vfat mkfs.ext4 blkid chroot e2fsck; do
    have "$tool" || missing_tool+=" $tool"
  done
  if [[ -n "$missing_tool" ]]; then
    err "Missing required tools:$missing_tool"
    return 1
  fi

  # Globals so cleanup works from any context (hooks, failures, Ctrl+C→EXIT)
  _MIG_NBD="" _MIG_MNT_ROOT="" _MIG_MNT_BOOT="" _MIG_MNT_SRC="" _MIG_MNT_EFI="" _MIG_EFI_OURS=0 _MIG_CLEANED=0 _MIG_SRC_OURS=0 _MIG_FAST=0

  migration_cleanup() {
    [[ "${_MIG_CLEANED:-0}" -eq 1 ]] && return 0
    _MIG_CLEANED=1
    local had_e=0; [[ $- == *e* ]] && had_e=1
    set +e
    local d uopt=""
    (( ${_MIG_FAST:-0} == 1 )) && uopt="-l"

    if [[ -n "${_MIG_MNT_ROOT:-}" ]]; then
      for d in run sys proc dev/pts dev; do umount $uopt "$_MIG_MNT_ROOT/$d" 2>/dev/null; done
    fi
    [[ -n "${_MIG_MNT_BOOT:-}" ]] && umount $uopt "$_MIG_MNT_BOOT" 2>/dev/null
    if [[ -n "${_MIG_MNT_EFI:-}" && "${_MIG_EFI_OURS:-0}" == "1" ]]; then
      umount $uopt "$_MIG_MNT_EFI" 2>/dev/null
      rmdir "$_MIG_MNT_EFI" 2>/dev/null
    fi
    if [[ -n "${_MIG_MNT_SRC:-}" && "${_MIG_SRC_OURS:-0}" == "1" ]]; then
      umount $uopt "$_MIG_MNT_SRC" 2>/dev/null; rmdir "$_MIG_MNT_SRC" 2>/dev/null
    fi
    [[ -n "${_MIG_MNT_ROOT:-}" ]] && { umount $uopt "$_MIG_MNT_ROOT" 2>/dev/null; rmdir "$_MIG_MNT_ROOT" 2>/dev/null; }
    _MIG_MNT_ROOT="" _MIG_MNT_BOOT="" _MIG_MNT_SRC="" _MIG_MNT_EFI="" _MIG_EFI_OURS=0
    if [[ -n "${_MIG_NBD:-}" ]]; then
      if (( ${_MIG_FAST:-0} == 1 )); then
        nbd_kill "$_MIG_NBD"
      else
        nbd_release "$_MIG_NBD"
      fi
    fi
    _MIG_NBD=""
    (( had_e )) && set -e
    return 0
  }
  cleanup_unregister migration_cleanup 2>/dev/null
  register_cleanup migration_cleanup

  # ── Step 1: Source disk ──
  echo
  echo "💽 Step 1: Select the SOURCE disk (the real OS drive)"
  local src_disk
  src_disk="$(pick_block_device disk)"
  if ! maybe_unmount "$src_disk"; then
    warn "Source is mounted (possibly the running system)."
    local live
    live="$(ask_yesno "Continue with a LIVE copy anyway? (boot from Live-USB for best consistency)" "N")"
    [[ "$live" == "true" ]] || { user_cancel; return 1; }
  fi

  # ── Step 2: Scan + detect ──
  echo
  echo "🔍 Step 2: Scanning and detecting OS"
  log "Scanning partitions on $src_disk …"
  local -a parts=() fstypes=() sizes=()
  local p t s f i
  while read -r p t s f; do
    [[ -b "$p" ]] || continue
    [[ "$t" == "part" || "$t" == "lvm" || "$t" == raid* ]] || continue
    parts+=("$p"); sizes+=("$s"); fstypes+=("$f")
  done < <(lsblk -nrpo NAME,TYPE,SIZE,FSTYPE "$src_disk")
  (( ${#parts[@]} )) || { err "No partitions found on $src_disk"; return 1; }

  echo
  echo "📦 Partitions found on $src_disk:"
  for i in "${!parts[@]}"; do
    printf "  [%d] %-12s %-10s %s\n" "$((i+1))" "${parts[$i]}" "${sizes[$i]}" "${fstypes[$i]:-?}"
  done
  echo

  log "Detecting root partition…"
  local root_part="" root_idx=-1 tmp_mnt existing_mp mount_err=""
  for i in "${!parts[@]}"; do
    case "${fstypes[$i]}" in ext4|btrfs|xfs) ;; *) continue ;; esac

    existing_mp="$(findmnt -rn -o TARGET -S "${parts[$i]}" 2>/dev/null | head -n1)"
    if [[ -n "$existing_mp" ]]; then
      if [[ -f "$existing_mp/etc/fstab" ]] && \
         [[ -f "$existing_mp/etc/os-release" || -f "$existing_mp/usr/lib/os-release" || -f "$existing_mp/etc/lsb-release" ]]; then
        root_part="${parts[$i]}"; root_idx=$i
        log "Root partition detected (already mounted at $existing_mp)"
        break
      fi
      continue
    fi

    tmp_mnt="$(mktemp -d)"
    if mount_err="$(mount_ro_fs "${parts[$i]}" "$tmp_mnt" 2>&1)"; then
      if [[ -f "$tmp_mnt/etc/fstab" ]] && \
         [[ -f "$tmp_mnt/etc/os-release" || -f "$tmp_mnt/usr/lib/os-release" || -f "$tmp_mnt/etc/lsb-release" ]]; then
        root_part="${parts[$i]}"; root_idx=$i
      fi
    else
      warn "Could not mount ${parts[$i]} read-only: $(head -n1 <<<"$mount_err")"
    fi
    umount "$tmp_mnt" 2>/dev/null || true
    rmdir "$tmp_mnt" 2>/dev/null || true
    [[ -n "$root_part" ]] && break
  done

  if [[ -z "$root_part" ]]; then
    warn "Could not auto-detect root partition."
    echo
    echo "  Available partitions:"
    for i in "${!parts[@]}"; do
      printf "    [%d] %-12s %-10s %s\n" "$((i+1))" "${parts[$i]}" "${sizes[$i]}" "${fstypes[$i]:-?}"
    done
    echo
    local sel
    read -rp "➡️  Enter partition number for root (1-${#parts[@]}): " sel <"$TTY"
    [[ "$sel" =~ ^[0-9]+$ && "$sel" -ge 1 && "$sel" -le ${#parts[@]} ]] || { err "Invalid selection."; return 1; }
    root_idx=$((sel-1)); root_part="${parts[$root_idx]}"
  fi
  success "Root partition: $root_part (${fstypes[$root_idx]})"

  local boot_part=""
  for i in "${!parts[@]}"; do
    (( i == root_idx )) && continue
    [[ "${fstypes[$i]}" == "vfat" ]] && { boot_part="${parts[$i]}"; break; }
  done
  if [[ -n "$boot_part" ]]; then success "EFI partition: $boot_part → UEFI mode"
  else info "No EFI partition found → BIOS mode"; fi

  # ── Detect separate /boot ──
  # Option 10 currently copies /boot only when it is part of the root filesystem.
  # Refuse a separate /boot rather than silently producing an incomplete VM image.
  local separate_boot_part="" boot_probe_mp="" boot_probe_ours=0
  local boot_mount_source="" boot_fstab_spec="" boot_candidate=""

  boot_probe_mp="$(findmnt -rn -o TARGET -S "$root_part" 2>/dev/null | head -n1)"

  if [[ -z "$boot_probe_mp" ]]; then
    boot_probe_mp="$(mktemp -d)" || {
      err "Cannot create a temporary root probe mount."
      return 1
    }

    if mount_ro_fs "$root_part" "$boot_probe_mp"; then
      boot_probe_ours=1
    else
      rmdir "$boot_probe_mp" 2>/dev/null || true
      boot_probe_mp=""
    fi
  fi

  if [[ -n "$boot_probe_mp" ]]; then
    boot_mount_source="$(findmnt -rn -o SOURCE -T "$boot_probe_mp/boot" 2>/dev/null | head -n1)"

    if [[ -b "$boot_mount_source" &&
          "$boot_mount_source" != "$root_part" &&
          "$boot_mount_source" != "$boot_part" ]]; then
      separate_boot_part="$boot_mount_source"
    fi

    if [[ -z "$separate_boot_part" && -f "$boot_probe_mp/etc/fstab" ]]; then
      boot_fstab_spec="$(
        awk '
          !/^[[:space:]]*#/ && NF >= 2 && $2 == "/boot" {
            print $1
            exit
          }
        ' "$boot_probe_mp/etc/fstab"
      )"

      boot_candidate=""

      case "$boot_fstab_spec" in
        UUID=*)
          local boot_uuid="${boot_fstab_spec#UUID=}"
          boot_candidate="$(blkid -U "$boot_uuid" 2>/dev/null || true)"
          ;;
        PARTUUID=*)
          local boot_partuuid="${boot_fstab_spec#PARTUUID=}"
          boot_candidate="$(
            blkid -t "PARTUUID=$boot_partuuid" -o device 2>/dev/null |
              head -n1
          )"
          ;;
        /dev/*)
          boot_candidate="$(readlink -f "$boot_fstab_spec" 2>/dev/null || true)"
          ;;
        *)
          boot_candidate=""
          ;;
      esac

      if [[ -b "$boot_candidate" &&
            "$boot_candidate" != "$root_part" &&
            "$boot_candidate" != "$boot_part" ]]; then
        separate_boot_part="$boot_candidate"
      fi
    fi
  fi

  if (( boot_probe_ours == 1 )); then
    umount "$boot_probe_mp" 2>/dev/null || true
    rmdir "$boot_probe_mp" 2>/dev/null || true
  fi

  if [[ -n "$separate_boot_part" ]]; then
    err "A separate /boot partition was detected: $separate_boot_part"
    err "Option 10 currently migrates /boot only when it is part of the root filesystem."
    tip "Merge /boot into the root filesystem first, or use a migration path that explicitly copies a separate /boot partition."
    return 1
  fi

  # ── Step 3: Size + output path (+ resume detection) ──
  local root_size root_used="" probe probe_mp=""
  root_size="$(bytes_of_src "$root_part")"
  probe_mp="$(findmnt -rn -o TARGET -S "$root_part" 2>/dev/null | head -n1)"
  if [[ -n "$probe_mp" ]]; then
    root_used="$(df -B1 "$probe_mp" 2>/dev/null | awk 'NR==2 {print $3}')"
  else
    probe="$(mktemp -d)"
    if mount_ro_fs "$root_part" "$probe"; then
      root_used="$(df -B1 "$probe" 2>/dev/null | awk 'NR==2 {print $3}')"
      umount "$probe" 2>/dev/null || true
    fi
    rmdir "$probe" 2>/dev/null || true
  fi

  # Initial/provisional sizing is used only so ask_save_path() can validate
  # the selected destination. For a FRESH build, a real rsync dry-run below
  # replaces this estimate before qemu-img create.
  local src_is_live=0
  [[ -n "$(findmnt -rn -o TARGET -S "$root_part" 2>/dev/null | head -n1)" ]] && src_is_live=1

  local img_size required_space transfer_estimate=""

  if [[ "$root_used" =~ ^[0-9]+$ && "$root_used" -gt 0 ]]; then
    local _over _min_over

    if (( src_is_live )); then
      _over=$(( root_used * 25 / 100 ))
      _min_over=$(( 20*1024*1024*1024 ))
    else
      _over=$(( root_used * 10 / 100 ))
      _min_over=$(( 5*1024*1024*1024 ))
    fi

    (( _over < _min_over )) && _over=$_min_over
    img_size=$(( root_used + _over ))
  else
    img_size=$(( root_size + 512*1024*1024 ))
    warn "Could not measure used space; using conservative provisional virtual size $(numfmt --to=iec "$img_size")."
  fi

  required_space=$(( img_size * 120 / 100 + 3*1024*1024*1024 ))

  info "Provisional root usage: $(numfmt --to=iec "${root_used:-0}") → initial virtual size $(numfmt --to=iec "$img_size")"
  info "Final fresh-build sizing will use an rsync dry-run before the image is created."

  echo
  echo "💾 Step 3: Choose where to save the migrated image"
  local dst="" resume_mode=0
  while true; do
    # defer_existing=true → ask_save_path returns the path without prompting
    # or deleting when a file already exists. We handle resume/overwrite below.
    dst="$(ask_save_path "$(suggest_out_dir)/migrated-os.qcow2" "qcow2" "$required_space" "" "true")" || return 1

    if ! assert_dst_not_on_src "$root_part" "$dst"; then
      tip "Choose an external USB drive or another physical disk — NOT a folder on the source OS."
      continue
    fi

    # No file → fresh build
    [[ -f "$dst" ]] || { resume_mode=0; break; }

    # File exists: probe for resumability
    if _migration_can_resume "$dst" "$src_disk" "$boot_part" "$root_part"; then
      local rans
      rans="$(ask_yesno "Found a resumable image at $dst. Resume incremental copy?" "Y")"
      if [[ "$rans" == "true" ]]; then
        resume_mode=1
        break
      fi
      local ow
      ow="$(ask_yesno "Overwrite the existing image and start fresh?" "N")"
      [[ "$ow" == "true" ]] || continue
      rm -f "$dst"
      resume_mode=0
      break
    else
      warn "Existing file at $dst is not a resumable migration image."
      local ow
      ow="$(ask_yesno "Overwrite it and start fresh?" "N")"
      [[ "$ow" == "true" ]] || continue
      rm -f "$dst"
      resume_mode=0
      break
    fi
  done

  # ── Fresh-build preflight: measure allocated source data ──
  # Resume already performed its own delta probe, so do not walk the source twice.
  if (( resume_mode == 0 )); then
    echo
    log "Measuring allocated source data for target sizing…"

    if ! transfer_estimate="$(_migration_measure_transfer "$root_part" "$boot_part" "$src_is_live")"; then
      err "Could not measure the source's allocated data size safely."
      err "Refusing to start a multi-hour migration with unmeasured target sizing."
      return 1
    fi

    if [[ "$transfer_estimate" =~ ^[0-9]+$ ]]; then
      local measured_need="$transfer_estimate"
      local _over _min_over

      if (( measured_need == 0 )); then
        measured_need="${root_used:-0}"
        warn "Pre-flight reported zero transferable bytes; falling back to measured root usage."
      fi

      if (( src_is_live )); then
        _over=$(( measured_need * 25 / 100 ))
        _min_over=$(( 20*1024*1024*1024 ))
      else
        _over=$(( measured_need * 10 / 100 ))
        _min_over=$(( 5*1024*1024*1024 ))
      fi

      (( _over < _min_over )) && _over=$_min_over
      img_size=$(( measured_need + _over ))
      required_space=$(( img_size * 120 / 100 + 3*1024*1024*1024 ))

      info "Allocated source data estimate: $(numfmt --to=iec "$measured_need")"
      info "Target virtual size: $(numfmt --to=iec "$img_size")"
      info "Required outer-drive free space: $(numfmt --to=iec "$required_space")"

      local final_outer_free
      final_outer_free="$(df -B1 "$(dirname "$dst")" 2>/dev/null | awk 'NR==2 {print $4}')"
      final_outer_free="${final_outer_free:-0}"

      if (( final_outer_free < required_space )); then
        err "Destination filesystem does not have enough free space for the measured migration."
        err "Required: $(numfmt --to=iec "$required_space")"
        err "Available: $(numfmt --to=iec "$final_outer_free")"
        tip "Choose a destination with more free space."
        return 1
      fi
    else
      err "Pre-flight returned an invalid transfer size: $transfer_estimate"
      return 1
    fi
  fi

  # ── Fresh-build inode preflight ──
  # ext4 inode exhaustion can happen even when plenty of bytes remain.
  # Measure source inode usage and reserve ~10% additional inodes for growth.
  local source_inode_used=0 target_inode_count=0

  if (( resume_mode == 0 )); then
    local inode_probe="" inode_probe_ours=0

    inode_probe="$(findmnt -rn -o TARGET -S "$root_part" 2>/dev/null | head -n1)"

    if [[ -z "$inode_probe" ]]; then
      inode_probe="$(mktemp -d)" || {
        err "Cannot create a temporary source inode probe mount."
        return 1
      }

      if mount_ro_fs "$root_part" "$inode_probe"; then
        inode_probe_ours=1
      else
        rmdir "$inode_probe" 2>/dev/null || true
        inode_probe=""
      fi
    fi

    if [[ -z "$inode_probe" ]]; then
      err "Could not mount the source filesystem to measure inode usage."
      return 1
    fi

    source_inode_used="$(
      df -Pi "$inode_probe" 2>/dev/null |
        awk 'NR==2 {print $3}'
    )"

    if [[ ! "$source_inode_used" =~ ^[0-9]+$ || "$source_inode_used" -le 0 ]]; then
      (( inode_probe_ours == 1 )) && umount "$inode_probe" 2>/dev/null || true
      (( inode_probe_ours == 1 )) && rmdir "$inode_probe" 2>/dev/null || true
      err "Could not measure source inode usage safely."
      return 1
    fi

    if (( inode_probe_ours == 1 )); then
      umount "$inode_probe" 2>/dev/null || true
      rmdir "$inode_probe" 2>/dev/null || true
    fi

    local inode_buffer=$(( source_inode_used / 10 + 4096 ))
    target_inode_count=$(( source_inode_used + inode_buffer ))
    (( target_inode_count < 16384 )) && target_inode_count=16384

    info "Source inodes in use: $(numfmt --to=si "$source_inode_used")"
    info "Fresh target inode count: $(numfmt --to=si "$target_inode_count")"
  fi

  local compress_final
  compress_final="$(ask_yesno "🗜️  Compress the final image? (extra pass — slower, typically 30–60% smaller)" "N")"

  # ── Step 4: Build (fresh) or resume ──
  echo
  echo "🏗️  Step 4: Building bootable image (partition → format → copy → GRUB)"
  local start_ts; start_ts="$(date +%s)"

  local nbd="" troot="" tefi="" root_uuid="" new_efi_uuid=""
  local do_fresh=1

  # ── Resume attempt ──
  if (( resume_mode == 1 )); then
    log "Resuming existing image at $dst …"

    if ! _MIG_NBD="$(nbd_attach "$dst" false 2>/dev/null)"; then
      err "Resume: cannot attach the existing image."
      err "The partial image has been kept at: $dst"
      tip "Re-run Option 10 and choose overwrite/start-fresh if the image should be rebuilt."
      migration_cleanup
      return 1
    fi

    USED_NBDS+=("$_MIG_NBD")
    nbd="$_MIG_NBD"

    if [[ -n "$boot_part" ]]; then
      troot="${nbd}p2"
      tefi="${nbd}p1"
    else
      troot="${nbd}p1"
      tefi=""
    fi

    local _w=0
    while [[ ! -b "$troot" && $_w -lt 20 ]]; do
      sleep 0.1
      _w=$((_w+1))
    done

    if [[ ! -b "$troot" ]]; then
      err "Resume: target root partition did not appear."
      err "The existing image has been kept at: $dst"
      migration_cleanup
      return 1
    fi

    _MIG_MNT_ROOT="$(mktemp -d)"

    if ! mount "$troot" "$_MIG_MNT_ROOT" 2>/dev/null; then
      err "Resume: cannot mount the existing target root filesystem."
      err "The existing image has been kept at: $dst"
      migration_cleanup
      return 1
    fi

    if [[ -n "$tefi" ]]; then
      mkdir -p "$_MIG_MNT_ROOT/boot/efi"
      _MIG_MNT_BOOT="$_MIG_MNT_ROOT/boot/efi"

      if ! mount "$tefi" "$_MIG_MNT_BOOT" 2>/dev/null; then
        err "Resume: cannot mount the existing EFI filesystem."
        err "The existing image has been kept at: $dst"
        migration_cleanup
        return 1
      fi
    fi

    root_uuid="$(blkid -s UUID -o value "$troot" 2>/dev/null || true)"
    if [[ -z "$root_uuid" ]]; then
      err "Resume: cannot read the target root filesystem UUID."
      migration_cleanup
      return 1
    fi

    if [[ -n "$tefi" ]]; then
      new_efi_uuid="$(blkid -s UUID -o value "$tefi" 2>/dev/null || true)"
      if [[ -z "$new_efi_uuid" ]]; then
        err "Resume: cannot read the target EFI filesystem UUID."
        migration_cleanup
        return 1
      fi
    fi

    do_fresh=0
    success "Resume: existing image mounted."
  fi

  # ── Fresh build ──
  if (( do_fresh == 1 )); then
    qemu-img create -f qcow2 "$dst" "$img_size" >&2 || { err "qemu-img create failed."; rm -f "$dst"; return 1; }

    _MIG_NBD="$(nbd_attach "$dst" false)" || { err "Failed to attach image."; migration_cleanup; return 1; }
    USED_NBDS+=("$_MIG_NBD")
    nbd="$_MIG_NBD"
    if [[ -n "$boot_part" ]]; then troot="${nbd}p2"; tefi="${nbd}p1"; else troot="${nbd}p1"; fi

    local efi_mib=512
    if [[ -n "$boot_part" ]]; then
      local eb; eb="$(bytes_of_src "$boot_part" 2>/dev/null || echo 0)"
      efi_mib=$(( eb / 1048576 + 64 )); (( efi_mib < 512 )) && efi_mib=512
    fi

    root_uuid=""

    _mig_parted() {
      if [[ -n "$boot_part" ]]; then
        parted -s "$nbd" mklabel gpt || return 1
        parted -s "$nbd" mkpart "EFI" fat32 1MiB "${efi_mib}MiB" || return 1
        parted -s "$nbd" set 1 esp on || true
        parted -s "$nbd" mkpart "ROOT" ext4 "${efi_mib}MiB" 100% || return 1
      else
        parted -s "$nbd" mklabel msdos || return 1
        parted -s "$nbd" mkpart primary ext4 1MiB 100% || return 1
        parted -s "$nbd" set 1 boot on || true
      fi
      partprobe "$nbd" 2>/dev/null || true
      udevadm settle 2>/dev/null || sleep 1
    }
    if ! run_with_spinner "Creating partition table…" _mig_parted; then
      err "Partitioning failed."; migration_cleanup; return 1
    fi

    log "Formatting filesystems…"

    if [[ -n "$tefi" ]]; then
      run_with_spinner "Creating EFI filesystem…" bash -c "mkfs.vfat -F 32 -n EFI '$tefi' >/dev/null"
      local rc=$?
      if (( rc == 130 )); then
        info "Cancelled during mkfs.vfat."
        _MIG_FAST=1; migration_cleanup; rm -f "$dst" 2>/dev/null
        return 1
      elif (( rc != 0 )); then
        err "mkfs.vfat failed (exit $rc)."; migration_cleanup; return 1
      fi
      new_efi_uuid="$(blkid -s UUID -o value "$tefi" 2>/dev/null || true)"
      if [[ -z "$new_efi_uuid" ]]; then
        udevadm settle 2>/dev/null || true
        new_efi_uuid="$(blkid -s UUID -o value "$tefi" 2>/dev/null || true)"
      fi
    fi

    run_with_spinner "Creating ext4 filesystem (can take a minute)…" \
      bash -c "mkfs.ext4 -q -F -m 0 -N '$target_inode_count' '$troot' >/dev/null"
    local rc=$?

    if (( rc == 130 )); then
      info "Cancelled during mkfs.ext4."
      _MIG_FAST=1
      migration_cleanup
      rm -f "$dst" 2>/dev/null
      return 1
    elif (( rc != 0 )); then
      err "mkfs.ext4 failed (exit $rc)."
      migration_cleanup
      return 1
    fi

    root_uuid="$(blkid -s UUID -o value "$troot" 2>/dev/null || true)"

    if [[ -z "$root_uuid" ]]; then
      err "Could not read the newly created target root filesystem UUID."
      migration_cleanup
      return 1
    fi
    [[ -n "$tefi" && -z "$new_efi_uuid" ]] && \
      warn "Could not read EFI UUID after format — /boot/efi fstab entry will stay commented; fix inside the VM."

    _MIG_MNT_ROOT="$(mktemp -d)"
    mount "$troot" "$_MIG_MNT_ROOT" || { migration_cleanup; return 1; }
    if [[ -n "$tefi" ]]; then
      mkdir -p "$_MIG_MNT_ROOT/boot/efi"
      _MIG_MNT_BOOT="$_MIG_MNT_ROOT/boot/efi"
      mount "$tefi" "$_MIG_MNT_BOOT" || { migration_cleanup; return 1; }
    fi
  fi

  # ── Source marker ──
  # Write it only for a fresh build. Resume relies on the existing marker.
  local src_serial
  src_serial="$(lsblk -no SERIAL "$src_disk" 2>/dev/null | head -n1 | tr -d ' ')"

  if (( do_fresh == 1 )) && [[ -n "$src_serial" ]]; then
    echo "$src_serial" > "$_MIG_MNT_ROOT/.migration-src-id" 2>/dev/null || true
  fi

  # ── Source mount ──
  local src_mp
  src_mp="$(findmnt -rn -o TARGET -S "$root_part" 2>/dev/null | head -n1)"
  if [[ -n "$src_mp" ]]; then
    _MIG_MNT_SRC="$src_mp"; _MIG_SRC_OURS=0
    warn "Source root is live-mounted at $src_mp — performing a LIVE copy of the running system."
  else
    _MIG_MNT_SRC="$(mktemp -d)"; _MIG_SRC_OURS=1
    mount_ro_fs "$root_part" "$_MIG_MNT_SRC" || { err "Cannot mount source root read-only."; migration_cleanup; return 1; }
  fi
  # ── Validate target inode capacity before rsync ──
  if (( do_fresh == 1 )); then
    local target_ifree inode_need

    target_ifree="$(
      df -Pi "$_MIG_MNT_ROOT" 2>/dev/null |
        awk 'NR==2 {print $4}'
    )"

    target_ifree="${target_ifree:-0}"

    inode_need=$(( source_inode_used + source_inode_used / 10 + 4096 ))

    if [[ ! "$target_ifree" =~ ^[0-9]+$ || "$target_ifree" -lt "$inode_need" ]]; then
      err "Fresh target filesystem does not have enough free inodes."
      err "Required: approximately $(numfmt --to=si "$inode_need") free inodes"
      err "Available: $(numfmt --to=si "${target_ifree:-0}")"
      tip "The image was formatted with the source inode count plus a safety buffer; do not continue with an undersized inode table."
      migration_cleanup
      rm -f "$dst" 2>/dev/null
      return 1
    fi
  fi

  # ── Verify boot tooling before the long rsync ──
  local missing_target_tools=""
  local mig_tool
  for mig_tool in grub-install update-grub update-initramfs; do
    if [[ ! -x "$_MIG_MNT_SRC/usr/sbin/$mig_tool" &&
          ! -x "$_MIG_MNT_SRC/usr/bin/$mig_tool" &&
          ! -x "$_MIG_MNT_ROOT/usr/sbin/$mig_tool" &&
          ! -x "$_MIG_MNT_ROOT/usr/bin/$mig_tool" ]]; then
      missing_target_tools+=" $mig_tool"
    fi
  done

  if [[ -n "$missing_target_tools" ]]; then
    err "Required bootloader tooling is missing:$missing_target_tools"
    err "Refusing to start the multi-hour filesystem copy."
    tip "Install the required GRUB/initramfs packages on the source OS, then retry."
    migration_cleanup
    (( do_fresh == 1 )) && rm -f "$dst" 2>/dev/null
    return 1
  fi
  # ── File-level rsync (idempotent; on resume skips complete files) ──
  local copy_total rc=0

  if (( resume_mode == 1 )); then
    copy_total="${_MIG_RESUME_DELTA:-0}"
  else
    copy_total="${transfer_estimate:-${root_used:-$root_size}}"
  fi

  PB_EMOJI="🚀"
  PB_DEV="$nbd"
  PB_TOTAL="$copy_total"
  PB_HEADER="$(basename "$src_disk") → $(basename "$dst")"

  if (( resume_mode == 1 )); then
    PB_SUBLINE="incremental copy · $(numfmt --to=iec "$copy_total") delta → qcow2"
  else
    PB_SUBLINE="file-level copy · $(numfmt --to=iec "$copy_total") → qcow2"
  fi

  local -a rs_ex=()
  _migration_build_rsync_excludes "$boot_part" "$src_is_live" rs_ex

  if (( src_is_live )); then
    info "Live source: excluding volatile paths (journal, caches, /var/tmp, crash data) from the copy."
  fi

  local outer_wd_pid="" inner_wd_pid=""
  local wd_fired=0 wd_label="" wd_thr inner_wd_thr
  local outer_free_start inner_free_start

  # ── Outer watchdog: protects the physical filesystem containing qcow2 ──
  # Keep a concrete multi-GiB reserve instead of deriving the threshold from
  # required_space - root_used, which is especially misleading for resume mode.
  wd_thr=$(( 3*1024*1024*1024 ))

  outer_free_start="$(
    df -B1 "$(dirname "$dst")" 2>/dev/null |
      awk 'NR==2 {print $4}'
  )"
  outer_free_start="${outer_free_start:-0}"

  # If the destination starts with little free space, make sure the watchdog
  # threshold is below the current free space so it does not trip immediately.
  if [[ "$outer_free_start" =~ ^[0-9]+$ && "$outer_free_start" -gt 0 ]]; then
    local outer_half=$(( outer_free_start / 2 ))
    (( wd_thr > outer_half )) && wd_thr="$outer_half"
  fi

  (( wd_thr < 512*1024*1024 )) && wd_thr=$(( 512*1024*1024 ))
  (( wd_thr > 8*1024*1024*1024 )) && wd_thr=$(( 8*1024*1024*1024 ))

  # ── Inner watchdog: protects the ext4 filesystem INSIDE the qcow2 ──
  # Reserve enough space for the expected rsync payload plus a 256 MiB
  # emergency cushion. This avoids the old fixed-512-MiB threshold problem
  # on small but otherwise valid resume deltas.
  inner_free_start="$(
    df -B1 "$_MIG_MNT_ROOT" 2>/dev/null |
      awk 'NR==2 {print $4}'
  )"
  inner_free_start="${inner_free_start:-0}"

  local expected_copy_bytes="${copy_total:-0}"
  [[ "$expected_copy_bytes" =~ ^[0-9]+$ ]] || expected_copy_bytes=0

  local inner_reserve=$(( 256*1024*1024 ))

  if (( inner_free_start > expected_copy_bytes + inner_reserve )); then
    inner_wd_thr=$(( inner_free_start - expected_copy_bytes - inner_reserve ))
  else
    inner_wd_thr=$(( inner_free_start / 2 ))
  fi

  (( inner_wd_thr > 2*1024*1024*1024 )) && inner_wd_thr=$(( 2*1024*1024*1024 ))

  if (( inner_free_start > 128*1024*1024 )); then
    (( inner_wd_thr < 64*1024*1024 )) && inner_wd_thr=$(( 64*1024*1024 ))
  fi

  if (( inner_wd_thr >= inner_free_start && inner_free_start > 0 )); then
    inner_wd_thr=$(( inner_free_start / 2 ))
  fi

  (( inner_wd_thr < 1 )) && inner_wd_thr=1

  rm -f "/run/qemu-disk-tool/space-watchdog.$$"

  if ! outer_wd_pid="$(
    start_space_watchdog \
      "$(dirname "$dst")" \
      "$wd_thr" \
      "outer destination filesystem"
  )"; then
    err "Could not start the OUTER destination space watchdog."
    migration_cleanup
    return 1
  fi

  if ! inner_wd_pid="$(
    start_space_watchdog \
      "$_MIG_MNT_ROOT" \
      "$inner_wd_thr" \
      "inner target filesystem"
  )"; then
    err "Could not start the INNER target space watchdog."
    [[ -n "$outer_wd_pid" ]] && kill "$outer_wd_pid" 2>/dev/null || true
    migration_cleanup
    return 1
  fi

  info "Outer destination free at start: $(numfmt --to=iec "$outer_free_start") — watchdog threshold $(numfmt --to=iec "$wd_thr")"
  info "Inner target free at start: $(numfmt --to=iec "$inner_free_start") — watchdog threshold $(numfmt --to=iec "$inner_wd_thr")"

  run_with_progress_bar "Copying root filesystem…" "$copy_total" \
    rsync -aHAXSx --numeric-ids "${rs_ex[@]}" \
      "$_MIG_MNT_SRC/" "$_MIG_MNT_ROOT/" || rc=$?

  [[ -n "$outer_wd_pid" ]] && kill "$outer_wd_pid" 2>/dev/null || true
  [[ -n "$inner_wd_pid" ]] && kill "$inner_wd_pid" 2>/dev/null || true

  unset PB_DEV PB_TOTAL PB_HEADER PB_SUBLINE PB_EMOJI

  if [[ -f "/run/qemu-disk-tool/space-watchdog.$$" ]]; then
    wd_label="$(
      sed -n 's/^label=//p' \
        "/run/qemu-disk-tool/space-watchdog.$$" |
      head -n1
    )"
    rm -f "/run/qemu-disk-tool/space-watchdog.$$"
    wd_fired=1
  fi
  if (( rc == 130 )); then
    if (( wd_fired )); then
      if [[ "$wd_label" == "inner target filesystem" ]]; then
        err "Copy stopped by the space watchdog — the INNER target filesystem inside the qcow2 was approaching ENOSPC."
        err "The partial image has been KEPT at: $dst (NOT bootable)."
        tip "The qcow2 file itself may still have plenty of outer-drive space; the ext4 filesystem inside the image is the limiting resource."
      elif [[ "$wd_label" == "outer destination filesystem" ]]; then
        err "Copy stopped by the space watchdog — the OUTER destination filesystem was approaching ENOSPC."
        err "The partial image has been KEPT at: $dst (NOT bootable)."
        tip "Free space on $(dirname "$dst"), move the image, or choose a different destination."
      else
        err "Copy stopped by the space watchdog — the partial image has been KEPT at: $dst (NOT bootable)."
        tip "Check both the outer destination filesystem and the inner filesystem inside the qcow2."
      fi
      migration_cleanup
    else
      local keep
      keep="$(ask_yesno "Migration cancelled. Keep the partial image for resume later?" "Y")"
      if [[ "$keep" == "true" ]]; then
        info "Partial image kept at: $dst — re-run Option 10 to resume."
        migration_cleanup
      else
        info "Migration cancelled — removing incomplete image."
        _MIG_FAST=1
        migration_cleanup
        rm -f "$dst" 2>/dev/null
      fi
    fi
    return 1
  fi
  if (( rc == 0 && wd_fired )); then
    warn "Destination free space dropped below the safety margin, but the copy COMPLETED — image is intact."
  fi

  if (( rc == 24 )); then
    if (( src_is_live )); then
      warn "rsync reported vanished source files (exit 24) during the LIVE copy."
      warn "This is commonly caused by files being created/deleted while the running system is being copied."
    else
      err "rsync reported vanished source files (exit 24) on a non-live source."
      warn "The partial image has been KEPT at: $dst"
      migration_cleanup
      return 1
    fi
  elif (( rc == 23 )); then
    err "rsync reported a PARTIAL TRANSFER due to one or more copy errors (exit 23)."
    err "The image is not considered bootable."
    warn "The partial image has been KEPT at: $dst"
    tip "Re-run Option 10 and resume after correcting the underlying source/destination error."
    migration_cleanup
    return 1
  elif (( rc == 11 )); then
    local dst_avail dst_size_now inner_avail inner_ifree log_tail=""
    dst_avail="$(
      df -B1 "$(dirname "$dst")" 2>/dev/null |
        awk 'NR==2 {print $4}'
    )"
    dst_avail="${dst_avail:-0}"

    inner_avail="$(
      df -B1 "$_MIG_MNT_ROOT" 2>/dev/null |
        awk 'NR==2 {print $4}'
    )"
    inner_avail="${inner_avail:-0}"

    inner_ifree="$(
      df -Pi "$_MIG_MNT_ROOT" 2>/dev/null |
        awk 'NR==2 {print $4}'
    )"
    inner_ifree="${inner_ifree:-0}"

    dst_size_now="$(stat -c '%s' "$dst" 2>/dev/null || echo 0)"

    if [[ -n "${_PB_LAST_LOG:-}" && -f "${_PB_LAST_LOG:-}" ]]; then
      log_tail="$(
        tr '\r' '\n' < "$_PB_LAST_LOG" 2>/dev/null |
          grep -i 'rsync:' |
          tail -n3
      )"
      rm -f "$_PB_LAST_LOG"
      _PB_LAST_LOG=""
    fi

    err "rsync receiver failed to write (exit 11)."

    if [[ "$log_tail" == *"No space left on device"* ]]; then
      if [[ "$inner_ifree" =~ ^[0-9]+$ && "$inner_ifree" -eq 0 ]]; then
        err "  Cause: The INNER target filesystem ran out of INODES."
        err "  Inner filesystem still has $(numfmt --to=iec "${inner_avail:-0}") bytes free, but no free inodes remain."
        tip "The target ext4 filesystem needs more inodes; a larger image with a suitable inode ratio is required."
      elif [[ "$inner_avail" =~ ^[0-9]+$ && "$inner_avail" -lt 1073741824 ]]; then
        err "  Cause: The VIRTUAL filesystem inside the qcow2 ran out of space."
        err "  Inner target free: $(numfmt --to=iec "${inner_avail:-0}")"
        err "  Outer destination free: $(numfmt --to=iec "${dst_avail:-0}")"

        if (( src_is_live )); then
          err "  This happened during a LIVE source copy — included source data can grow while the migration is running."
          err "  The pre-flight size was measured at the start; later source growth can consume additional target space."
        fi

        tip "Re-run Option 10 and allow it to perform a fresh pre-flight sizing pass with a larger virtual disk."
      elif [[ "$dst_avail" =~ ^[0-9]+$ && "$dst_avail" -lt 10737418240 ]]; then
        err "  Cause: The OUTER physical destination filesystem is full (ENOSPC)."
        err "  Outer destination free: $(numfmt --to=iec "${dst_avail:-0}")"
        tip "Free up space on $(dirname "$dst"), move the image, or choose another destination."
      else
        err "  Cause: ENOSPC was reported, but neither filesystem currently appears full."
        err "  Inner target free: $(numfmt --to=iec "${inner_avail:-0}")"
        err "  Outer destination free: $(numfmt --to=iec "${dst_avail:-0}")"
        [[ -n "$log_tail" ]] && printf '   │ %s\n' "$log_tail" >&2
        tip "Check destination I/O health and investigate filesystem-specific limits."
      fi
    elif [[ "$log_tail" == *"Disk quota exceeded"* ]]; then
      err "  Cause: disk quota exceeded."
    elif [[ "$log_tail" == *"Read-only file system"* ]]; then
      err "  Cause: destination filesystem went read-only (possible drive failure)."
    else
      err "  Cause is NOT clearly disk-full — likely I/O errors or another destination-side write failure."
      [[ -n "$log_tail" ]] && printf '   │ %s\n' "$log_tail" >&2
      tip "Check the health of the destination drive (Option 13) before retrying."
    fi

    err "  Outer destination ($(dirname "$dst")) free now: $(numfmt --to=iec "${dst_avail:-0}")"
    err "  Inner target filesystem free now: $(numfmt --to=iec "${inner_avail:-0}")"
    err "  Partial image size: $(numfmt --to=iec "${dst_size_now:-0}")"

    warn "The partial image has been KEPT at: $dst (NOT bootable — do not use as a VM)."
    migration_cleanup

    if [[ -f "$dst" ]]; then
      local want_check
      want_check="$(ask_yesno "Run integrity check on the partial image? (can take a few minutes)" "Y")"

      if [[ "$want_check" == "true" ]]; then
        log "Running integrity check on the partial image (please wait)…"
        if verify_image "$dst"; then
          info "Partial qcow2 is structurally intact — you can browse/extract files via Option 5."
        else
          warn "Partial image also failed its integrity check."
        fi
      fi
    fi

    return 1
  elif (( rc != 0 )); then
    err "Root copy failed (exit $rc)."
    migration_cleanup; return 1
  fi

  if (( _MIG_SRC_OURS == 1 )); then
    umount "$_MIG_MNT_SRC" 2>/dev/null || true; rmdir "$_MIG_MNT_SRC" 2>/dev/null || true
  fi
  _MIG_MNT_SRC=""

  if [[ -n "$boot_part" ]]; then
    local src_efi_mp
    src_efi_mp="$(findmnt -rn -o TARGET -S "$boot_part" 2>/dev/null | head -n1)"

    if [[ -n "$src_efi_mp" ]]; then
      _MIG_MNT_EFI="$src_efi_mp"
      _MIG_EFI_OURS=0
    else
      _MIG_MNT_EFI="$(mktemp -d)"
      _MIG_EFI_OURS=1

      if ! mount -o ro "$boot_part" "$_MIG_MNT_EFI"; then
        err "Cannot mount the source EFI partition."
        migration_cleanup
        return 1
      fi
    fi

    log "Copying EFI partition…"

    if ! rsync -aAXx --numeric-ids \
      "$_MIG_MNT_EFI/" \
      "$_MIG_MNT_BOOT/"; then
      err "EFI partition copy failed."
      migration_cleanup
      return 1
    fi

    if (( _MIG_EFI_OURS == 1 )); then
      umount "$_MIG_MNT_EFI" 2>/dev/null || true
      rmdir "$_MIG_MNT_EFI" 2>/dev/null || true
    fi

    _MIG_MNT_EFI=""
    _MIG_EFI_OURS=0
  fi

  # ── Fix fstab ──
  log "Fixing /etc/fstab…"
  awk -v ru="$root_uuid" -v eu="$new_efi_uuid" '
    /^[[:space:]]*#/ { print; next }
    NF >= 3 {
      if ($2 == "/") { $1 = "UUID=" ru; $3 = "ext4"; print; next }
      if ($2 == "/boot/efi" && eu != "") { $1 = "UUID=" eu; $3 = "vfat"; print; next }
      if ($3 ~ /^(swap|ext2|ext3|ext4|xfs|btrfs|ntfs|vfat|exfat)$/) { print "#" $0; next }
    }
    { print }
  ' "$_MIG_MNT_ROOT/etc/fstab" > "$_MIG_MNT_ROOT/etc/fstab.new" \
    && mv "$_MIG_MNT_ROOT/etc/fstab.new" "$_MIG_MNT_ROOT/etc/fstab" \
    || warn "fstab rewrite failed — check it inside the VM."

  # ── virtio drivers ──
  log "Adding virtio drivers to initramfs…"
  mkdir -p "$_MIG_MNT_ROOT/etc/initramfs-tools"
  local m
  for m in virtio_pci virtio_blk virtio_net virtio_scsi; do
    grep -qx "$m" "$_MIG_MNT_ROOT/etc/initramfs-tools/modules" 2>/dev/null || echo "$m" >> "$_MIG_MNT_ROOT/etc/initramfs-tools/modules"
  done
  rm -f "$_MIG_MNT_ROOT/etc/initramfs-tools/conf.d/resume"

  # ── GRUB ──
  log "Installing GRUB bootloader…"

  local d
  for d in dev dev/pts proc sys run; do
    mkdir -p "$_MIG_MNT_ROOT/$d"
    mount --bind "/$d" "$_MIG_MNT_ROOT/$d" || { err "Bind mount /$d failed."; migration_cleanup; return 1; }
  done

  if [[ -e /etc/resolv.conf || -L /etc/resolv.conf ]]; then
    cp -L /etc/resolv.conf "$_MIG_MNT_ROOT/etc/resolv.conf.tmp" 2>/dev/null \
      && mv "$_MIG_MNT_ROOT/etc/resolv.conf.tmp" "$_MIG_MNT_ROOT/etc/resolv.conf" 2>/dev/null
  fi

  local grub_rc=0
  local chroot_shell=""

  if [[ -x "$_MIG_MNT_ROOT/bin/bash" ]]; then
    chroot_shell="/bin/bash"
  elif [[ -x "$_MIG_MNT_ROOT/bin/sh" ]]; then
    chroot_shell="/bin/sh"
  else
    err "Target root filesystem has neither /bin/bash nor /bin/sh."
    migration_cleanup
    return 1
  fi

  if [[ -n "$boot_part" ]]; then
    chroot "$_MIG_MNT_ROOT" \
      env -i \
      PATH=/usr/sbin:/usr/bin:/sbin:/bin \
      HOME=/root \
      TERM="${TERM:-linux}" \
      "$chroot_shell" -c "
        set -e
        export DEBIAN_FRONTEND=noninteractive
        update-initramfs -u -k all || update-initramfs -u
        grub-install \
          --target=x86_64-efi \
          --efi-directory=/boot/efi \
          --removable \
          --no-nvram \
          --recheck \
          --force
        update-grub
      " || grub_rc=$?
  else
    chroot "$_MIG_MNT_ROOT" \
      env -i \
      PATH=/usr/sbin:/usr/bin:/sbin:/bin \
      HOME=/root \
      TERM="${TERM:-linux}" \
      "$chroot_shell" -c "
        set -e
        export DEBIAN_FRONTEND=noninteractive
        update-initramfs -u -k all || update-initramfs -u
        grub-install --target=i386-pc --recheck --force '$nbd'
        update-grub
      " || grub_rc=$?
  fi

  if (( grub_rc != 0 )); then
    err "GRUB installation failed (exit $grub_rc)."
    tip "Source needs grub-efi-amd64 (UEFI mode) or grub-pc (BIOS mode) installed."
    migration_cleanup
    return 1
  fi

  # ── Successful → remove the source marker, then clean up ──
  log "Cleaning up…"
  rm -f "$_MIG_MNT_ROOT/.migration-src-id" 2>/dev/null
  migration_cleanup
  cleanup_unregister migration_cleanup

  # ── Optional compression ──
  if [[ "$compress_final" == "true" ]]; then
    local cur_size crc=0 tmp_dir picked=""
    cur_size="$(stat -c '%s' "$dst" 2>/dev/null || echo 0)"
    tmp_dir="$(dirname "$dst")"

    local avail; avail="$(df -B1 "$tmp_dir" 2>/dev/null | awk 'NR==2 {print $4}')"; avail="${avail:-0}"
    if (( avail < cur_size )); then
      warn "Not enough free space at $tmp_dir for the compression pass (need $(numfmt --to=iec "$cur_size"), have $(numfmt --to=iec "$avail"))."
      if has_gui; then
        info "Opening folder picker — choose a location with enough free space."
        picked="$(gui_pick_directory "Choose folder for temporary compressed image")"
      else
        read -rp "✍️  Type a folder with enough free space (or press Enter to skip compression): " picked <"$TTY"
      fi
      [[ -n "$picked" && -d "$picked" ]] && tmp_dir="$picked"
      avail="$(df -B1 "$tmp_dir" 2>/dev/null | awk 'NR==2 {print $4}')"; avail="${avail:-0}"
      if (( avail < cur_size )); then
        warn "Still not enough free space at: $tmp_dir"
        local skip; skip="$(ask_yesno "Skip compression and keep the uncompressed image?" "Y")"
        [[ "$skip" == "true" ]] && compress_final="false"
      fi
    fi

    if [[ "$compress_final" == "true" ]]; then
      local tmp_c="$tmp_dir/$(basename "$dst").compressing"
      run_convert_engine "qcow2" "$dst" "qcow2" "$tmp_c" -c || crc=$?
      if (( crc == 0 )); then
        local src_fs dst_fs
        src_fs="$(stat -c '%d' "$tmp_c" 2>/dev/null || echo 0)"
        dst_fs="$(stat -c '%d' "$(dirname "$dst")" 2>/dev/null || echo 0)"
        if [[ "$src_fs" == "$dst_fs" ]]; then
          mv -f "$tmp_c" "$dst" && \
            success "Image compressed: $(numfmt --to=iec "$(stat -c '%s' "$dst")")" || \
            warn "Rename failed — compressed file kept as: $tmp_c"
        else
          local comp_size; comp_size="$(stat -c '%s' "$tmp_c" 2>/dev/null || echo 0)"
          if ! check_free_space "$(dirname "$dst")" "$comp_size"; then
            warn "No room on the destination filesystem for the compressed image."
            warn "Compressed file kept at: $tmp_c — move it manually."
          elif cp -f "$tmp_c" "${dst}.staging" && mv -f "${dst}.staging" "$dst"; then
            rm -f "$tmp_c"
            success "Image compressed: $(numfmt --to=iec "$(stat -c '%s' "$dst")")"
          else
            rm -f "${dst}.staging" 2>/dev/null
            warn "Copy failed — original intact at $dst, compressed kept at $tmp_c"
          fi
        fi
      elif (( crc == 130 )); then
        rm -f "$tmp_c" 2>/dev/null
        info "Compression cancelled — keeping the uncompressed image."
      else
        rm -f "$tmp_c" 2>/dev/null
        warn "Compression failed (exit $crc) — keeping the uncompressed image."
      fi
    fi
  fi

  echo
  if (( resume_mode == 1 )); then
    success "Smart OS Migration resumed and completed!"
  else
    success "Smart OS Migration complete!"
  fi
  std_ending "Smart OS migration" "$src_disk" "$dst" "$start_ts"
}