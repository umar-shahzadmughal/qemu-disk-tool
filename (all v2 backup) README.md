════════════════════════════════════════════════════════════════════
QEMU DISK TOOL — PROJECT README (Backup Reference)
════════════════════════════════════════════════════════════════════

1. OVERVIEW
────────────────────────────────────────────────────────────────────
QEMU Disk Tool is a menu-driven, root-level bash utility for complete
disk and VM-image lifecycle management. It wraps qemu-img, qemu-nbd,
partclone, sgdisk, smartctl and friends behind a guided 17-option menu
with safety confirmations, real-time progress bars, automatic
dependency installation (Debian/Ubuntu), and guaranteed cleanup of
NBD devices and mounts on any exit path.

Target users: people who create, convert, migrate, clone, shrink,
repair and restore virtual-machine disk images (qcow2/raw/vmdk/vhdx/
vhd) and physical disks, including bootable OS migration to VMs.


2. FEATURE MENU (17 OPTIONS)
────────────────────────────────────────────────────────────────────
 [1]  🔍 Scan disks/partitions        — inventory with models, serials,
                                        partition trees, usage bars
 [2]  🧱 Create blank VM disk image   — qcow2/raw/vmdk/vhdx/vhd
 [3]  🧊 Image from real disk/part    — backup to image file
 [4]  🔁 Convert image format         — any-to-any + compression
 [5]  🔎 Explore/mount image          — qemu-nbd browse (RO/RW)
 [6]  🧨 Write image to disk/part     — DESTRUCTIVE restore
 [7]  ℹ️  Show image info              — full qemu-img analysis
 [8]  🗑️  Delete image file            — double-confirmed deletion
 [9]  📀 Direct clone disk→disk       — no intermediate file
 [10] 🚀 Smart OS migration           — bootable VM from real drive
                                        (rsync + GRUB + virtio + fstab fix)
 [11] 📦 Smart data-level copy        — partclone used-blocks-only
 [12] 📏 Resize/shrink image          — virtual shrink + compaction
 [13] 🏥 Disk health check            — HD-Sentinel-style SMART scoring
 [14] 🔄 MBR/GPT conversion           — sgdisk with end-gap auto-fix
 [15] 🔧 Repair image/disk/partition  — fs + boot repair (Linux/Windows)
 [16] ❓ Help                          — per-option detailed docs
 [17] 🚪 Exit                          — safe cleanup


3. FILE STRUCTURE
────────────────────────────────────────────────────────────────────
qemu-disk-tool.sh          Main entry: menu loop, module sourcing,
                           root re-exec (sudo -E), trap registration
lib/
  00_common.sh             Shared engine: progress bar, cleanup hooks,
                           pickers, safety helpers, logging, preflight
  01_scan.sh               human_lsblk() — storage inventory
  02_create_blank.sh       create_blank_disk()
  03_image_from_device.sh  create_image_from_device()
  04_convert.sh            convert_image()
  05_explore.sh            explore_mount_image()
  06_write.sh              write_image_to_device()
  07_info.sh               image_info()
  08_delete.sh             delete_image_file()
  09_direct_clone.sh       direct_clone()
  10_smart_migration.sh    smart_os_migration()
  11_smart_data_copy.sh    smart_data_copy() (+ rsync fallback)
  12_resize.sh             resize_image()
  13_health_check.sh       disk_health_check()
  14_mbr_gpt.sh            mbr_gpt_convert()
  15_repair.sh             repair_target() (+ sub-repair functions)
  16_help.sh               show_help() + per-option help pages

Runtime artifacts:
  ~/.qemu-disk-tool.log    Timestamped operation log
  <image>.info             Metadata sidecar (written after create/convert)


4. REQUIREMENTS
────────────────────────────────────────────────────────────────────
OS:      Linux (auto-install tuned for Ubuntu/Debian), root via sudo
Core:    qemu-utils (qemu-img, qemu-nbd), util-linux, kmod (nbd),
         e2fsprogs, parted, gdisk (sgdisk), ntfs-3g, smartmontools,
         partclone, rsync, coreutils (numfmt/dd/truncate), udev
Optional: pv (fast raw copies), zenity (GUI pickers), ms-sys
         (Windows MBR repair — auto-compiled from source if missing)
The preflight check detects missing tools and offers one-command
installation, including compiling ms-sys when no repo package exists.


5. HOW TO RUN
────────────────────────────────────────────────────────────────────
  ./qemu-disk-tool.sh
The tool re-executes itself under sudo when not root (preserving the
TTY variable for interactive prompts). All input is read from /dev/tty
so it works even when piped or run from sudo.


6. ARCHITECTURE HIGHLIGHTS
────────────────────────────────────────────────────────────────────

