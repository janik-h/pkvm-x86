#!/bin/bash -e

USER=$(whoami)

#
# Arguments and defaults
#
[ -z "$PORT" ] && PORT=$((2000 + RANDOM % 1000))
[ -z "$KERNEL" ] && KERNEL="./bxImage"
[ -z "$IMAGE" ] && IMAGE="ubuntuguest.qcow2"
[ -z "$SPICEMNT" ] && SPICEMNT="/mnt/spice"
[ -z "$SPICESOCK" ] && SPICEPORT=$(($PORT+1)) && SPICESOCK="port=$SPICEPORT"
[ -z "$CORE" ] && CORE="off"
[ -z "$VMNAME" ] && VMNAME="vm_$PORT"
[ -z "$INPUT" ] && INPUT="-device virtio-keyboard-pci -device virtio-mouse-pci"

export TMPDIR=$SPICEMNT

usage() {
	echo "$0 -tcp|-unix|-core -image <disk image> -kernel <kernel file> -hw [hw name]"
	echo ""
	rm -f $SPICESOCK
	exit 1
}

extract() {
	if file $2 | grep -q compressed ; then
		echo "Extracting $1 $2.."
		gunzip $2
		export $1=$(basename $2 .gz)
	fi
}

cleanup() {
	rm -f $SPICESOCK
	exit 0
}

trap cleanup PWR HUP INT TERM EXIT

for i in "$@"; do
	case $i in
		-help)
			usage
			shift
		;;
		-tcp)
			SPICEPORT=$(($PORT+1))
			SPICESOCK="port=$SPICEPORT"
			shift
		;;
		-core)
			CORE="on"
			shift
		;;
		-debug)
			DEBUGOPTS="-S -s"
			shift
		;;
		-unix)
			SPICEPORT=$((0))
			SPICESOCK="unix=on,addr=$SPICEMNT/sock/linux$PORT"
			shift
		;;
		-name)
			VMNAME=$2
			shift; shift
		;;
		-image)
			IMAGE=$2
			shift; shift
		;;
		-kernel)
			KERNEL=$2
			shift; shift
		;;
		-hw)
			HW=$2
			shift; shift
		;;
		-cpuset)
			CPUSET=$2
			shift; shift
		;;
		-cpumems)
			CPUMEMS=$2
			shift; shift
		;;
		-usb3)
			INPUT="-device qemu-xhci -device usb-mouse -device usb-kbd -device usb-tablet"
			shift;
		;;
	esac
done

#
# Image exract when needed
#
extract KERNEL $KERNEL
extract IMAGE $IMAGE

[ ! -e "$KERNEL" ] && echo "Please provide a kernel image" && usage
[ ! -e "$IMAGE" ] && echo "Please provide a bootable system image image" && usage

#
# Detect network
#
status=0
ip route get 8.8.8.8 2>&1  > /dev/null || status=$?
if [ $status -eq 0 ]; then
	LOCALIF=$(ip route get 8.8.8.8 |awk '{print $5}')
	LOCALIP=$(ip route get 8.8.8.8 |awk '{print $7}')
else
	echo "For the VM networking support please enable the network"
	echo "before starting the VMs. Now starting with local networking"
	echo "only."
	LOCALIF="lo"
	LOCALIP="127.0.0.1"
fi

#
# Hardware specific configuration
#
if [ -n "$HW" ]; then
	if [ "$HW" = "imx8qmmek_1" ]; then
		CPUSET="0-3"
		CPUMEMS="0"
	fi
fi

