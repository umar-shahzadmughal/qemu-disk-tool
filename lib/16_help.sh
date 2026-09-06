show_help() {
  hr
  echo "🧰 QEMU Disk Tool — Help"
  hr
  echo
  echo "  [1] 🔍 Scan disks/partitions"
  echo "  [2] 🧱 Create NEW blank VM disk image"
  echo "  [3] 🧊 Create image from real disk/partition"
  echo "  [4] 🔁 Convert image format"
  echo "  [5] 🔎 Explore/Mount an image"
  echo "  [6] 🧨 Write image to disk/partition (restore)"
  echo "  [7] ℹ️  Show image info"
  echo "  [8] 🗑️  Delete an image file"
  echo "  [9] 📀 Direct Clone (disk → disk)"
  echo "  [10] 🚀 Smart OS Migration (bootable VM)"
  echo "  [11] 📦 Smart Data-Level Copy (used blocks only)"
  echo "  [12] 📏 Resize/Shrink Image"
  echo "  [13] 🏥 Disk Health Check"
  echo "  [14] 🔄 MBR/GPT Conversion"
  echo "  [15] 🔧 Repair Image / Disk / Partition"
  echo "  [16] ❓ Help (this page)"
  echo "  [17] 🚪 Exit"
  echo
  hr

  local help_choice
  read -rp "📖 Enter option number for detailed help (or press Enter to go back): " help_choice <"$TTY"

  # Empty → go back to main menu immediately
  [[ -z "$help_choice" ]] && return

  # Validate input
  if [[ ! "$help_choice" =~ ^[0-9]+$ ]] || ((help_choice < 1 || help_choice > 17)); then
    warn "Invalid option. Enter 1-17."
    pause
    return
  fi

  # Clear screen and show detailed help (replaces the menu)
  clear

  case "$help_choice" in
    1)  _help_option_1 ;;
    2)  _help_option_2 ;;
    3)  _help_option_3 ;;
    4)  _help_option_4 ;;
    5)  _help_option_5 ;;
    6)  _help_option_6 ;;
    7)  _help_option_7 ;;
    8)  _help_option_8 ;;
    9)  _help_option_9 ;;
    10) _help_option_10 ;;
    11) _help_option_11 ;;
    12) _help_option_12 ;;
    13) _help_option_13 ;;
    14) _help_option_14 ;;
    15) _help_option_15 ;;
    16) _help_option_16 ;;
    17) _help_option_17 ;;
  esac

  pause
}
# ── Detailed help for each option ──

_help_option_1() {
  hr
  echo "🔍 Option 1: Scan Disks & Partitions"
  hr
  echo
  echo "  WHAT IT DOES:"
  echo "    Lists every physical disk and partition connected to your computer."
  echo "    Shows disk model, serial number, size, partition table type (MBR/GPT),"
  echo "    and for each partition: filesystem type, size, and mount point."
  echo
  echo "  WHEN TO USE IT:"
  echo "    • Before ANY operation, to identify which disk is which."
  echo "    • To find the correct /dev/sdX path for your target drive."
  echo "    • To check if a USB drive was detected properly."
  echo
  echo "  IS IT SAFE?"
  echo "    ✅ Yes. This is 100% read-only. It changes nothing on your disks."
  echo
  echo "  EXAMPLE OUTPUT:"
  echo "    💽 /dev/sda  465.8G  GPT  WDC WD5000LPLX-08ZNTT0"
  echo "       /dev/sda1  512M   vfat  (EFI System)"
  echo "       /dev/sda2  465G   ext4  /"
  echo
  echo "  TIP:"
  echo "    Always run this FIRST before doing anything else. It helps you"
  echo "    avoid accidentally selecting the wrong disk in other options."
  echo
}

