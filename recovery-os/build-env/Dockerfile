FROM debian:12

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        live-build \
        debootstrap \
        ca-certificates \
        git \
        rsync \
        xorriso \
        squashfs-tools \
        syslinux \
        syslinux-common \
        isolinux \
        grub-pc-bin \
        grub-efi-amd64-bin \
        grub-efi-amd64-signed \
        shim-signed \
        mtools \
        dosfstools \
        qemu-utils \
        ovmf \
        && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build
