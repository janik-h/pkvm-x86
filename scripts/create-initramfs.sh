#!/usr/bin/env -S bash -e

SCRIPT_NAME=$(realpath "$0")
SCRIPT_DIR=$(dirname "${SCRIPT_NAME}")
NBDDEV="nbd3"
CPIO_HEADER="070701"

# shellcheck disable=SC1090
. "${SCRIPT_DIR}/${SYSROOT_JAIL:-chroot}-utils.sh"

# Check required env variables
[ ! -d "$BASE_DIR" ] && sysroot_exit_error 1 "BASE_DIR does not exist"
[ ! -d "$KERNEL_DIR" ] && sysroot_exit_error 1 "KERNEL_DIR does not exist"

if [ "x$EFI" = "x1" ]; then
	if [ "x$LUKS" = "x1" ]; then
		OUTFILE=ubuntuhost-luks-efi.qcow2
	else
		OUTFILE=ubuntuhost-efi.qcow2
	fi
else
	OUTFILE=ubuntuhost.qcow2
fi
OUTDIR=$BASE_DIR/images/host
IMAGEPATH=$OUTDIR/$OUTFILE

# Create sysroot dir
TEMP_SYSROOT_DIR=$(mktemp -d --tmpdir="$(pwd)/build")
export TEMP_SYSROOT_DIR
[ ! -d "$TEMP_SYSROOT_DIR" ] && sysroot_exit_error 1 "Tempdir $TEMP_SYSROOT_DIR creation failed"

do_cleanup()
{
	echo "${FUNCNAME[0]}: clean $TEMP_SYSROOT_DIR at /dev/$NBDDEV"

	sudo sync

	sysroot_unmount_all "$TEMP_SYSROOT_DIR"
	sudo umount /dev/${NBDDEV}p2
	sudo qemu-nbd -d /dev/$NBDDEV

	sudo rm -rf "$TEMP_SYSROOT_DIR"

	exit 0
}

trap do_cleanup SIGHUP SIGINT SIGTERM EXIT

echo "Mounting sysroot"

sudo rmmod nbd || true
sudo modprobe nbd
sudo qemu-nbd --connect=/dev/$NBDDEV $IMAGEPATH
sudo mount /dev/${NBDDEV}p2 $TEMP_SYSROOT_DIR

ROOTMOUNT=$TEMP_SYSROOT_DIR
BOOTDIR="$ROOTMOUNT/boot"
if [ ! -d "$BOOTDIR" ]; then 
	echo "r u sure about $IMAGEPATH?"
	do_cleanup
fi

# Make our kernel config available for the initramfs tooling
KERNEL_RELEASE=$(cat "$BASE_BUILD_DIR/kernel.release" | tr -d '[:space:]')
sudo cp "$KERNEL_DIR/.config" "$BOOTDIR/config-${KERNEL_RELEASE}"
sudo sync

# The mounts necessary for the chroot
sysroot_mount_all "$BASE_DIR" "$TEMP_SYSROOT_DIR"

echo "Sysroot mounted"

ROOT_PARTITION_DEVICE="/dev/nvme0n1p2"

echo "rootmount: $ROOTMOUNT"
echo "kernel: $KERNEL_RELEASE"

FSTAB="$ROOTMOUNT/etc/fstab"
INITRAMFS_CONF="$ROOTMOUNT/etc/initramfs-tools/initramfs.conf"
INIT_PATH="$ROOTMOUNT/usr/share/initramfs-tools/init"
if [ ! -f "$INIT_PATH" ]; then
    echo "Error: $INIT_PATH not found!"
    exit 1
fi
sudo sed -i "s/exec run-init.*/exec switch_root \/root \/sbin\/init/" "$INIT_PATH"

MOUNT_POINT="/"
FS_TYPE="ext4"
FSTAB_OPTIONS="errors=remount-ro"
FSTAB_DUMP_PASS="0 1"

HOOKS_CONF='HOOKS="base udev block keyboard filesystems"'
if grep -q '^HOOKS=' "$INITRAMFS_CONF"; then
	sudo sed -i "s/^HOOKS=.*/$HOOKS_CONF/" "$INITRAMFS_CONF"
else
	echo "$HOOKS_CONF" | sudo tee -a "$INITRAMFS_CONF" > /dev/null
fi

MODULES_CONF='MODULES=most'
if grep -q '^MODULES=' "$MODULES_CONF"; then
	sudo sed -i "s/^MODULES=.*/$MODULES_CONF/" "$INITRAMFS_CONF"
else
	echo "$MODULES_CONF" | sudo tee -a "$INITRAMFS_CONF" > /dev/null
fi