_help_option_2() {
  hr
  echo "🧱 Option 2: Create NEW Blank VM Disk Image"
  hr
  echo
  echo "  WHAT IT DOES:"
  echo "    Creates a brand-new, empty virtual disk image file."
  echo "    Think of it like buying a brand-new empty hard drive for a VM."
  echo
  echo "  STEP BY STEP:"
  echo "    1. Choose a format:"
  echo "       • qcow2  → Best for QEMU/KVM. Supports snapshots, compression,"
  echo "                  and thin-provisioning (only uses space for actual data)."
  echo "       • raw    → Fastest performance, but uses full size on disk."
  echo "       • vmdk   → For VMware ESXi / Workstation / VirtualBox."
  echo "       • vhdx   → For Microsoft Hyper-V (modern, up to 64TB)."
  echo "       • vhd    → Legacy Microsoft format (required for Azure)."
  echo
  echo "    2. Enter the size (e.g., 50G, 120G, 1T)."
  echo
  echo "    3. Choose where to save the file."
  echo
  echo "  IS IT SAFE?"
  echo "    ✅ Yes. It only creates a new file. No existing data is touched."
  echo
  echo "  TIP:"
  echo "    For most users, choose qcow2. A 120G qcow2 file only uses"
  echo "    ~200KB on your disk until you actually write data into it."
  echo
}

_help_option_3() {
  hr
  echo "🧊 Option 3: Create Image from Real Disk/Partition"
  hr
  echo
  echo "  WHAT IT DOES:"
  echo "    Reads a physical disk or partition and saves it as an image file."
  echo "    This is like making a complete digital copy (backup) of your drive."
  echo
  echo "  TWO MODES:"
  echo "    💽 Whole Disk  → Copies EVERYTHING (partition table + all partitions)."
  echo "                     The resulting image IS bootable."
  echo "    🧩 Partition   → Copies ONLY one partition (data only)."
  echo "                     ⚠️  The resulting image is NOT bootable."
  echo
  echo "  STEP BY STEP:"
  echo "    1. Choose source type (whole disk or partition)."
  echo "    2. Select the source disk/partition from the list."
  echo "    3. Choose output format (qcow2 recommended)."
  echo "    4. Choose where to save the image file."
  echo "    5. Wait for the conversion to complete."
  echo
  echo "  SPACE CHECK:"
  echo "    The tool automatically checks if you have enough free space"
  echo "    before starting. If not, it will warn you and stop."
  echo
  echo "  ⚠️  IMPORTANT:"
  echo "    • The source disk will be unmounted automatically."
  echo "    • Do NOT unplug the source disk during the process."
  echo "    • For best results, run Option 13 (Health Check) first."
  echo
}

_help_option_4() {
  hr
  echo "🔁 Option 4: Convert Image Format"
  hr
  echo
  echo "  WHAT IT DOES:"
  echo "    Converts an existing image file from one format to another."
  echo "    Example: Convert a .qcow2 file to .vmdk for use in VMware."
  echo
  echo "  SUPPORTED CONVERSIONS:"
  echo "    qcow2 ↔ raw ↔ vmdk ↔ vhdx ↔ vhd (all directions)"
  echo
  echo "  STEP BY STEP:"
  echo "    1. Enter the path to your source image file."
  echo "    2. The tool auto-detects the current format."
  echo "    3. Choose the destination format."
  echo "    4. Choose where to save the converted file."
  echo "    5. Wait for conversion to complete."
  echo
  echo "  COMPRESSION:"
  echo "    When converting TO qcow2, you can enable compression."
  echo "    This makes the file smaller but takes slightly longer."
  echo
  echo "  ⚠️  NOTE:"
  echo "    If source and destination format are the same, the tool warns you."
  echo "    This can still be useful for 'recompacting' a fragmented image."
  echo
}

