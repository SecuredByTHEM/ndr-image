#!/bin/bash

CODENAME=xenial
MIRROR=http://us.archive.ubuntu.com/ubuntu
BUILD_TIME=`date`
BUILD_TIMESTAMP=`date +"%s"`

SYSTEM_PARTITION_SIZE=2048
INSTALLATION_PACKAGES="ca-certificates uucp syslog-ng dhcpcd5 libdumbnet1 libpython3.5 python3-pkg-resources python3-setuptools joe nano libpcap0.8 libc-ares2 tcpdump python-minimal libgcrypt20 libglib2.0-0"
DEVELOPMENT_PACKAGES="build-essential python3-dev libffi-dev libssl-dev libpcap-dev libpcre3-dev libdumbnet-dev flex bison libc-ares-dev autoconf automake libtool pkg-config libtool-bin libgcrypt-dev libglib2.0-dev"
MOUNT_POINT=mnt

DAQ_URL="https://snort.org/downloads/snort/daq-2.0.6.tar.gz"
SNORT_URL="https://snort.org/downloads/snort/snort-2.9.9.0.tar.gz"
NMAP_URL="https://nmap.org/dist/nmap-7.60.tar.bz2"

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

if [ -z $NDR_ROOT_PASSWORD ]; then
    echo 'Env variable $NDR_ROOT_PASSWORD must be set'
    exit 1
fi

. ./configs/$NDR_CONFIG/image.config

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
mkdir -p $ROOTFS_DIR
dd if=/dev/zero of=$IMAGE_FILE bs=1048576 count=$SYSTEM_PARTITION_SIZE

# Create our partitions in the disk image

echo "=== Initializing filesystems ==="
mkfs.ext4 $IMAGE_FILE

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

mkdir -p $ROOTFS_DIR/scratch

echo "=== Building SNORT ==="
run_or_die 'curl -L $DAQ_URL -o $ROOTFS_DIR/scratch/daq.tar.gz'
tar zxvf $ROOTFS_DIR/scratch/daq.tar.gz -C $ROOTFS_DIR/scratch
run_or_die 'chroot $ROOTFS_DIR /bin/bash -c "cd /scratch/daq* && ./configure --prefix=/usr && make && make install"'

run_or_die 'curl -L $SNORT_URL -o $ROOTFS_DIR/scratch/snort.tar.gz'
tar zxvf $ROOTFS_DIR/scratch/snort.tar.gz -C $ROOTFS_DIR/scratch
run_or_die 'chroot $ROOTFS_DIR /bin/bash -c "cd /scratch/snort* && ./configure --prefix=/usr && make && make install"'

echo "=== Building NMAP ==="
run_or_die 'curl -L $NMAP_URL -o $ROOTFS_DIR/scratch/nmap.tar.bz2'
tar jxvf $ROOTFS_DIR/scratch/nmap.tar.bz2 -C $ROOTFS_DIR/scratch
run_or_die 'chroot $ROOTFS_DIR /bin/bash -c "cd /scratch/nmap* && ./configure --prefix=/usr && make && make install"'


echo "=== Installing NDR ==="

pushd $ROOTFS_DIR/scratch

# Use the system git to download the source code from the repo
run_or_die 'git clone $NDR_TSHARK_REPO -b $NDR_TSHARK_BRANCH ndr-tshark'
run_or_die 'git clone $NDR_NETCFG_REPO -b $NDR_NETCFG_BRANCH ndr-netcfg'
run_or_die 'git clone $NDR_REPO -b $NDR_BRANCH ndr'
popd

echo "=== Building NDR-TShark ==="
run_or_die 'chroot $ROOTFS_DIR /bin/bash -c "cd /scratch/ndr-tshark && ./autogen.sh && ./configure --prefix=/opt/tshark-ndr --disable-wireshark --with-c-ares=/usr && make && make install"'
run_or_die 'chroot $ROOTFS_DIR /bin/bash -c "cd /scratch/ndr-netcfg && ./setup.py test && ./setup.py install"'
run_or_die 'chroot $ROOTFS_DIR /bin/bash -c "cd /scratch/ndr && ./setup.py test && ./setup.py install"'