BUSYBOX_CONF="BUSYBOX=y"
if grep -q '^BUSYBOX=' "$INITRAMFS_CONF"; then
	sudo sed -i "s/^BUSYBOX=.*/$BUSYBOX_CONF/" "$INITRAMFS_CONF"
else
	echo "$BUSYBOX_CONF" | sudo tee -a "$INITRAMFS_CONF" > /dev/null
fi

# gzip if we wanted such a thing
if [ "x$GZIP_RAMFS" = "x1" ]; then
	if [ -f "$INITRAMFS_CONF" ]; then
		if sudo grep -q '^COMPRESS=' "$INITRAMFS_CONF"; then
			sudo sed -i 's/^COMPRESS=.*/COMPRESS=gzip/' "$INITRAMFS_CONF"
		else
			echo "COMPRESS=gzip" | sudo tee -a "$INITRAMFS_CONF" > /dev/null
		fi
	else
		echo "Error: $INITRAMFS_CONF not found."
		exit 1
	fi
fi

if [ "x$LUKS" = "x1" ]; then
	CRYPTSETUP_CONF="$ROOTMOUNT/etc/cryptsetup-initramfs/conf-hook"
	CRYPTTAB="$ROOTMOUNT/etc/crypttab"
	ENCRYPTED_DEVICE_NAME=$(basename "$ROOT_PARTITION_DEVICE")
	DECRYPTED_VOLUME_NAME="d${ENCRYPTED_DEVICE_NAME}"
	FSTAB_DEVICE="/dev/mapper/$DECRYPTED_VOLUME_NAME"
	CRYPTTAB_OPTIONS="luks,discard"
	CRYPTTAB_LINE="$DECRYPTED_VOLUME_NAME $ROOT_PARTITION_DEVICE none $CRYPTTAB_OPTIONS"
	# Ensure cryptsetup or notify if conf file is not found
	if [ -f "$CRYPTSETUP_CONF" ]; then
		if ! grep -q "^CRYPTSETUP=y" "$CRYPTSETUP_CONF"; then
			echo "CRYPTSETUP=y" | sudo tee -a "$CRYPTSETUP_CONF" > /dev/null
		else
			echo "CRYPTSETUP=y already present in $CRYPTSETUP_CONF."
		fi
	else
		echo "Warning: $CRYPTSETUP_CONF not found."
	fi

	sudo sed -i "/^$DECRYPTED_VOLUME_NAME/d" "$CRYPTTAB" 2>/dev/null
	echo "$CRYPTTAB_LINE" | sudo tee -a "$CRYPTTAB" > /dev/null

	echo "decrypted volume: $DECRYPTED_VOLUME_NAME"
	echo "crypttab: $CRYPTTAB"
	echo "crypttab conf: $CRYPTTAB_LINE"
else
	FSTAB_DEVICE="$ROOT_PARTITION_DEVICE"
	DECRYPTED_VOLUME_NAME=$(basename "$ROOT_PARTITION_DEVICE")
fi

FSTAB_LINE="$FSTAB_DEVICE $MOUNT_POINT $FS_TYPE $FSTAB_OPTIONS $FSTAB_DUMP_PASS"

echo "fstab: $FSTAB"
echo "fstab conf: $FSTAB_LINE"

sudo sed -i "/$DECRYPTED_VOLUME_NAME/d" "$FSTAB" 2>/dev/null
echo "$FSTAB_LINE" | sudo tee -a "$FSTAB" > /dev/null

OUTPUT_DIR="boot"
INITRD_FILENAME="initrd.img"
OUTPUT_FILE="${OUTPUT_DIR}/${INITRD_FILENAME}"

echo "Building initramfs"
sysroot_run_commands "$TEMP_SYSROOT_DIR" "
	depmod -a -v '$KERNEL_RELEASE'
	update-initramfs -v -c -k '$KERNEL_RELEASE'
	sync
	exit
	"

sudo sync
sleep 2

INITRAMFSDIR=$BASE_BUILD_DIR/initramfs
rm -rf $INITRAMFSDIR || true
mkdir -p $INITRAMFSDIR
INFILE="$TEMP_SYSROOT_DIR/$OUTPUT_DIR/${INITRD_FILENAME}-${KERNEL_RELEASE}"
#cp "$INFILE" "${INITRAMFSDIR}/"
#cpio -vmiudD "$INITRAMFSDIR" < "$INFILE"
unmkinitramfs "$INFILE" "${INITRAMFSDIR}/"
echo "merge '${INITRAMFSDIR}/early/usr' to '${INITRAMFSDIR}/main/usr'"
rsync -a "${INITRAMFSDIR}/early/usr/" "${INITRAMFSDIR}/main/usr"
sudo sync
echo "Initramfs available at $INITRAMFSDIR/main"
sleep 2

exit 0