_help_option_5() {
  hr
  echo "🔎 Option 5: Explore/Mount an Image"
  hr
  echo
  echo "  WHAT IT DOES:"
  echo "    Mounts a virtual disk image so you can browse its files"
  echo "    using your file manager, just like a USB drive."
  echo
  echo "  STEP BY STEP:"
  echo "    1. Enter the path to your image file."
  echo "    2. Choose read-only (recommended) or read-write."
  echo "    3. The tool connects the image via qemu-nbd (virtual block device)."
  echo "    4. Select which partition inside the image to mount."
  echo "    5. The partition is mounted to /media/<user>/QEMU_<name>_<timestamp>."
  echo "    6. Open that path in your file manager to browse files."
  echo "    7. Press Enter when done to unmount and disconnect."
  echo
  echo "  READ-ONLY vs READ-WRITE:"
  echo "    🔒 Read-Only  → Safe. You can browse but NOT modify files."
  echo "    ⚠️  Read-Write → You can modify files, but risk corruption"
  echo "                     if you make a mistake. Use with caution."
  echo
  echo "  IS IT SAFE?"
  echo "    ✅ Read-only mode is 100% safe."
  echo "    ⚠️  Read-write mode can corrupt the image if misused."
  echo
  echo "  CLEANUP:"
  echo "    The tool automatically unmounts and disconnects when you press Enter."
  echo "    If the script crashes, run 'sudo qemu-nbd --disconnect /dev/nbdX'"
  echo "    to manually clean up."
  echo
}

_help_option_6() {
  hr
  echo "🧨 Option 6: Write Image to Disk/Partition (Restore)"
  hr
  echo
  echo "  WHAT IT DOES:"
  echo "    Writes an image file BACK to a physical disk or partition."
  echo "    This is the reverse of Option 3 — it restores a backup."
  echo
  echo "  ⚠️  THIS IS DESTRUCTIVE:"
  echo "    ALL DATA on the target disk/partition will be ERASED."
  echo "    The tool requires you to:"
  echo "    1. Type the exact target device path (e.g., /dev/sdb)"
  echo "    2. Type the word WIPE to confirm"
  echo "    This prevents accidental data loss."
  echo
  echo "  STEP BY STEP:"
  echo "    1. Enter the path to your image file."
  echo "    2. Choose target type (whole disk or partition)."
  echo "    3. Select the target disk/partition."
  echo "    4. Confirm by typing the device path and WIPE."
  echo "    5. Wait for the write to complete."
  echo
  echo "  SIZE CHECK:"
  echo "    If the image is LARGER than the target, the tool warns you."
  echo "    Tip: Use Option 12 (Resize/Shrink) to reduce the image first."
  echo
  echo "  VERIFICATION:"
  echo "    The tool verifies the source image before writing."
  echo "    If the image is corrupted, it warns you and asks to continue."
  echo
}

_help_option_7() {
  hr
  echo "ℹ️  Option 7: Show Image Info"
  hr
  echo
  echo "  WHAT IT DOES:"
  echo "    Displays detailed information about a virtual disk image file."
  echo
  echo "  INFORMATION SHOWN:"
  echo "    • File name and full path"
  echo "    • Format (qcow2, raw, vmdk, etc.)"
  echo "    • Virtual size (the size the VM sees)"
  echo "    • Actual size (the real file size on your disk)"
  echo "    • Cluster size and compatibility version"
  echo "    • Compression type (for qcow2)"
  echo "    • Space efficiency percentage (for qcow2)"
  echo
  echo "  INTEGRITY CHECK:"
  echo "    After showing info, you can optionally run an integrity check."
  echo "    This verifies the internal structure of the image file."
  echo "    If issues are found, Option 15 (Repair) can attempt to fix them."
  echo
  echo "  IS IT SAFE?"
  echo "    ✅ Yes. This is 100% read-only."
  echo
}

_help_option_8() {
  hr
  echo "🗑️  Option 8: Delete an Image File"
  hr
  echo
  echo "  WHAT IT DOES:"
  echo "    Permanently deletes a virtual disk image file from your computer."
  echo
  echo "  SAFETY FEATURES:"
  echo "    • Shows file details (name, format, size) before deletion."
  echo "    • Shows the associated .info metadata file (if it exists)."
  echo "    • Requires TWO confirmations:"
  echo "      1. Answer 'Y' to the first prompt."
  echo "      2. Type the word DELETE to confirm."
  echo
  echo "  ⚠️  WARNING:"
  echo "    This action is PERMANENT. The file cannot be recovered."
  echo "    Make sure you have backups before deleting."
  echo
  echo "  METADATA CLEANUP:"
  echo "    If a .info metadata file exists alongside the image,"
  echo "    it is automatically deleted too."
  echo
}