echo "=== Install NDR System Configuration Files ==="
# We may want to move this to a script in the ndr-client directory
run_or_die "cp $ROOTFS_DIR/scratch/ndr/sysconfig/logrotate/ndr $ROOTFS_DIR/etc/logrotate.d/"
run_or_die "cp $ROOTFS_DIR/scratch/ndr/sysconfig/cron/ndr $ROOTFS_DIR/etc/cron.d/"
run_or_die "cp $ROOTFS_DIR/scratch/ndr/sysconfig/syslog-ng/ndr.conf $ROOTFS_DIR/etc/syslog-ng/conf.d/"

# Install the sudoers file to allow enlistment to work
run_or_die "cp $ROOTFS_DIR/scratch/ndr/sysconfig/sudoers/ndr $ROOTFS_DIR/etc/sudoers.d/ndr"
run_or_die "chown root:root $ROOTFS_DIR/etc/sudoers.d/ndr"
run_or_die "chmod 0600 $ROOTFS_DIR/etc/sudoers.d/ndr"

echo "=== Setting root password ==="
run_or_die "chroot $ROOTFS_DIR /bin/bash -c \"echo 'root:$NDR_ROOT_PASSWORD' | chpasswd\""

echo "=== Setting up configuration files ==="
# Create symlinks to persistance directory for host/hostname
run_or_die 'chroot $ROOTFS_DIR ln -sf /persistant/etc/hosts /etc/hosts'
run_or_die 'chroot $ROOTFS_DIR ln -sf /persistant/etc/hostname /etc/hostname'
run_or_die 'chroot $ROOTFS_DIR ln -sf /persistant/etc/dhcpcd.secret /etc/dhcpcd.secret'

# And another for the DHCP DUID (see rant in NDR installation script in buildroot)
run_or_die 'chroot $ROOTFS_DIR ln -sf /persistant/etc/dhcpcd.duid /etc/dhcpcd.duid'

# Build the snort configuration files
mkdir -p $ROOTFS_DIR/etc/snort/rules

# Create the snort user
run_or_die "chroot $ROOTFS_DIR adduser --system --group snort --no-create-home"

# Copy some common files from the snort build directory
run_or_die "cp $ROOTFS_DIR/scratch/snort*/etc/classification.config $ROOTFS_DIR/etc/snort"
run_or_die "cp $ROOTFS_DIR/scratch/snort*/etc/file_magic.conf $ROOTFS_DIR/etc/snort"
run_or_die "cp $ROOTFS_DIR/scratch/snort*/etc/reference.config $ROOTFS_DIR/etc/snort"
run_or_die "cp $ROOTFS_DIR/scratch/snort*/etc/unicode.map $ROOTFS_DIR/etc/snort"

# Build community rules config file
run_or_die 'cat configs/common/snort/common.conf configs/common/snort/community.conf > $ROOTFS_DIR/etc/snort/snort-community.conf'
run_or_die 'cp configs/common/snort/community.rules $ROOTFS_DIR/etc/snort/rules/community.rules'
run_or_die 'cp configs/common/snort/community.service $ROOTFS_DIR/lib/systemd/system/snort-community.service'
run_or_die "chroot $ROOTFS_DIR systemctl enable snort-community.service"

# Install the TCPDUMP service
run_or_die 'cp configs/common/tcpdump/tcpdump-monitor.service $ROOTFS_DIR/lib/systemd/system/tcpdump-monitor.service'
run_or_die "chroot $ROOTFS_DIR systemctl enable tcpdump-monitor.service"

# Disable postfix port 25 service
run_or_die "chroot $ROOTFS_DIR systemctl disable postfix.service"

