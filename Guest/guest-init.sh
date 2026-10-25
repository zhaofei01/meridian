#!/bin/busybox sh
# Pid 1 for the Meridian guest. The virtual machine has no network card.
/bin/busybox --install -s

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts /tmp /run /workspace /root /etc
mount -t devpts devpts /dev/pts
mount -t tmpfs tmpfs /tmp

if [ -x /sbin/modprobe ]; then
    MP=/sbin/modprobe
else
    MP=modprobe
fi

$MP virtio_pci 2>/dev/null || true
$MP virtio_mmio 2>/dev/null || true
$MP virtio_console 2>/dev/null || true
$MP fuse 2>/dev/null || true
$MP virtiofs 2>/dev/null || true
$MP vmw_vsock_virtio_transport 2>/dev/null || true
$MP vsock 2>/dev/null || true

if [ -c /dev/hvc0 ]; then
    exec >/dev/hvc0 2>&1
fi

echo "meridian: drivers loaded"
dmesg | tail -n 60 || true

mounted=0
i=0
while [ "$i" -lt 30 ]; do
    if mount -t virtiofs project /workspace; then
        mounted=1
        break
    fi
    i=$((i + 1))
    sleep 1
done

if [ "$mounted" -eq 1 ]; then
    echo "meridian: workspace mounted"
else
    echo "meridian: workspace mount failed"
fi

hostname meridian 2>/dev/null || true
export MERIDIAN_WORKSPACE_MOUNTED="$mounted"
exec /usr/bin/python3 -u /usr/local/bin/meridian-agent