_help_option_9() {
  hr
  echo "📀 Option 9: Direct Clone (Disk → Disk)"
  hr
  echo
  echo "  WHAT IT DOES:"
  echo "    Copies one physical disk/partition DIRECTLY to another."
  echo "    No intermediate image file is created."
  echo "    This is like cloning a hard drive to a new one."
  echo
  echo "  ⚠️  THIS IS DESTRUCTIVE:"
  echo "    ALL DATA on the TARGET disk will be ERASED."
  echo "    The tool requires you to type the target path and CLONE."
  echo
  echo "  STEP BY STEP:"
  echo "    1. Choose source type (whole disk or partition)."
  echo "    2. Select the source disk/partition."
  echo "    3. Choose target type (whole disk or partition)."
  echo "    4. Select the target disk/partition."
  echo "    5. Confirm by typing the target path and CLONE."
  echo "    6. Wait for the clone to complete."
  echo
  echo "  SIZE CHECK:"
  echo "    If the source is LARGER than the target, the tool warns you."
  echo "    Tip: Use Option 11 (Smart Data-Level Copy) for used-blocks-only"
  echo "    copying, which can fit on smaller drives."
  echo
  echo "  SPEED:"
  echo "    If 'pv' is installed, the tool uses it for faster raw copies"
  echo "    with a visual progress bar."
  echo
}

_help_option_10() {
  hr
  echo "🚀 Option 10: Smart OS Migration (Bootable VM)"
  hr
  echo
  echo "  WHAT IT DOES:"
  echo "    Creates a fully bootable VM image from a physical Linux drive."
  echo "    Unlike Option 3 (raw block copy), this copies FILES and then"
  echo "    installs the bootloader, making the image bootable in a VM."
  echo
  echo "  WHAT IT DETECTS AUTOMATICALLY:"
  echo "    • Root partition (where Linux is installed)"
  echo "    • Boot partition (if separate)"
  echo "    • EFI partition (for UEFI systems)"
  echo
  echo "  WHAT IT DOES AUTOMATICALLY:"
  echo "    1. Copies all files using rsync (preserving permissions)."
  echo "    2. Fixes /etc/fstab to match the new virtual disk."
  echo "    3. Adds virtio drivers (for fast VM disk/network access)."
  echo "    4. Installs GRUB bootloader (BIOS or UEFI, auto-detected)."
  echo "    5. Updates initramfs and GRUB configuration."
  echo
  echo "  RESULT:"
  echo "    A .qcow2 image that you can boot directly in QEMU/KVM."
  echo
  echo "  ⚠️  LIMITATIONS:"
  echo "    • Currently supports Linux only."
  echo "    • Windows requires different tools (not supported here)."
  echo "    • The source drive must be unmounted during the process."
  echo
}

_help_option_11() {
  hr
  echo "📦 Option 11: Smart Data-Level Copy (Used Blocks Only)"
  hr
  echo
  echo "  WHAT IT DOES:"
  echo "    Copies ONLY the used blocks of a filesystem, skipping empty space."
  echo "    This creates MUCH smaller images than full block-level copies."
  echo
  echo "  EXAMPLE:"
  echo "    A 500GB disk with only 50GB of data:"
  echo "    • Option 3 (block copy) → ~500GB image"
  echo "    • Option 11 (data copy) → ~50GB image  ← Much smaller!"
  echo
  echo "  HOW IT WORKS:"
  echo "    1. Detects the filesystem type (ext4, NTFS, etc.)."
  echo "    2. Uses 'partclone' to read only used blocks."
  echo "    3. Creates a new image with a formatted partition."
  echo "    4. Restores the used blocks into the new partition."
  echo "    5. Converts to your chosen format (qcow2, raw, vmdk, etc.)."
  echo
  echo "  FALLBACK:"
  echo "    If partclone is not installed, the tool falls back to rsync"
  echo "    (file-level copy), which also skips empty space."
  echo
  echo "  REQUIREMENTS:"
  echo "    • partclone must be installed: sudo apt install partclone"
  echo "    • Supports: ext2/3/4, NTFS, FAT, exFAT, XFS, Btrfs, etc."
  echo
}