6.1 GLOBAL PROGRESS BAR ENGINE (run_with_progress_bar)
  • Fork-free loop: /proc/uptime clock, bash-only human-readable
    sizes, printf -v formatting — zero subprocesses per tick.
  • Monochrome dashboard: gapped cells (█ / ─ / fractional ▏▎▍▌▋▊▉),
    "[ XX% ]" prefix, right-aligned stats row, auto-fit terminal
    width (capped at 100 cells).
  • Centered header line: emoji + action verb + src → dst, truncated
    with ellipsis when paths are long.
  • Two progress sources:
      - PB_DEV=<block device> → kernel /sys/block/*/stat write
        counters (true 0.1% smoothness, used by writes/clones)
      - Log parsing fallback → understands qemu-img "(x/100%)",
        dd "bytes copied", badblocks/rsync "N% done"
  • Speed EMA (70/30 blend), stall detection (rate→0 after 5s idle,
    bar advances at most +2% ahead of last real update).
  • Countdown ETA: seeded from first bytes, re-estimated every 5s
    with drop-clamping (max −30s jumps) and 10% rise tolerance.
  • Interrupt-safe: trap kills child with SIGINT, flag forces
    rc=130, prints "Cancelled after HH:MM:SS", restores global trap.
  • Final states: Cancelled / 100.00% full bar / FAILED (exit N).

  Engine contract (env vars set by caller):
    PB_DEV     target block device (kernel-stat mode)
    PB_TOTAL   total bytes for % math and ETA
    PB_HEADER  "src → dst" centered title
    PB_EMOJI   per-option icon (matches menu emoji)

6.2 CLEANUP FRAMEWORK
  • CLEANUP_HOOKS registry: register_cleanup <fn> pushes a function;
    global_cleanup runs hooks LIFO on EXIT, then disconnects all
    USED_NBDS devices, waits, and unloads the nbd module if unused.
  • Global traps: trap global_cleanup EXIT; trap 'exit 130' INT TERM
    (Ctrl+C anywhere exits cleanly through the EXIT trap).
  • nbd_attach / nbd_release standardize connect + USED_NBDS bookkeeping.

6.3 SAFETY LAYER
  • Destructive ops: typed confirmation (confirm_typed with retry and
    cancel words), GUI zenity confirm where available, target lsblk
    detail dump before commit.
  • assert_disjoint_devices: blocks src==target, partition-of-disk
    suffix overlap (sda/sda1, nbd0/nbd0p1), and shared parent disks.
  • maybe_unmount: deep-first unmount of device + children; returns
    gracefully on refusal instead of exiting.
  • check_free_space before every file-producing operation.
  • pick_block_device excludes loop/nbd/nullb/zram/ram/rom devices.

6.4 SECURITY HARDENING (audited)
  • write_image_metadata: quoted heredoc + printf (no shell expansion
    of hostile labels/paths — previous injection vector closed).
  • 01_scan lsblk parsing: pure-regex KEY="VALUE" parser, no eval
    (malicious LABEL="$(...)" stays literal).
  • All df parsing single-call + awk/field-safe extraction.

6.5 SHARED HELPER INVENTORY (00_common.sh)
  Pickers:   pick_block_device, pick_partition_from_device,
             pick_image_from_dir, ask_path_existing_file,
             ask_path_new_file, ask_save_path (GUI+terminal loop with
             gui/cancel keywords, auto-extension, overwrite + space
             checks), pick_free_nbd
  Prompts:   ask_yesno, ask_format_out, ask_compression_opts,
             ask_size (bounded), confirm_typed, user_cancel
  Checks:    check_free_space, estimate_image_size, is_qemu_image,
             is_mounted, verify_image, has_partclone_for, use_pv
  Devices:   nbd_attach, nbd_release, assert_disjoint_devices,
             maybe_unmount, zero_fill_parts, backup_partition_table
  Sizes:     bytes_of_src, img_virtual_bytes, get_total_bytes, fmt_to_ext
  Flow:      run_with_progress_bar, run_convert (engine-wrapped),
             std_ending (verify+metadata+summary+pause),
             print_write_failure_hints
  System:    need_root, preflight_check, check_nbd_module,
             register_cleanup, global_cleanup, pause
  Logging:   log/warn/err/die/success/info + _write_log (timestamped)
  GUI:       has_gui + zenity wrappers (file/dir/save/confirm/warn/error)


7. OPTION 1 (SCAN) OUTPUT SPEC
────────────────────────────────────────────────────────────────────
  • Single lsblk -Pbpo call + single df -k call regardless of disk
    count (2 external commands total).
  • Per-disk header: model, size, GPT/MBR, serial number.
  • Per-partition row, auto-aligned columns sized to the widest value
    on the system AND capped to terminal width (mount/label truncate
    with …): name, size, FSTYPE uppercase, mount point, "label",
    10-cell usage bar [█████░░░░░] NN% used, GREEN free space,
    filesystem emoji at end of line (kept out of aligned columns
    because emoji cell-width is terminal-dependent).
  • Footer: disk count + total capacity.


8. KNOWN LIMITATIONS / DESIGN DECISIONS
────────────────────────────────────────────────────────────────────
  • Ctrl+C always exits the whole tool (intentional for a root disk
    tool — prevents half-finished writes).
  • Size estimates for unmounted sources use 70%/40% heuristics
    (best-effort; partclone exactness would add a hard dependency).
  • Smart OS migration (opt 10) supports Linux sources only.
  • Windows BCD repair (opt 15) guides the user to Windows Recovery
    Media — bcdboot cannot run from Linux.
  • Legacy qemu_img_progress_bar (pty-based) still present for
    backward compatibility; scheduled for removal once every option
    uses the new engine.


9. DEVELOPMENT STATUS
────────────────────────────────────────────────────────────────────
COMPLETED:
  ✅ Progress engine (final polished version)
  ✅ 00_common.sh hardened: security fixes, cleanup hooks, new helper
     inventory, traps, scope cleanup
  ✅ Option 1 rewritten: secure parser, aligned columns, usage bars,
     auto-fit, green free space, BIOS-style icons
  ✅ Full audit of options 2–16: per-file issue lists recorded

RECORDED ISSUES TO FIX DURING OPTION REWRITES:
  • opt2: bare-number size bug, ask_save_path/ask_size adoption
  • opt3: estimate-before-unmount ordering, ask_save_path
  • opt4: dst==src data-loss guard
  • opt5: cleanup hooks instead of trap swapping; whole-device mount
    fallback for bare-filesystem images
  • opt6: set-e-safe rc capture (|| rc=$?)
  • opt9: overlap guard, replace hand-rolled bar with engine (keep pv)
  • opt10: register_cleanup hooks, --no-nvram, numeric validation,
    free-space check, unbound mnt_boot fix
  • opt11: partclone virtual-size semantics (src_size, no pre-mkfs),
    merge two functions, gpt-if->2TB, extension fix on convert fallback
  • opt12: geometry math (start offset + GPT backup header + sgdisk -e),
    partition type-code preservation, raw truncate, e2fsck rc gate
  • opt13: NVMe support branch, engine-wrapped badblocks (-o -b 4096)
  • opt14: hard-fail shrink chain, 2TB enforcement, sgdisk -b backup,
    boot-mode warnings
  • opt15: remove eval, --no-nvram, case-insensitive OS detection,
    cleanup hooks for bind mounts

NEXT PHASE:
  Rewrite options 2 → 16 one by one using the new helpers and the
  standard operation skeleton:
    header → pick source → pick target → safety checks →
    run via engine (PB_EMOJI/PB_DEV/PB_TOTAL/PB_HEADER) →
    post-op (sync/partprobe/verify) → std_ending → pause
  Then delete legacy pty progress code.


10. TESTING NOTES
────────────────────────────────────────────────────────────────────
  • Always test destructive options on throwaway devices first
    (e.g., null_blk test targets or spare USB sticks).
  • After crashes/interrupts, verify no stale NBD connections:
      for d in /dev/nbd[0-9]*; do sudo qemu-nbd --disconnect "$d"; done
  • Log review: ~/.qemu-disk-tool.log
════════════════════════════════════════════════════════════════════
END OF README
════════════════════════════════════════════════════════════════════





════════════════════════════════════════════════════════════════════
lib/00_common.sh — COMPLETE TECHNICAL REFERENCE (Backup Document)
════════════════════════════════════════════════════════════════════

PURPOSE
────────────────────────────────────────────────────────────────────
Single shared library sourced by the main script before any option
runs. Provides: configuration, logging, device/image pickers, GUI
wrappers, safety checks, NBD lifecycle, the global progress engine,
cleanup framework, and all reusable operation helpers. Every option
(01–16) depends on this file. Sourced order matters: this file is
loaded first (00_*), so everything defined here is available to all
later modules.

DEPENDENCY GUARANTEE
────────────────────────────────────────────────────────────────────
Assumes bash with `set -euo pipefail` (set by the main script),
/dev/tty available via $TTY, and root privileges (enforced by
need_root in the main script). All functions are safe under `set -u`
(unbound-variable checking) — every variable is declared `local` or
guarded with ${var:-default}.


════════════════════════════════════════════════════════════════════
SECTION 1 — CONFIGURATION GLOBALS
════════════════════════════════════════════════════════════════════

DEFAULT_OUT_DIR="${HOME}"
    Default directory suggested when saving new images. Falls back to
    $PWD via suggest_out_dir() if this path does not exist.

NBD_MAX=2
    Requested number of nbd devices when loading the module
    (nbds_max parameter). Actual available devices depend on kernel.

USED_NBDS=()
    Array tracking every /dev/nbdX currently connected by this tool.
    Populated by nbd_attach()/pick_free_nbd callers. Consumed and
    cleared by global_cleanup() and nbd_release().

NBD_LOADED_BY_US=0
    Flag: 1 if THIS script loaded the nbd module (so cleanup may
    unload it), 0 if it was already loaded (leave it alone).

LOG_FILE="${HOME}/.qemu-disk-tool.log"
    Append-only timestamped log written by _write_log().

CLEANUP_HOOKS=()
    LIFO stack of function names pushed via register_cleanup().
    Executed newest-first by global_cleanup() before NBD teardown.
    This is how options 5/10/11/12/15 guarantee mount/nbd cleanup
    even when a mid-operation command fails under set -e.


════════════════════════════════════════════════════════════════════
SECTION 2 — NBD MODULE MANAGEMENT
════════════════════════════════════════════════════════════════════

check_nbd_module()
    Verifies the nbd kernel module is loaded and usable.
    Steps:
      1. Checks modprobe exists (kmod package).
      2. If /sys/module/nbd exists: reports who loaded it
         (this script vs. pre-existing).
      3. Otherwise tries: modprobe nbd max_part=16 nbds_max=$NBD_MAX,
         then falls back to `modprobe nbd max_part=16`.
      4. Reads max_part and nbds_max parameters.
      5. FAILS if max_part == 0 (partition support disabled) or
         max_part < 16 — prints fix command.
      6. max_part == 31 is accepted (common kernel rounding of 16).
    Returns: 0 on success, 1 on failure.
    Side effect: sets NBD_LOADED_BY_US=1 when it loads the module.
    Called by: pick_free_nbd() (output redirected to stderr so the
    function's stdout stays clean for returning the device path).


════════════════════════════════════════════════════════════════════
SECTION 3 — PREFLIGHT / AUTO-INSTALL
════════════════════════════════════════════════════════════════════

preflight_check()
    Runs once at startup (from the main script).
    1. Detects distro from /etc/os-release ($ID). Auto-install only
       supported on ubuntu/debian; others get a notice.
    2. REQUIRED tools checked (each shows ✅ version or ❌ missing):
       qemu-img, qemu-nbd, lsblk, findmnt, mount, umount, mountpoint,
       partprobe, dd, truncate, modprobe, udevadm, blockdev, numfmt,
       script, rsync, sgdisk, ntfs-3g, smartctl, resize2fs,
       partclone.ext4, partclone.ntfs
    3. OPTIONAL tools checked (⚠️ if missing, never blocks):
       pv, zenity, ms-sys
    4. If all required present → offer_optional_install(), return 0.
    5. If required missing on ubuntu/debian → maps each tool to its
       apt package (qemu-utils, parted, util-linux, coreutils, kmod,
       udev, rsync, gdisk, ntfs-3g, smartmontools, e2fsprogs,
       partclone), deduplicates, asks user, runs apt-get update +
       install, then RE-VERIFIES every tool. Exits 1 if any still
       missing or if user declines.
    6. Missing on other distros → prints manual-install message,
       exits 1.

    offer_optional_install()  (nested function)
        Only on ubuntu/debian with missing optional tools.
        - pv/zenity → apt packages.
        - ms-sys → compiled from GitHub source (pbatard/ms-sys):
          installs build-essential/unzip/wget if needed, downloads
          master.zip, make, copies bin/ms-sys to /usr/local/bin.
        Local variables: ans, opt_pkgs, install_ms_sys, tmp_dir,
        cwd_save (declared once at function top — no re-declaration).


════════════════════════════════════════════════════════════════════
SECTION 4 — COLORS
════════════════════════════════════════════════════════════════════

RED     = \033[0;31m
YELLOW  = \033[1;33m
GREEN   = \033[0;32m
BLUE    = \033[0;34m
CYAN    = \033[0;36m
NC      = \033[0m      (reset / no color)

The progress engine additionally uses its own local palette:
DIM=\033[90m  WHT=\033[97m  BLD=\033[1;97m  RST=\033[0m
(re-declared before final status output as a safety measure).


════════════════════════════════════════════════════════════════════
SECTION 5 — LOGGING
════════════════════════════════════════════════════════════════════

_write_log LEVEL MESSAGE...
    Appends "[YYYY-MM-DD HH:MM:SS] [LEVEL] message" to $LOG_FILE.
    Failure to write is silently ignored (|| true) so logging never
    breaks an operation.

log MESSAGE      🟦 blue   → level INFO
warn MESSAGE     🟨 yellow → level WARN
err MESSAGE      🟥 red (stderr) → level ERROR
die MESSAGE      err + exit 1  (use only for truly fatal states;
                 prefer return 1 for user-cancellable situations)
success MESSAGE  ✅ green  → level SUCCESS
info MESSAGE     ℹ️  cyan   → level INFO

have CMD
    True if CMD is in PATH (command -v).

ver CMD
    Best-effort version string. Tries `CMD --version`, then `CMD -V`,
    then prints "(installed)". Always single line, never fails.


════════════════════════════════════════════════════════════════════
SECTION 6 — PROGRESS ENGINE INTERNALS (fork-free helpers)
════════════════════════════════════════════════════════════════════

All four helpers avoid subprocesses — critical because the engine
loops every 0.2s.

_pb_sectors_written /dev/xxx
    Reads field 7 (sectors written) from the device's sysfs stat file.
    Search order: /sys/block/<name>/stat, then every
    /sys/block/*/ <name>/stat (finds partitions under their parent).
    Returns: integer string, or rc=1 if unreadable/non-numeric.
    Basis of the PB_DEV kernel-stat progress mode.