# Remove the unwanted floatism
echo "=== Reducing image size ==="
rm -rf $ROOTFS_DIR/scratch
rm -rf $ROOTFS_DIR/tmp/*
rm $ROOTFS_DIR/var/cache/apt/archives/*.deb

# Removing unneeded packages
echo "=== Removing Development Packages ==="
run_or_die 'chroot $ROOTFS_DIR bash -c "apt-get remove -y $DEVELOPMENT_PACKAGES lib*dev *doc"'

echo "=== Dump ureadahead ==="
run_or_die "chroot $ROOTFS_DIR apt-get -y remove ureadahead"

echo "=== Dump ureadahead ==="
run_or_die "chroot $ROOTFS_DIR apt-get -y autoremove"

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

# Delete the daily uudaemon run
run_or_die "chroot $ROOTFS_DIR rm /etc/cron.daily/apt-compat"
run_or_die "chroot $ROOTFS_DIR rm /etc/cron.daily/dpkg"
run_or_die "chroot $ROOTFS_DIR rm /etc/cron.daily/uucp"

# Create the NDR user
run_or_die "chroot $ROOTFS_DIR useradd -r -U ndr"
mkdir -p $ROOTFS_DIR/etc/ndr
run_or_die "cp configs/$NDR_CONFIG/ndr/config.yml $ROOTFS_DIR/etc/ndr"
run_or_die "cp configs/$NDR_CONFIG/ndr/ca.crt $ROOTFS_DIR/etc/ndr"

run_or_die "cp configs/$NDR_CONFIG/uucp/call $ROOTFS_DIR/etc/uucp/call"
run_or_die "cp configs/$NDR_CONFIG/uucp/port $ROOTFS_DIR/etc/uucp/port"
run_or_die "cp configs/$NDR_CONFIG/uucp/sys $ROOTFS_DIR/etc/uucp/sys"
run_or_die "cp configs/$NDR_CONFIG/cron/uucp $ROOTFS_DIR/etc/cron.d/uucp"
run_or_die "chroot $ROOTFS_DIR chown ndr:ndr -R /etc/ndr"

# Enable COM1 login
run_or_die "chroot $ROOTFS_DIR ln -s /usr/lib/systemd/system/getty@.service   /etc/systemd/system/getty.target.wants/getty@ttyS0.service"

# Copy in rc.local
cp configs/common/rc.local $ROOTFS_DIR/etc/rc.local
run_or_die "cp configs/common/postfix/aliases $ROOTFS_DIR/etc/postfix"
run_or_die "chroot $ROOTFS_DIR newaliases"

echo "=== Writing out the fstab ==="
mkdir $ROOTFS_DIR/persistant
echo "tmpfs			/tmp        	tmpfs   nodev,nosuid,noexec,size=16M	0 0" >> $ROOTFS_DIR/etc/fstab
echo "tmpfs			/run    	tmpfs   nodev,nosuid,noexec,size=16M	0 0" >> $ROOTFS_DIR/etc/fstab

echo "=== Writing information about the image ==="

echo "build_date: $BUILD_TIMESTAMP" > $ROOTFS_DIR/etc/ndr/image_info.yml
echo "image_type: $NDR_CONFIG" >> $ROOTFS_DIR/etc/ndr/image_info.yml
echo $BUILD_TIMESTAMP > $BUILD_DIR/ota.timestamp

echo "=== Copying build tree to the boot disk ==="
run_or_die "mount $IMAGE_FILE $MOUNT_POINT"
run_or_die "rsync -aHAX $ROOTFS_DIR/ $MOUNT_POINT"
sync
umount $MOUNT_POINT

echo "=== Creating DM-Verity hashs ==="
ROOT_HASH=`veritysetup format $IMAGE_FILE $HASH_BLOCK | grep Root\ hash | awk '{print $3}'`
echo "ROOT_HASH=$ROOT_HASH" > $ROOT_HASH_FILE

mkdir upload

echo "=== Building the boot kernel ==="
bin/cook_kernel.sh -b $BUILD_DIR -d $NDR_CONFIG