_help_option_12() {
  hr
  echo "📏 Option 12: Resize/Shrink Image"
  hr
  echo
  echo "  WHAT IT DOES:"
  echo "    Shrinks a virtual disk image so it can fit on a smaller drive,"
  echo "    or compacts the file to free up space on your host disk."
  echo
  echo "  THREE MODES:"
  echo "    [1] 📉 Virtual Shrink"
  echo "        Shrinks the filesystem and partition INSIDE the image."
  echo "        Use this BEFORE restoring to a smaller physical drive."
  echo
  echo "    [2] 🗜️  Actual File Shrink (Compaction)"
  echo "        Zeroes out empty space and compacts the image file."
  echo "        Use this to free up space on your host disk."
  echo "        (qcow2 only — raw images cannot be compacted)"
  echo
  echo "    [3] 🔄 Both"
  echo "        Runs Virtual Shrink first, then Actual File Shrink."
  echo "        This gives you the smallest possible image file."
  echo
  echo "  SMART SIZE RECOMMENDATION:"
  echo "    The tool scans the filesystem to calculate used data,"
  echo "    then recommends a safe new size using a smart algorithm."
  echo "    You can choose: Minimal, Standard, Generous, or Custom."
  echo
  echo "  SUPPORTED FILESYSTEMS:"
  echo "    • ext2/3/4 (using resize2fs)"
  echo "    • NTFS (using ntfsresize)"
  echo
  echo "  ⚠️  WARNING:"
  echo "    Always backup your image before shrinking."
  echo "    Shrinking is more risky than expanding."
  echo
}

_help_option_13() {
  hr
  echo "🏥 Option 13: Disk Health Check"
  hr
  echo
  echo "  WHAT IT DOES:"
  echo "    Reads the SMART data from a physical disk and calculates"
  echo "    a health percentage (0-100%), similar to HD Sentinel."
  echo
  echo "  INFORMATION SHOWN:"
  echo "    • Drive model, serial number, firmware"
  echo "    • Power-on hours (converted to days)"
  echo "    • Temperature"
  echo "    • Health percentage with color-coded progress bar:"
  echo "      🟢 91-100% = Excellent"
  echo "      🟡 61-90%  = Caution"
  echo "      🔴 0-60%   = Poor/Critical"
  echo "    • Reallocated sectors (retired bad blocks)"
  echo "    • Pending sectors (unstable blocks)"
  echo "    • SMART error log"
  echo
  echo "  OPTIONAL SURFACE SCAN:"
  echo "    You can optionally run a full surface scan using badblocks."
  echo "    ⚠️  This reads the ENTIRE disk and can take HOURS."
  echo "    If SMART shows 100%, the surface scan is usually unnecessary."
  echo
  echo "  USB DRIVE SUPPORT:"
  echo "    The tool auto-detects USB bridges and tries multiple"
  echo "    protocols (sat, auto, sntjmicron, etc.) to read SMART data."
  echo
  echo "  WHEN TO USE IT:"
  echo "    • Before cloning an old drive (to check if it's dying)."
  echo "    • Before buying a used drive."
  echo "    • To monitor the health of your daily-use drives."
  echo
}

_help_option_14() {
  hr
  echo "🔄 Option 14: MBR/GPT Conversion"
  hr
  echo
  echo "  WHAT IT DOES:"
  echo "    Converts the partition table of a disk between MBR and GPT."
  echo "    • MBR → GPT: Needed for drives larger than 2TB or UEFI boot."
  echo "    • GPT → MBR: Needed for older BIOS systems or compatibility."
  echo
  echo "  ⚠️  IMPORTANT:"
  echo "    • This modifies the partition table structure."
  echo "    • BACKUP YOUR DATA BEFORE CONVERTING."
  echo "    • The tool requires you to type the device path and CONVERT."
  echo
  echo "  SMART AUTO-FIX:"
  echo "    GPT requires 33 sectors (16.5KB) of empty space at the END"
  echo "    of the disk for its backup header. If your last partition"
  echo "    touches the end of the disk, the tool AUTOMATICALLY shrinks"
  echo "    it by 2MB to make room. You don't need to do anything."
  echo
  echo "  STEP BY STEP:"
  echo "    1. Select the disk to convert."
  echo "    2. The tool detects the current partition table type."
  echo "    3. Read the warnings carefully."
  echo "    4. Type the device path and CONVERT to confirm."
  echo "    5. The conversion runs and shows the new partition layout."
  echo
  echo "  LIMITATIONS:"
  echo "    • GPT → MBR may fail if you have more than 4 partitions"
  echo "      or partitions larger than 2TB."
  echo
}

