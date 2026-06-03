# 🧰 QEMU Disk Tool

<div align="center">

![Bash](https://img.shields.io/badge/Bash-5.0+-green.svg)
![Platform](https://img.shields.io/badge/Platform-Linux%20(Ubuntu%2FDebian)-orange.svg)
![QEMU](https://img.shields.io/badge/QEMU-qcow2%20%7C%20raw%20%7C%20vmdk%20%7C%20vhdx%20%7C%20vhd-red.svg)
![Version](https://img.shields.io/badge/Version-1.0-blue.svg)

**A friendly menu-driven tool to create, convert, mount, and restore QEMU virtual disk images — no commands to memorize**

</div>

---

## 📖 Overview

QEMU Disk Tool is a bash script for anyone who struggles with QEMU's command-line tools. Instead of searching through documentation and typing complex commands, you just run the script, pick an option from the menu, and follow the prompts. It handles everything behind the scenes.

Perfect for beginners who want to:
- Create virtual disks for QEMU/KVM
- Convert between disk formats (qcow2, raw, vmdk, vhdx, vhd)
- Mount virtual disk images to browse or copy files
- Backup real disks or partitions into virtual images
- Restore images back to real disks

All with safe confirmations, pretty progress bars, and automatic cleanup.

---

## ✨ Features

### Disk Operations
- **9 menu-driven operations** — Scan disks, create blank images, image from real disk, convert formats, mount/explore images, write images to disk, show info, delete files
- **5 disk image formats** — qcow2, raw, vmdk, vhdx, vhd (vpc)
- **Whole disk OR partition** operations — Work with entire drives or individual partitions
- **Smart format detection** — Auto-detects source image format, no need to know it
- **qcow2 compression** — Option to compress qcow2 output for smaller files

### Safety Features
- **Read-only mounting** — Explore image contents without risk of corruption
- **Auto filesystem detection** — Mounts ext4, NTFS, vfat, exfat with correct options
- **Double-confirmation for destructive operations** — Must type device path AND "WIPE" to confirm
- **Mount detection** — Warns if target is currently mounted, offers to unmount
- **Partition-level safety** — Pick exact partition to mount, no guessing

### User Experience
- **Friendly menu system** — No commands to learn, just pick numbers
- **Pretty progress bars** — Real-time speed, ETA, and percentage during long operations
- **Storage inventory** — Scan and view all disks/partitions with sizes and models
- **Directory picker** — Browse directories with numbered file selection
- **Auto-cleanup** — Disconnects NBD devices and unmounts on exit or Ctrl+C

### Technical
- **NBD auto-management** — Loads kernel module, checks partition support, picks free device
- **Auto-dependency install** — Detects missing tools and installs them on Ubuntu/Debian
- **Preflight check** — Verifies all required tools before starting
- **TTY-aware** — Works correctly when run with sudo, keeps input working

---

## 🛠️ Built Solo

Designed, developed, and debugged from scratch. Every function, safety check, and menu decision was hand-crafted to make QEMU disk management accessible to beginners.

---

## 📦 Installation

### Prerequisites
- **Linux** (Ubuntu/Debian recommended for auto-install)
- **Root access** (required for disk operations and NBD)

### Step 1: Clone the Repository

```bash
git clone git@github.com:umar-shahzadmughal/qemu-disk-tool.git
cd qemu-disk-tool
```

### Step 2: Make the Script Executable

```bash
chmod +x qemu-disk-tool.sh
```

### Step 3: Run It

```bash
sudo ./qemu-disk-tool.sh
```

### Step 4: First-Time Setup

On first run, the script runs a **Preflight Check** that:
1. Detects your Linux distribution
2. Checks for required tools (qemu-img, qemu-nbd, lsblk, mount, etc.)
3. Checks for optional tools (pv, sgdisk, ntfs-3g)
4. If anything is missing, offers to auto-install on Ubuntu/Debian
5. Verifies the NBD kernel module is loaded with partition support

> **Note:** The script handles everything. No manual package installation needed on Ubuntu/Debian.

### Required Tools (Auto-Installed)

| Tool | Package | Purpose |
|------|---------|---------|
| qemu-img, qemu-nbd | qemu-utils | Disk image creation and NBD connections |
| lsblk, findmnt, mount | util-linux | Device listing and mounting |
| partprobe | parted | Partition table updates |
| dd, truncate | coreutils | Raw file operations |
| modprobe | kmod | Kernel module loading |
| udevadm | udev | Device management |

### Optional Tools (Recommended)

| Tool | Package | Purpose |
|------|---------|---------|
| pv | pv | Alternative progress display |
| sgdisk | gdisk | GPT partition table fixes |
| ntfs-3g | ntfs-3g | NTFS filesystem support |

---

## 🚀 Usage

### Main Menu

When you run the script, you see:

```
🧰 QEMU Disk Tool
────────────────────────────────────────────────────────
What do you want to do?

  [1] 🔍 Scan disks/partitions
  [2] 🧱 Create NEW blank VM disk image
  [3] 🧊 Create image from real disk/partition
  [4] 🔁 Convert image format
  [5] 🔎 Explore/Mount an image (read-only)
  [6] 🧨 Write image to disk/partition (restore)
  [7] ℹ️  Show image info
  [8] 🗑️  Delete an image file
  [9] 🚪 Exit
```

Just type a number and follow the prompts.

### Common Tasks

#### Create a Blank VM Disk
1. Pick option **2**
2. Choose output directory (default: `/`)
3. Enter filename (e.g., `myvm.qcow2`)
4. Enter size (e.g., `50G`, `120G`)
5. Pick format (qcow2 recommended)
6. Optionally enable compression
7. Done — disk is ready for QEMU

#### Convert a Virtual Disk
1. Pick option **4**
2. Enter path to source image
3. Tool auto-detects current format
4. Pick new format (1-5)
5. Choose output directory and filename
6. Watch progress bar with ETA
7. Done — converted image is ready

#### Explore Files Inside a Virtual Disk
1. Pick option **5**
2. Enter path to image
3. Choose read-only (recommended) or read-write
4. Image connects via NBD
5. Pick which partition to mount
6. Tool mounts it to `/media/$USER/QEMU_...`
7. Open the path in your file manager
8. Press Enter when done — everything unmounts and cleans up automatically

#### Backup a Real Disk to Image
1. Pick option **3**
2. Choose "Whole disk" or "Partition"
3. Select the disk from numbered list
4. Tool checks if it's mounted (warns if yes)
5. Choose output format and location
6. Watch progress bar
7. Done — you have a backup image

#### Restore an Image to a Real Disk
1. Pick option **6**
2. Enter image path
3. Select target disk or partition
4. Tool warns if mounted
5. **Type the device path exactly** (first confirmation)
6. **Type "WIPE"** (second confirmation)
7. Image writes to disk with progress bar
8. Done — disk is restored

---

## 🏗️ Project Structure

```
qemu-disk-tool/
├── qemu-disk-tool.sh          # Main script (all functionality)
└── README.md
```

---

## ⚡ Performance

| Operation | With Progress Bar | Notes |
|-----------|:---:|-------|
| Disk to Image | ✅ | Shows speed in MB/s, ETA, percentage |
| Image Conversion | ✅ | Real-time progress with time elapsed |
| Image to Disk | ✅ | Same progress tracking |
| File-based images | ✅ | Auto-detects total size from qemu-img info |

The progress bar adapts automatically — block devices use `blockdev --getsize64`, files use `qemu-img info` to get the total size.

---

## ⚠️ Known Limitations

### Platform
- **Linux only**: Uses modprobe, udevadm, apt-get, and Linux-specific device paths
- **Ubuntu/Debian auto-install**: Other distros need manual tool installation

### Current Constraints (v1)
- Single image processing at a time (no batch mode)
- No image resize or expand functionality
- No qcow2 snapshot management (list/create/delete/apply)
- No ISO creation or conversion support
- NBD kernel module must support `max_part >= 16` (script checks this)
- Some kernels round `max_part` to 31 instead of 16 (script handles this, shows warning but continues)
- Must be run as root (script auto-re-launches with sudo if needed)

---

## 🗺️ Planned Improvements

### v2 (Next Update)
- **Smart disk cloning** — Clone entire disk or partition to image with automatic size detection. Same size limits as current script. Just pick the source, pick the format, done.
- **Batch convert** — Select multiple images at once and convert all in one operation. No more converting files one by one.
- **Resize images** — Change the size of existing qcow2/raw images (make bigger or smaller), and optionally fix the partitions inside so they still work.
- **Disk usage stats** — Show actual space used on disk vs. virtual size. For qcow2, show compression ratio and how much space you're saving.

### v3 (Future)
- **Support more Linux distros** — Auto-install tools on Fedora, Arch, openSUSE, etc. Not just Ubuntu/Debian.
- **Snapshot manager** — New menu option to create, list, delete, and rollback qcow2 snapshots. Like save points for your VM.
- **ISO to qcow2** — Turn an ISO file into a bootable VM disk directly from the menu.
- **Tabbed interface** — Script opens with tabs, each tab can run a different batch operation. Do multiple things at once without leaving the menu.

---

## 🔧 Issues Fixed (v1)

| Issue | Status |
|-------|--------|
| NBD partition detection failing when `max_part` was 31 (kernel rounding) | ✅ Fixed |
| Progress bar not showing output (missing `-f` flag in `script` command) | ✅ Fixed |
| Ctrl+C during conversion causing error instead of clean cancel | ✅ Fixed |
| `explore_mount_image` cleanup running twice on exit (missing guard flag) | ✅ Fixed |
| NBD picker returning partition nodes instead of base device | ✅ Fixed |
| Mount detection missing disk-level mounts (only checked exact device) | ✅ Fixed |
| USED_NBDS array not updating on disconnect | ✅ Fixed |
| `set -u` causing crashes when associative array counts were unset | ✅ Fixed |

---

## 🤝 Contributing

### Development Setup

```bash
git clone git@github.com:umar-shahzadmughal/qemu-disk-tool.git
cd qemu-disk-tool
chmod +x qemu-disk-tool.sh
```

### Code Quality

```bash
shellcheck qemu-disk-tool.sh    # Static analysis
bash -n qemu-disk-tool.sh       # Syntax check
```

### Debug Mode

To see detailed NBD and mount operations:

```bash
sudo bash -x ./qemu-disk-tool.sh
```

### Code Guidelines
- Pure bash, no external scripting languages
- All functions must use `local` for internal variables
- Destructive operations require double confirmation
- NBD cleanup must be registered in `global_cleanup` trap
- All user input reads from `$TTY` (not stdin) for sudo compatibility
- Use `set -euo pipefail` at the top of every new function file

---

## 📄 License

This project is provided without a license. All rights reserved by the creator. 

If you wish to use, modify, or distribute this code, please contact the author.

### Third-Party Licenses
| Component | License |
|-----------|---------|
| QEMU | GPLv2 |
| util-linux | GPLv2+ |
| parted | GPLv3+ |
| ntfs-3g | GPLv2+ |

---



## 🙏 Credits

Built with:

| Tool | Purpose |
|------|---------|
| [QEMU](https://www.qemu.org/) | Virtual machine and disk image tools |
| [util-linux](https://github.com/util-linux/util-linux) | Essential Linux utilities |
| [ntfs-3g](https://github.com/tuxera/ntfs-3g) | NTFS filesystem driver |

---

<div align="center">

Version 1.0

The tool I needed when I started. One person's struggle, now everyone's solution. QEMU disks mastered, simplified. 
</div>

---