#
# System configuration
#
if [ "$USER" = "root" ]; then
	[ ! -d /dev/net ] && mkdir /dev/net
	[ ! -c /dev/net/tun ] && mknod /dev/net/tun c 10 200 && chmod 0666 /dev/net/tun
	[ ! -d $SPICEMNT ] && mkdir -p $SPICEMNT && chmod 0777 $SPICEMNT
	[ -z "$(mount | grep $SPICEMNT)" ] && mount -t tmpfs -o size=1g tmpfs $SPICEMNT
	[ ! -d $SPICEMNT/sock ] && mkdir -p $SPICEMNT/sock && chmod 0777 $SPICEMNT/sock
	[ -d /dev/dri ] && chmod 0666 /dev/dri/render*

	if [ "$CORE" = "on" ]; then
		echo "%e.core.%p" > /proc/sys/kernel/core_pattern
		ulimit -c unlimited
	fi

	echo 1 > /proc/sys/net/ipv4/ip_forward
	iptables -t nat -A POSTROUTING -o $LOCALIF -j MASQUERADE

	if [ -z "$CPUSET" ]; then
		echo "Running default cpuset configuration.";
	else
		if [ -z "$CPUMEMS" ]; then
			echo "Invalid configuration: -cpuset without -cpumems"
		else
			echo "Setting up cpuset.cpus: $CPUSET with cpuset.mems: $CPUMEMS"
			[ ! -d /dev/cpuset ] && mkdir /dev/cpuset
			[ -z "$(mount | grep /dev/cpuset)" ] && mount -t cpuset none /dev/cpuset
			[ ! -d /dev/cpuset/$VMNAME ] && mkdir /dev/cpuset/$VMNAME
			echo $CPUSET > /dev/cpuset/$VMNAME/cpuset.cpus
			echo $CPUMEMS > /dev/cpuset/$VMNAME/cpuset.mems
			echo $$ > /dev/cpuset/$VMNAME/tasks
			echo "Running cpuset $(cat /proc/self/cpuset)"
		fi

	fi
else
	echo "The system configuration may not be up to date and the VM execution may fail."
	echo "Run as the user root if that happens or reconfigure the system manually."
fi

#
# Screen configuration
#
#VDAGENT="-device virtio-serial-pci -device virtserialport,chardev=spicechannel0,name=spice.0 -chardev spicevmc,id=spicechannel0,name=vdagent"
#SPICEOPTS="$SPICESOCK,disable-ticketing=on,image-compression=off,seamless-migration=on,streaming-video=all,playback-compression=off,disable-agent-file-xfer=off"
#SCREEN="-device virtio-gpu-pci -spice $SPICEOPTS $VDAGENT"
SCREEN="-nographic"

#
# Machine settings
#
[ -z "$MEM" ] && MEM=4096
MACHINE="-machine q35 -device intel-iommu,aw-bits=48,device-iotlb=on"
CPUFLAGS="+kvm-pv-enforce-cpuid,+vmx,-waitpkg,+ssse3,+tsc,+nx,-kvm-pv-ipi,-kvm-pv-tlb-flush,-kvm-pv-unhalt,-kvm-pv-sched-yield,-kvm-asyncpf-int,-kvm-pv-eoi"
CPU="--accel kvm,kernel-irqchip=on -cpu host,$CPUFLAGS -smp 2"

DRIVE="-drive file=$IMAGE,if=virtio,format=qcow2"
KERNEL_OPTS="rw root=/dev/vda1 selinux=0 nokaslr console=ttyS0 ignore_loglevel swiotlb=force noapic acpi=off"
NETOPTS="-device virtio-net-pci,netdev=net0 -netdev user,id=net0,host=192.168.8.1,net=192.168.8.0/24,restrict=off,hostname=guest$PORT,hostfwd=tcp:$LOCALIP:$PORT-192.168.8.3:22"
QEMUOPTS="${CPU} ${SMP} ${MACHINE} -m ${MEM} ${CONSOLE} ${NETOPTS} ${RNG} ${AUDIO} ${BALLOON} ${DEBUGOPTS} -L . "
if [ "$BIOS" = "1" ]; then
QEMUOPTS="$QEMUOPTS -bios coreboot-guest.rom"
fi

#[ -z "$AUDIO" ] && AUDIO="-audiodev spice,id=spice"
#[ -z "$CONSOLE" ] && CONSOLE="-chardev stdio,mux=on,id=vport0 -mon chardev=vport0,mode=readline -serial chardev:vport0 -device virtio-serial -device virtconsole,chardev=vport0,id=vport0"

#
# Finally the qemu invocation with some helper output
#
echo "Running qemu-system-x86_64 as user $USER"
echo "- Guest ssh access available at $LOCALIP:$PORT"
if [ $SPICEPORT -eq 0 ]; then
	echo "- Spice server at 'spice+unix:/$SPICESOCK'"
else
	echo "- Spice server at 'spice://$LOCALIP:$SPICEPORT'"
fi
echo "- Host wlan ip $LOCALIP"

qemu-system-x86_64 -name $VMNAME -kernel $KERNEL $DRIVE $INPUT \
	$PARTITIONS $SHARED_FS $SCREEN -append "$KERNEL_OPTS" $QEMUOPTS
exit 0
