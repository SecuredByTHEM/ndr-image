#!/bin/bash

CODENAME=xenial
MIRROR=http://us.archive.ubuntu.com/ubuntu
BUILD_TIME=`date`

SYSTEM_PARTITION_SIZE=2048
INSTALLATION_PACKAGES="ca-certificates uucp nmap snort syslog-ng dhcpcd5 openssh-server"
DEVELOPMENT_PACKAGES="python3-setuptools build-essential python3-dev libffi-dev libssl-dev"
MOUNT_POINT=mnt

while getopts ":d:b:" opt; do
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

# Make debconf shut up
export DEBIAN_FRONTEND=noninteractive

if [ "$(id -u)" != "0" ]; then
    echo "mkimage must be run as root" 1>&2
    exit 1
fi

trap cleanup INT
. ./functions

echo "=== Creating raw image ==="

# BUG IN DD, bs is a signed 32-bit integer.
# use MB size
rm -rf $ROOTFS_DIR
#mkdir -p $ROOTFS_DIR
dd if=/dev/zero of=$IMAGE_FILE bs=1048576 count=$SYSTEM_PARTITION_SIZE

# Create our partitions in the disk image

echo "=== Initializing filesystems ==="
mkfs.ext4 -F $IMAGE_FILE

echo "=== Building root filesystem ==="
# Create an installation chroot so we may load root-an
run_or_die "debootstrap $CODENAME $ROOTFS_DIR $MIRROR"

# Mount proc and dev/pts so things can be happy
run_or_die "mount -t proc none $ROOTFS_DIR/proc"
run_or_die "mount -t devpts none $ROOTFS_DIR/dev/pts"
run_or_die "mount -t sysfs none $ROOTFS_DIR/sys"

# Install /etc/apt/sources.list and force an index rebuild
echo "deb $MIRROR $CODENAME main universe" > $ROOTFS_DIR/etc/apt/sources.list
echo "deb $MIRROR $CODENAME-security main universe" >> $ROOTFS_DIR/etc/apt/sources.list

echo "=== Creating hostname file to allow postfix to install ==="
echo "ndr.notreal\n" > $ROOTFS_DIR/etc/hostname

# Install updates and MAGIC
echo "=== Installing base upgrades and localegen"
run_or_die "chroot $ROOTFS_DIR apt-get update"
run_or_die "chroot $ROOTFS_DIR apt-get -y dist-upgrade"
run_or_die "chroot $ROOTFS_DIR locale-gen en_US.UTF-8"

echo "=== Installing packages ==="
run_or_die "chroot $ROOTFS_DIR apt-get -y install $INSTALLATION_PACKAGES $DEVELOPMENT_PACKAGES"

echo "=== Installing NDR ==="

# Use the system git to download the source code from the repo
mkdir -p $ROOTFS_DIR/scratch
pushd $ROOTFS_DIR/scratch
git clone https://github.com/SecuredByTHEM/ndr.git
git clone https://github.com/SecuredByTHEM/ndr-netcfg.git

# This shouldn't be needed, but travis seems to require it
mkdir -p $ROOTFS/usr/lib/python3.5/site-packages/
popd

run_or_die 'chroot $ROOTFS_DIR /bin/bash -c "cd /scratch/ndr && ./setup.py test && ./setup.py install"'
run_or_die 'chroot $ROOTFS_DIR /bin/bash -c "cd /scratch/ndr-netcfg && ./setup.py test && ./setup.py install"'

# Install the unit file and enable it
cp $ROOTFS_DIR/scratch/ndr-netcfg/systemd/ndr-netcfg.service $ROOTFS_DIR/etc/systemd/system
run_or_die "chroot $ROOTFS_DIR systemctl enable ndr-netcfg.service"

# Remove the unwanted floatism
echo "=== Reducing image size ==="
rm -rf $ROOTFS_DIR/scratch
rm $ROOTFS_DIR/var/cache/apt/archives/*.deb

echo "=== Setting root password ==="
run_or_die 'chroot $ROOTFS_DIR /bin/bash -c "echo root:password | chpasswd"'

# Create symlinks to persistance directory for host/hostname
run_or_die 'chroot $ROOTFS_DIR ln -sf /persistant/etc/hosts /etc/hosts'
run_or_die 'chroot $ROOTFS_DIR ln -sf /persistant/etc/hostname /etc/hostname'

# Removing unneeded packages
echo "=== Removing Development Packages ==="
run_or_die 'chroot $ROOTFS_DIR bash -c "apt-get remove -y $DEVELOPMENT_PACKAGES lib*dev *doc"'

# Mount root-a and copy stuff there
echo "=== Copying files into image ==="
mkdir mnt
umount $ROOTFS_DIR/proc
umount $ROOTFS_DIR/dev/pts
umount $ROOTFS_DIR/sys

# Change the OS Branding
cp ident/lsb-release $ROOTFS_DIR/etc
cp ident/os-release $ROOTFS_DIR/etc
cp ident/legal $ROOTFS_DIR/etc/legal

# Override the login prompts
echo "Secured By THEM Network Data Recorder $BUILD_TIME" > $ROOTFS_DIR/etc/issue.net
echo "Secured By THEM Network Data Recorder $BUILD_TIME \n \l" > $ROOTFS_DIR/etc/issue

# Delete the Ubuntu documentation string
rm $ROOTFS_DIR/etc/update-motd.d/10-help-text

mkdir -p $ROOTFS_DIR/etc/ndr
run_or_die "cp configs/$NDR_CONFIG/ndr/config.yml $ROOTFS_DIR/etc/ndr"
run_or_die "cp configs/$NDR_CONFIG/ndr/ca.crt $ROOTFS_DIR/etc/ndr"

run_or_die "cp configs/$NDR_CONFIG/uucp/call $ROOTFS_DIR/etc/uucp/call"
run_or_die "cp configs/$NDR_CONFIG/uucp/port $ROOTFS_DIR/etc/uucp/port"
run_or_die "cp configs/$NDR_CONFIG/uucp/sys $ROOTFS_DIR/etc/uucp/sys"

# Copy in rc.local
cp configs/common/rc.local $ROOTFS_DIR/etc/rc.local

echo "=== Writing out the fstab ==="
mkdir $ROOTFS_DIR/persistant
echo "tmpfs			/tmp        	tmpfs   nodev,nosuid,noexec,size=16M	0 0" >> $ROOTFS_DIR/etc/fstab
echo "tmpfs			/run    	tmpfs   nodev,nosuid,noexec,size=16M	0 0" >> $ROOTFS_DIR/etc/fstab

echo "=== Copying build tree to the boot disk ==="
run_or_die "mount $IMAGE_FILE $MOUNT_POINT"
run_or_die "rsync -aHAX $ROOTFS_DIR/ $MOUNT_POINT"
sync
umount $MOUNT_POINT

echo "=== Creating DM-Verity hashs ==="
ROOT_HASH=`veritysetup format $IMAGE_FILE $HASH_BLOCK | grep Root\ hash | awk '{print $3}'`
echo "ROOT_HASH=$ROOT_HASH" > $ROOT_HASH_FILE

echo "=== Compressing output.img ==="
rm -f $IMAGE_FILE.bz2
bzip2 $IMAGE_FILE

run_or_die "mv $IMAGE_FILE.bz2 upload/rootfs.img.bz2"

echo "=== Building the boot kernel ==="
bin/cook_kernel.sh -b $BUILD_DIR -d $NDR_CONFIG