_pb_now_ms
    Millisecond clock WITHOUT forking date.
    Primary: /proc/uptime (first field, e.g. "12345.67") →
             seconds*1000 + centiseconds*10.
    Fallback: date +%s%N / 1000000.
    Monotonic enough for elapsed math; the engine also guards against
    backward jumps.

_pb_human BYTES  →  sets global PB_H
    Bytes → human string, pure bash integer math (no numfmt fork):
    ≥1GiB → "X.YGiB", ≥1MiB → "X.YMiB", ≥1KiB → "X.YKiB", else "NB".
    One decimal digit, IEC units.

_pb_hms SECONDS  →  sets global PB_T
    Seconds → "HH:MM:SS" via printf -v (no fork).


════════════════════════════════════════════════════════════════════
SECTION 7 — run_with_progress_bar (THE CORE ENGINE)
════════════════════════════════════════════════════════════════════

SIGNATURE
    run_with_progress_bar DESCRIPTION [TOTAL_BYTES] COMMAND [ARGS...]

CONTRACT
    Runs COMMAND in the background, stdout+stderr captured to a temp
    log, and renders a live 2-line dashboard until it finishes.
    Returns the command's exit code (130 = cancelled by user).

ENVIRONMENT VARIABLES THE CALLER MAY SET (all optional):
    PB_DEV     target block device → kernel write-counter mode
               (smoothest; used for writes/clones to devices)
    PB_TOTAL   total bytes for % and ETA math (overrides TOTAL arg)
    PB_HEADER  dashboard title; "src → dst" is split and rendered
               centered; long paths truncated with …
    PB_EMOJI   icon shown before the action verb (should match the
               option's menu emoji)

HEADER AUTO-ACTION (from DESCRIPTION text, emoji overridable):
    *Writ*/*estor*      → 📥 Writing
    *Convert*           → 🔁 Converting
    *Clon*              → 📀 Cloning
    *Cop*/*igrat*       → 📦 Copying
    otherwise           → 🧰 Processing

GEOMETRY
    cols = $COLUMNS or tput cols or 80.
    bar_width = (cols−14)/2, clamped 20..100.
    Each bar cell is 2 characters ("█ " / "─ " / "▌" cap at the end).
    src/dst truncated to (cols−18)/2 (min 10) characters.
    Header line is centered with computed left padding.

PROGRESS SOURCES
    A) PB_DEV mode (have_dev=1):
       written = (current_sectors − s0) × 512, clamped ≥0.
       pct = written × 10000 / tot   (basis points: 10000 = 100%).
    B) Log-parsing fallback:
       Reads last 400 chars of the log each tick, \r → \n normalized.
       Regex priority:
         1. qemu-img style:  (NN.NN/100%)
         2. badblocks/rsync: NN.NN% done
         3. dd style:        N bytes … copied  → pct from total
         4. generic:         NN.NN%
       Rate (basis-points/ms) updated whenever parsed % advances;
       stalls >5s zero the rate; displayed pct interpolates forward
       but never more than +2.00% beyond the last real value.

