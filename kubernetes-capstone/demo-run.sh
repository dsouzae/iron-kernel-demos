#!/bin/bash
D=/home/edsouza/ironk/demo3
FIFO=/tmp/dser3.$$; rm -f "$FIFO"; mkfifo "$FIFO"
qemu-system-x86_64 -enable-kvm -cpu host -cdrom "$D/kernel.iso" \
  -serial "file:$FIFO" -display none -no-reboot -no-shutdown -m 8192 \
  -drive file="$D/root.img",if=virtio,format=raw \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 >/dev/null 2>&1 &
QPID=$!
while IFS= read -r -t 900 line; do
  case "$line" in *"[hb"*|*"[syscall] unhandled"*|*"cannot set terminal"*|*"no job control"*) continue;; esac
  printf '%s\n' "$line"
  case "$line" in *"### DEMO COMPLETE ###"*) break;; esac
done < "$FIFO"
sleep 1; kill "$QPID" 2>/dev/null; sleep 1; kill -9 "$QPID" 2>/dev/null; rm -f "$FIFO"
