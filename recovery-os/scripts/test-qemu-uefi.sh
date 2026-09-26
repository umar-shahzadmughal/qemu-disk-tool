#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECOVERY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LB_DIR="$RECOVERY_DIR/live-build"
TEST_DIR="$RECOVERY_DIR/test/uefi"

ISO="$(find "$LB_DIR" -maxdepth 1 -type f -name '*.iso' -print -quit)"

if [[ -z "$ISO" ]]; then
    echo "ERROR: No ISO found."
    echo "Build first with:"
    echo "  $RECOVERY_DIR/scripts/build.sh"
    exit 1
fi

mkdir -p "$TEST_DIR"

OVMF_CODE=""

for f in \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/OVMF/OVMF_CODE.fd
do
    if [[ -f "$f" ]]; then
        OVMF_CODE="$f"
        break
    fi
done

OVMF_VARS_TEMPLATE=""

for f in \
    /usr/share/OVMF/OVMF_VARS_4M.fd \
    /usr/share/OVMF/OVMF_VARS.fd
do
    if [[ -f "$f" ]]; then
        OVMF_VARS_TEMPLATE="$f"
        break
    fi
done

if [[ -z "$OVMF_CODE" || -z "$OVMF_VARS_TEMPLATE" ]]; then
    echo "ERROR: Standard OVMF UEFI firmware was not found."
    echo
    echo "Available OVMF files:"
    find /usr/share/OVMF -maxdepth 1 -type f 2>/dev/null | sort || true
    exit 1
fi

VARS="$TEST_DIR/OVMF_VARS.fd"
cp "$OVMF_VARS_TEMPLATE" "$VARS"

echo "ISO:        $ISO"
echo "OVMF CODE:  $OVMF_CODE"
echo "OVMF VARS:  $VARS"
echo
echo "Starting QEMU/KVM UEFI test..."
echo

exec qemu-system-x86_64 \
    -enable-kvm \
    -machine q35 \
    -cpu host \
    -smp 4 \
    -m 4096 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$VARS" \
    -cdrom "$ISO" \
    -boot order=d \
    -nic user,model=virtio-net-pci \
    -device virtio-rng-pci
