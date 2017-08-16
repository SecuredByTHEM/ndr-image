#!/bin/bash

CWD=`pwd`

while getopts ":b:d:" opt; do
    case $opt in
        b)
            echo "NDR Build Directory: $OPTARG"
            BUILD_DIR=$OPTARG
            ;;
        d)
            echo "NDR Config: $OPTARG"
            NDR_CONFIG=$OPTARG
            ;;
    esac
done

if [ -z $NDR_CONFIG ]; then
    echo "NDR distribution (-d) must be selected"
    exit 1
fi

. ./functions
. ./configs/$NDR_CONFIG/image.config

if [ "$(id -u)" != "0" ]; then
    echo "mkimage must be run as root" 1>&2
    exit 1
fi

rm -f upload/*


echo "=== Checking Out Buildroot ==="
if [ ! -d $BUILD_DIR/buildroot ]; then
    git clone $BUILDROOT_REPO -b $BUILDROOT_BRANCH $BUILD_DIR/buildroot
fi

echo "CURRENT_IMAGE_BUILDTIME=`cat $BUILD_DIR/ota.timestamp`" > $BUILD_DIR/buildroot/board/securedbythem/ndr_boot/rootfs_overlay/build.time
pushd $BUILD_DIR/buildroot
git pull
run_or_die "cp $CWD/$HASH_BLOCK board/securedbythem/ndr_boot/rootfs_overlay"
run_or_die "cp $CWD/$ROOT_HASH_FILE board/securedbythem/ndr_boot/rootfs_overlay"
run_or_die "cp $CWD/$IMAGE_CONFIG board/securedbythem/ndr/image.config"
./build_all.sh
popd

mkdir -p upload
run_or_die "cp $BUILD_DIR/buildroot/images/boot.efi upload/bootx64.efi"
run_or_die "cp $BUILD_DIR/buildroot/images/boot_installer.efi upload/boot_installer.efi"

echo "=== Compressing output.img ==="
rm -f $IMAGE_FILE.bz2
bzip2 $IMAGE_FILE

mv $IMAGE_FILE.bz2 upload/rootfs.img.bz2

BOOT_IMG="/tmp/boot_installer.img"
WORK_DIR=`mktemp -d`

run_or_die "cp $BUILD_DIR/ota.timestamp upload/"

run_or_die "dd if=/dev/zero of=$BOOT_IMG bs=1MiB count=64"
run_or_die "mkfs.vfat -F 32 $BOOT_IMG"
run_or_die "mount $BOOT_IMG $WORK_DIR"
run_or_die "mkdir -p $WORK_DIR/EFI/BOOT"
run_or_die "cp upload/boot_installer.efi $WORK_DIR/EFI/BOOT/bootx64.efi"
run_or_die "umount $WORK_DIR"
run_or_die "rm -rf $WORK_DIR"
run_or_die "cp $BOOT_IMG upload"

ISO_DIR=`mktemp -d`
run_or_die "cp $BOOT_IMG $ISO_DIR"
run_or_die "mkisofs -U -A \"NDR installer\" -V \"NDR Installer\" -J -joliet-long -r -v -T -o ./upload/boot_installer.iso -eltorito-alt-boot -no-emul-boot -eltorito-boot boot_installer.img $ISO_DIR/"
run_or_die "rm -rf $ISO_DIR"
