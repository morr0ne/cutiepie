#!/bin/sh

set -e

KERNEL_VERSION=6.7
BUSYBOX_VERSION=1.36.1
DASH_VERSION=0.5.12
LIMINE_VERSION=6.20231210.0
SRC_DIR=$PWD
WORK_DIR=$SRC_DIR/work
ROOTFS=$WORK_DIR/rootfs
ISOIMAGE=$WORK_DIR/isoimage
SCRIPTS=$SRC_DIR/scripts

KERNEL_SOURCES=$SRC_DIR/sources/linux/linux-${KERNEL_VERSION}
BUSYBOX_SOURCES=$SRC_DIR/sources/busybox/busybox-${BUSYBOX_VERSION}
DASH_SOURCES=$SRC_DIR/sources/dash/dash-${DASH_VERSION}
LIMINE_SOURCES=$SRC_DIR/sources/limine/limine-${LIMINE_VERSION}
SYSTEM_SOURCES=$SRC_DIR/system
SYSTEM_TARGET=$SYSTEM_SOURCES/target/x86_64-unknown-linux-gnu/release

build_kernel() {
    # Go into the linux directory
    cd $KERNEL_SOURCES

    # Make sure everything is squeaky clean
    make mrproper

    # Create a default config for amd64 that uses clang to build
    make ARCH=x86_64 LLVM=1 defconfig

    # Configure the kernel before building
    "${SCRIPTS}/config" --enable LTO_CLANG_FULL             # Enables full lto with clang
    "${SCRIPTS}/config" --enable CONFIG_KERNEL_ZSTD         # Enable zstd compression
    "${SCRIPTS}/config" --enable CONFIG_FB                  # Enable zstd compression
    "${SCRIPTS}/config" --enable CONFIG_FB_VESA             # Enable zstd compression
    "${SCRIPTS}/config" --enable CONFIG_FB_EFI              # Enable zstd compression
    "${SCRIPTS}/config" --enable CONFIG_FB_CORE             # Enable zstd compression
    "${SCRIPTS}/config" --enable CONFIG_FRAMEBUFFER_CONSOLE # Enable zstd compression

    make olddefconfig

    # exit

    # Build the kernel
    make bzImage

    # Go back to src before exiting
    cd $SRC_DIR
}

set_config_value() {
    config_name=$1
    config_content=$2
    config_path=$3

    sed -i "s|.*$config_name is not set.*|CONFIG_EXTRA_CFLAGS=$config_content|" $config_path
}

build_busybox() {
    # Go into busybox directory
    cd $BUSYBOX_SOURCES

    # Make sure everything is clean
    make distclean

    # Create a default config
    make allnoconfig

    # Configure busybox before building
    "${SCRIPTS}/config" --set-str EXTRA_CFLAGS "-O2"
    "${SCRIPTS}/config" --enable STATIC
    "${SCRIPTS}/config" --enable INIT
    "${SCRIPTS}/config" --enable FEATURE_USE_INITTAB
    "${SCRIPTS}/config" --disable SH_IS_ASH
    "${SCRIPTS}/config" --enable SH_IS_NONE
    "${SCRIPTS}/config" --enable CTTYHACK
    "${SCRIPTS}/config" --enable MOUNT
    "${SCRIPTS}/config" --enable CP
    "${SCRIPTS}/config" --enable MKDIR
    "${SCRIPTS}/config" --enable SWITCH_ROOT
    "${SCRIPTS}/config" --enable LS
    "${SCRIPTS}/config" --enable DU
    "${SCRIPTS}/config" --enable WHICH

    # Build busybox
    make busybox

    # Go back to src before exiting
    cd $SRC_DIR
}

build_dash() {
    cd $DASH_SOURCES

    autoreconf -fiv
    ./configure --enable-static CFLAGS="-O2"

    make

    cd $SRC_DIR
}

build_system() {
    cd $SYSTEM_SOURCES

    cargo build --release --target x86_64-unknown-linux-gnu

    cd $SRC_DIR
}

build_limine() {
    cd $LIMINE_SOURCES

    ./configure --enable-all

    make

    cd $SRC_DIR
}