_help_option_15() {
  hr
  echo "🔧 Option 15: Repair Image / Disk / Partition"
  hr
  echo
  echo "  WHAT IT DOES:"
  echo "    A comprehensive repair shop that diagnoses and fixes issues"
  echo "    with images, disks, and partitions. Includes boot repair."
  echo
  echo "  FIVE REPAIR MODES:"
  echo
  echo "    [1] 🔍 Full Auto-Repair (Recommended)"
  echo "        Automatically detects the OS (Linux or Windows) and runs"
  echo "        the appropriate boot repair + filesystem repair."
  echo "        Best for: 'My image won't boot, fix everything.'"
  echo
  echo "    [2] 🐧 Linux Boot Repair"
  echo "        Fixes GRUB bootloader, /etc/fstab UUIDs, adds virtio"
  echo "        drivers, and reinstalls GRUB (BIOS or UEFI)."
  echo "        Best for: Linux VM images that won't boot."
  echo
  echo "    [3] 🪟 Windows Boot Repair"
  echo "        Writes Windows MBR, sets boot flags, fixes NTFS errors,"
  echo "        and verifies EFI boot structure."
  echo "        Best for: Windows images that won't boot."
  echo "        Note: For BCD repair, you'll need Windows Recovery Media."
  echo
  echo "    [4] 📦 Filesystem / Image Repair"
  echo "        Runs diagnostics on all partitions: checks filesystem"
  echo "        integrity, size mismatches, and qcow2 structure."
  echo "        Best for: Corrupted filesystems or image errors."
  echo
  echo "    [5] 📂 Single Partition Repair"
  echo "        Repairs just one specific partition."
  echo "        Best for: Quick fix on a single known partition."
  echo
  echo "  WHAT IT CAN FIX:"
  echo "    ✅ Filesystem corruption (ext2/3/4, NTFS, FAT)"
  echo "    ✅ Filesystem/partition size mismatches"
  echo "    ✅ Missing or broken GRUB bootloader"
  echo "    ✅ Wrong UUIDs in /etc/fstab"
  echo "    ✅ Missing virtio drivers for VMs"
  echo "    ✅ Windows MBR/PBR boot records"
  echo "    ✅ Missing boot flags on partitions"
  echo "    ✅ qcow2 image structure errors"
  echo
  echo "  WHAT IT CANNOT FIX:"
  echo "    ❌ Windows BCD store (requires Windows Recovery Media)"
  echo "    ❌ Windows driver injection (requires DISM, Windows-only)"
  echo "    ❌ Physically damaged drives (use Option 13 to detect)"
  echo
}

_help_option_16() {
  hr
  echo "❓ Option 16: Help"
  hr
  echo
  echo "  You're looking at it! 😊"
  echo
  echo "  This page shows a brief overview of all 17 options."
  echo "  Type any option number (1-17) to get detailed help"
  echo "  for that specific option."
  echo
  echo "  Press Enter to go back to the main menu."
  echo
}

_help_option_17() {
  hr
  echo "🚪 Option 17: Exit"
  hr
  echo
  echo "  Safely quits the QEMU Disk Tool."
  echo
  echo "  WHAT HAPPENS ON EXIT:"
  echo "    • All mounted images are unmounted."
  echo "    • All qemu-nbd connections are disconnected."
  echo "    • The nbd kernel module is unloaded (if loaded by this script)."
  echo "    • The log file is saved to the logs/ directory."
  echo
  echo "  You can also exit by pressing Ctrl+C at any time."
  echo "  The cleanup trap will still run and disconnect everything."
  echo
}