SPEED
    EMA: speed = (speed×7 + instantaneous×3) / 10, sampled when
    ≥200ms passed. Unclamped (shows real bursts).

DRAW (every tick, 0.2s sleep)
    Line 1: "  [ XX% ] " + filled cells "█ " + fractional block
            (▏▎▍▌▋▊▉ by eighths) + empty track "─ " + end cap ▌
            (monochrome: white fill, dim track).
    Line 2: right-aligned stats:
            pct% · speed/s · written/total · ⏱ elapsed · ETA hh:mm:ss
    Redraw uses \r + \033[K (erase line) + \033[A (cursor up) so only
    2 lines ever repaint.

ETA (countdown, not re-jumping estimate)
    Seeded at first non-zero written from average speed.
    Then counts down each second. Every 5s re-estimates from overall
    average; if the new estimate is better, ETA drops (clamped to
    −30s per correction); if worse, allowed to rise max +10%.

INTERRUPT HANDLING
    trap '_pb_interrupted=1; kill -INT $pid' INT TERM
    On Ctrl+C: child receives SIGINT, loop exits, wait is skipped,
    rc forced to 130 → "Cancelled after HH:MM:SS" printed.
    Global trap `exit 130` is restored before returning.

FINAL STATES
    rc=130  → "  Cancelled after HH:MM:SS"
    rc=0    → full bar + "[ 100% ]" + final stats row
    other   → "FAILED (exit N) after HH:MM:SS"
    Temp log deleted. Exit code returned to caller.

SET -E SAFETY NOTE
    Callers capturing failure must use:
        local rc=0
        run_with_progress_bar ... || rc=$?
    (a bare call + `local rc=$?` would be aborted by set -e before
    the capture — this was a real bug fixed in Option 6).


════════════════════════════════════════════════════════════════════
SECTION 8 — SIZE HELPERS
════════════════════════════════════════════════════════════════════

bytes_of_src SRC
    Block device → blockdev --getsize64. File → stat -c %s.

img_virtual_bytes IMG
    Extracts "(NNN bytes)" from qemu-img info (the virtual size).

get_total_bytes SRC
    Device → lsblk -bno SIZE. Image → parses "virtual size:" line.
    Used as default total for conversion progress.


════════════════════════════════════════════════════════════════════
SECTION 9 — LEGACY PROGRESS (kept until all options migrate)
════════════════════════════════════════════════════════════════════

qemu_img_progress_bar TOTAL LABEL
    Old stdin-driven renderer for qemu-img -p output via a pty.
    Forks awk/date/numfmt per update. Scheduled for removal.

qemu_img_convert_with_tty_progress TOTAL LABEL CMD...
    Wraps CMD in `script -q -f -e -c` to force a pty so qemu-img
    emits progress, pipes into the legacy renderer. Treats rc=130 as
    user cancel (returns 0). Scheduled for removal.

spinner PID MSG / run_with_spinner MSG CMD...
    Simple |/-\ spinner for operations with no progress output.


════════════════════════════════════════════════════════════════════
SECTION 10 — SESSION BASICS
════════════════════════════════════════════════════════════════════

need_root ARGS...
    If EUID != 0: re-execs the script via `sudo -E TTY=$TTY bash ...`
    preserving arguments and the TTY variable.

pause
    "⏎ Press Enter to continue…" — reads from $TTY, never fails.

user_cancel [MSG]
    info "Cancelled." + return 1. The STANDARD non-fatal abort —
    replaces red `die` for user-initiated cancellations.


════════════════════════════════════════════════════════════════════
SECTION 11 — DEVICE PICKERS
════════════════════════════════════════════════════════════════════

pick_block_device disk|part
    Lists devices via one lsblk call, excludes nbd/loop/nullb/zram/
    ram/rom, shows numbered menu on stderr, returns chosen /dev path
    on stdout. Dies if no devices of the requested type exist.

is_mounted DEV
    True if findmnt finds any mountpoint for DEV.

maybe_unmount DEV
    Collects mountpoints of DEV (and, for disks, of all partitions),
    shows them, asks "Unmount ALL? (y/N)".
      yes → unmounts deepest paths first (length-sorted), returns 0.
      no  → warn + return 1 (GRACEFUL — no longer kills the script).
    Nothing mounted → return 0 silently.


════════════════════════════════════════════════════════════════════
SECTION 12 — GUI (zenity) WRAPPERS
════════════════════════════════════════════════════════════════════

has_gui            zenity installed AND $DISPLAY set
gui_pick_file      file open dialog (+filter)
gui_pick_directory directory dialog
gui_pick_save_file save dialog with confirm-overwrite + default name
gui_confirm        question dialog (rc 0 = yes)
gui_warn / gui_error  warning/error dialogs
All suppress stderr; cancel = empty output / non-zero rc.


════════════════════════════════════════════════════════════════════
SECTION 13 — FILE / IMAGE HELPERS
════════════════════════════════════════════════════════════════════

suggest_out_dir
    $DEFAULT_OUT_DIR if it exists, else $PWD.

is_qemu_image FILE
    File exists AND qemu-img info can read it.

detect_disk_info DEV  (output on stderr)
    Pretty analysis: partition table type (GPT/MBR/none), partition
    list with sizes/fstypes, UEFI hint when a vfat partition exists.

verify_image IMG
    Runs qemu-img check; passes if rc=0 and no "corrupt" in output.
    File missing → pass (returns 0). Returns 1 + prints report on
    problems.

detect_img_format IMG
    Parses "file format:" from qemu-img info.


════════════════════════════════════════════════════════════════════
SECTION 14 — IMAGE PATH PICKERS
════════════════════════════════════════════════════════════════════

pick_image_from_dir DIR
    Finds supported images (qcow2/raw/img/vmdk/vhdx/vhd by extension),
    verifies each with qemu-img, shows numbered list with format +
    virtual size, returns the chosen path. Dies if none found.

ask_path_existing_file PROMPT
    GUI file picker first (if has_gui); on cancel falls back to a
    terminal loop. Accepts: a file (validated with is_qemu_image) or
    a DIRECTORY (opens pick_image_from_dir). Loops until valid.

ask_path_new_file PROMPT
    Terminal loop for a new file path: parent dir must exist; if the
    file already exists, asks overwrite (y/N). Returns the path.


════════════════════════════════════════════════════════════════════
SECTION 15 — FORMAT / OPTION PROMPTS
════════════════════════════════════════════════════════════════════

ask_format_out
    Menu 1-5 → qcow2 / raw / vmdk / vhdx / vpc. Prints the format
    name on stdout.

ask_compression_opts ARRAY_NAME  (nameref)
    Menu for qcow2 compression; appends qemu-img flags to caller's
    array: [1] -c (zlib)  [2] -c -o compression_type=zstd  [3] none.
    NOTE: -c is only valid for `qemu-img convert`, not create.

ask_yesno PROMPT [DEFAULT=N]
    Loops until y/n; echoes "true" or "false" on stdout.

fmt_to_ext FORMAT
    qcow2→qcow2, raw→img, vmdk→vmdk, vhdx→vhdx, vpc/vhd→vhd.


════════════════════════════════════════════════════════════════════
SECTION 16 — CONVERT WRAPPERS
════════════════════════════════════════════════════════════════════

run_convert IN_FMT SRC OUT_FMT DST [EXTRA_OPTS...]
    Legacy wrapper: builds qemu-img convert -p and runs it through
    run_with_progress_bar (log-parse mode). Kept for compatibility.

run_convert_engine SRC_FMT SRC DST_FMT DST [TOTAL] [EXTRA...]
    New standard wrapper: auto-derives total via get_total_bytes when
    not given, sets PB_TOTAL + PB_HEADER="src → dst", runs through
    the engine, unsets the vars, returns the engine's rc.


════════════════════════════════════════════════════════════════════
SECTION 17 — NBD LIFECYCLE
════════════════════════════════════════════════════════════════════

pick_free_nbd
    Calls check_nbd_module (on stderr — returns 1 now, no longer
    exits), udevadm settle, then scans /dev/nbd* for a device whose
    sysfs size is 0 (= free). Prints it on stdout. Returns 1 with a
    cleanup hint if none free.

pick_partition_from_device DISK
    Lists partitions of DISK with size/fstype/mountpoints, numbered
    menu; also accepts a typed /dev path. Warns + returns 1 (graceful)
    when DISK is not a block device or has no partitions.

nbd_attach IMG [ro=false]
    STANDARD connect helper: pick_free_nbd → qemu-nbd --connect
    (--read-only when ro=true) → USED_NBDS+= → udevadm settle →
    partprobe → settle → prints nbd path. Returns 1 on any failure.

nbd_release NBD
    Disconnects NBD and removes it from USED_NBDS. Safe on empty or
    invalid input (returns 0).


════════════════════════════════════════════════════════════════════
SECTION 18 — CLEANUP FRAMEWORK
════════════════════════════════════════════════════════════════════

register_cleanup FN        push FN onto CLEANUP_HOOKS
cleanup_unregister FN      remove FN (after successful manual cleanup)

global_cleanup
    1. set +e (cleanup must never abort).
    2. Runs CLEANUP_HOOKS LIFO (newest first), errors ignored.
    3. Disconnects every USED_NBDS device still connected.
    4. Clears arrays, sleeps 0.5s for settle.
    5. If no nbd device remains in use → modprobe -r nbd.

TRAPS (registered right after global_cleanup definition):
    trap global_cleanup EXIT        — cleanup on ANY exit path
    trap 'exit 130' INT TERM        — Ctrl+C/kill → clean exit code,
                                      EXIT trap then runs cleanup.
    DESIGN DECISION: Ctrl+C always exits the whole tool (correct for
    a root disk tool — prevents half-finished writes).


════════════════════════════════════════════════════════════════════
SECTION 19 — METADATA & SUMMARY
════════════════════════════════════════════════════════════════════

write_image_metadata IMG [SRC] [NOTES]
    Creates IMG.info sidecar: generation time, file, format, virtual
    size, on-disk bytes, source device, hostname, user, partition
    listing, notes.
    SECURITY: heredoc body is quoted ('METAEOF'); all dynamic values
    appended via printf with explicit arguments → hostile labels or
    paths can never execute code (injection vector closed).

print_summary OP SRC DST START_TS
    End-of-operation report: operation, source/dest with sizes
    (blockdev for devices, stat for files), duration HH:MM:SS.
    Also writes a SUMMARY log line.


════════════════════════════════════════════════════════════════════
SECTION 20 — PARTCLONE & PV INTEGRATION
════════════════════════════════════════════════════════════════════

get_partclone_tool FSTYPE
    ext*→partclone.ext4, ntfs→partclone.ntfs, fat*→partclone.fat32,
    exfat/btrfs/xfs → their tools, unknown → "".

has_partclone_for FSTYPE
    Tool exists AND is installed.

use_pv          pv is installed.

pv_copy_with_progress SRC DST SIZE
    pv -s SIZE when available, else dd bs=4M status=progress.


════════════════════════════════════════════════════════════════════
SECTION 21 — PHASE-1 STANDARD HELPERS (refactor additions)
════════════════════════════════════════════════════════════════════

confirm_typed WORD PROMPT [allow_empty=false]
    Retry-loop typed confirmation. Accepts exact WORD; cancel/q/quit/
    c/abort → user_cancel (return 1). With allow_empty=true, bare
    Enter also aborts. Returns 0 on match.

ask_size PROMPT [MIN=1MiB] [MAX=64TiB]
    Validated size input: non-empty, number+optional K/M/G/T suffix,
    parseable by numfmt, within bounds (shows the bounds). Echoes the
    validated size string.

check_free_space DIR NEED_BYTES
    df -B1 on DIR; fails with Need/Available report when insufficient.

ask_save_path DEFAULT_PATH [EXT] [EST_BYTES]
    THE standard save-path loop (replaces 7 hand-written copies):
      • Opens GUI save dialog once (if has_gui); on cancel prints a
        notice and falls back to terminal.
      • Terminal accepts: path, bare filename (→ default dir), empty
        (= remembered path), "gui" (reopen dialog), cancel/q/abort.
      • Auto-appends .EXT when missing.
      • Validates parent dir exists, asks overwrite on existing file,
        runs check_free_space when EST_BYTES > 0.
      • Loops until fully confirmed; echoes final path; return 1 on
        cancel.

estimate_image_size SRC [FMT=qcow2] [COMPRESSED=false]
    Best-effort output-size estimate:
      raw            → full source size.
      mounted source → used blocks × 115% (metadata buffer).
      disk: sums used space of all MOUNTED partitions (same rule).
      fallback       → 40% of source (compressed) / 70% (normal).
    Known limitation: unmounted partitions fall back to percentages.

assert_disjoint_devices SRC TARGET
    Blocks operations where the devices overlap:
      1. exact equality,
      2. partition suffix: sda↔sda1, nbd0↔nbd0p1 (digit or p+digit),
      3. shared parent disk via lsblk PKNAME.
    Dies with a precise reason on any overlap.

zero_fill_parts PART...
    Mounts each partition rw, fills free space with dd zeros
    (.zero_fill file), removes it, syncs, unmounts. Used before
    qcow2 compaction so empty blocks collapse.

backup_partition_table DISK
    sgdisk -b snapshot to /tmp/pt_backup_<disk>_<epoch>.sgdisk.
    Echoes the path on success, rc=1 if sgdisk missing/fails.
    Standard pre-mutation backup for PT-modifying ops (12/14/15).

print_write_failure_hints IMG TARGET
    Standard troubleshooting block after a failed device write
    (memory advice incl. the manual -n -m 1 retry command, health
    check, source verification).

std_ending OP SRC DST [START_TS]
    Standard operation close: verify_image → write_image_metadata →
    print_summary → pause.


════════════════════════════════════════════════════════════════════
SECTION 22 — ERROR-HANDLING PHILOSOPHY
════════════════════════════════════════════════════════════════════

die        → only for unrecoverable / invalid-state conditions.
return 1   → user cancellations and recoverable failures
             (maybe_unmount, pick_free_nbd, nbd_attach,
             pick_partition_from_device, ask_save_path, user_cancel).
Caller pattern for engine commands under set -e:
             local rc=0; run_with_progress_bar ... || rc=$?
All log output for prompts/menus goes to stderr where a function must
return data on stdout (pickers, nbd_attach, ask_save_path, etc.).


════════════════════════════════════════════════════════════════════
SECTION 23 — QUICK CALL CHEAT-SHEET (for option rewrites)
════════════════════════════════════════════════════════════════════

src img    : img="$(ask_path_existing_file "📥 Path: ")"
save path  : dst="$(ask_save_path "$default" "$ext" "$est")" || return
size       : size="$(ask_size "📏 Size")"
device     : dev="$(pick_block_device disk)"        # or part
unmount    : maybe_unmount "$dev" || return 1
overlap    : assert_disjoint_devices "$src" "$target"
space      : check_free_space "$dir" "$bytes" || continue
confirm    : confirm_typed "WIPE" "Type WIPE:" || return 1
gui confirm: has_gui && { gui_confirm "…" "…" || return 1; }
nbd        : nbd="$(nbd_attach "$img")" || return 1
             register_cleanup my_cleanup ; … ; nbd_release "$nbd"
progress   : PB_EMOJI=🧨 PB_TOTAL=$n PB_HEADER="$a → $b"
             local rc=0
             run_with_progress_bar "Writing…" "$n" cmd... || rc=$?
             (( rc )) && { print_write_failure_hints …; return 1; }
ending     : std_ending "Op name" "$src" "$dst" "$start_ts"

════════════════════════════════════════════════════════════════════
END OF 00_common.sh REFERENCE
════════════════════════════════════════════════════════════════════