create_rootfs() {
    # Remove old rootfs if it exists
    rm -rf $ROOTFS
    rm -rf $WORK_DIR/rootfs.cpio.zst

    # Go into busybox directory
    cd $BUSYBOX_SOURCES

    # Create all the symlinks
    make CONFIG_PREFIX=$ROOTFS install

    # Enter rootfs
    cd $ROOTFS

    # Create basic filesystem
    mkdir dev
    mkdir etc
    mkdir lib
    mkdir proc
    mkdir root
    mkdir sys
    mkdir tmp
    mkdir var
    mkdir mnt

    # Copy init files
    cp $SRC_DIR/init .
    cp $SRC_DIR/inittab etc/inittab

    # cp $SRC_DIR/temp/btm bin/btm

    # Copy shell
    cp $DASH_SOURCES/src/dash bin/sh

    # Copy system manager files
    mkdir system
    cp $SYSTEM_TARGET/init system/init
    cp $SYSTEM_TARGET/uname system/uname
    cp $SYSTEM_TARGET/clear system/clear

    # Strip everything
    strip --strip-all $ROOTFS/bin/* $ROOTFS/sbin/*

    # Pack initramfs
    find . | bsdcpio -R root:root -H newc -o | zstd -22 --ultra --long --quiet --stdout >$WORK_DIR/rootfs.cpio.zst

    # Go back to src before exiting
    cd $SRC_DIR
}

create_iso() {
    # Remove old isoimage if it exists
    rm -rf $ISOIMAGE
    rm -rf cutiepie.iso

    # Create directory for boot files
    mkdir -p $ISOIMAGE/boot

    # Copy the actual kernel
    cp $KERNEL_SOURCES/arch/x86/boot/bzImage $ISOIMAGE/boot/kernel.zst

    # Copy the initramfs image
    cp $WORK_DIR/rootfs.cpio.zst $ISOIMAGE/boot/rootfs.zst

    # Copy all limine stuff
    cp $LIMINE_SOURCES/bin/limine-uefi-cd.bin $ISOIMAGE/boot
    cp $LIMINE_SOURCES/bin/limine-bios-cd.bin $ISOIMAGE/boot
    cp $LIMINE_SOURCES/bin/limine-bios.sys $ISOIMAGE/boot
    cp limine.cfg $ISOIMAGE/boot

    mkdir -p $ISOIMAGE/EFI/BOOT
    cp $LIMINE_SOURCES/bin/BOOTX64.EFI $ISOIMAGE/EFI/BOOT

    # Create iso
    xorriso -as mkisofs -b boot/limine-bios-cd.bin \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        --efi-boot boot/limine-uefi-cd.bin \
        -efi-boot-part --efi-boot-image --protective-msdos-label \
        $ISOIMAGE -o $SRC_DIR/cutiepie.iso

    # Ensure the iso is bootable
    $LIMINE_SOURCES/bin/limine bios-install cutiepie.iso

    cd $SRC_DIR

}

DOWNLOAD_SOURCES=true
BUILD_KERNEL=true
BUILD_BUSYBOX=true
BUILD_DASH=true

while getopts "skbd" arg; do
    case ${arg} in
    s)
        DOWNLOAD_SOURCES=false
        ;;
    k)
        BUILD_KERNEL=false
        ;;
    b)
        BUILD_BUSYBOX=false
        ;;
    d)
        BUILD_DASH=false
        ;;
    esac
done

if $DOWNLOAD_SOURCES; then
    rm -rf $WORK_DIR
    pipenv run python download_and_extract.py
else
    echo "Skipping sources download"
fi

BUILD_START=$(date +%s)

if $BUILD_KERNEL; then
    build_kernel
else
    echo "Skipping kernel build"
fi

if $BUILD_BUSYBOX; then
    build_busybox
else
    echo "Skipping busybox build"
fi

if $BUILD_DASH; then
    build_dash
else
    echo "Skipping dash build"
fi

build_system
build_limine
create_rootfs
create_iso

BUILD_END=$(date +%s)
printf "Built cutiepie iso in %s seconds\n" $(($BUILD_END - $BUILD_START))
