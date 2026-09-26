#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECOVERY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LB_DIR="$RECOVERY_DIR/live-build"
PROJECT_ROOT="$(cd "$RECOVERY_DIR/.." && pwd)"

VERSION="$(cat "$RECOVERY_DIR/VERSION")"
BUILDER_IMAGE="qdt-recovery-build:bookworm"

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker is required."
    exit 1
fi

if ! docker image inspect "$BUILDER_IMAGE" >/dev/null 2>&1; then
    echo "ERROR: Builder image not found: $BUILDER_IMAGE"
    echo
    echo "Build it with:"
    echo "  docker build -t $BUILDER_IMAGE $RECOVERY_DIR/build-env"
    exit 1
fi

cd "$LB_DIR"

echo "============================================================"
echo "      QEMU Disk Tool Recovery OS Build"
echo "============================================================"
echo
echo "Version:      $VERSION"
echo "Architecture: amd64"
echo "Base:         Debian 12 Bookworm"
echo "Builder:      $BUILDER_IMAGE"
echo

SOURCE_DATE_EPOCH="$(
    git -C "$PROJECT_ROOT" log -1 --pretty=%ct 2>/dev/null ||
    date +%s
)"

echo "Generating live-build configuration..."

docker run --rm \
    --privileged \
    -v "$LB_DIR:/build" \
    -w /build \
    "$BUILDER_IMAGE" \
    ./auto/config

echo
echo "Checking live-build version..."

docker run --rm \
    "$BUILDER_IMAGE" \
    lb --version

echo
echo "Starting Debian Bookworm live-build..."
echo

docker run --rm \
    --privileged \
    -e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    -v "$LB_DIR:/build" \
    -w /build \
    "$BUILDER_IMAGE" \
    lb build

echo
echo "============================================================"
echo "Build completed."
echo "============================================================"
echo

find "$LB_DIR" -maxdepth 1 \
    -type f \
    \( -name '*.iso' -o -name '*.sha256' \) \
    -exec ls -lh {} \; \
    2>/dev/null || true
