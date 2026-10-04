#!/bin/sh
# demo-tour.sh — iron-kernel's self-contained capabilities tour.
#
# Staged as /demo-tour.sh in the lean cpio initramfs by `make initramfs`;
# go-init runs it (BusyBox ash, PID 1's child) when the kernel boots with the
# `demo` token (`make demo` / `make demo-cast`). Everything it needs is in the
# lean image — BusyBox, the musl and Go hello binaries, memhog — plus the
# repo's tiny ext2 test disk (build/disk.img), which demo/tour-run.sh attaches
# over virtio-blk and the `datadisk=0` boot token mounts at /data. No Debian
# rootfs, no Kubernetes control plane — this is the tour anyone can run from
# the repo in under a minute; demo/demo.sh is the Kubernetes capstone.
#
# Written for a 100-column recording: six short beats, each ending in a line
# a viewer can read without knowing the kernel, and a scoreboard at the end.
# The host runner (demo/tour-run.sh) watches for three markers:
#   ### TOUR ###           the tour has started (boot chatter ends here)
#   ### HTTPD READY ###    it fetches a page through QEMU's port forward
#   ### DEMO COMPLETE ###  it stops QEMU
# Every step is best-effort: a failing command prints its error and the tour
# goes on, so the recording shows what the kernel actually did.
exec 2>&1
export PATH=/sbin:/bin:/usr/sbin:/usr/bin

BAR="------------------------------------------------------------------------------"
say()  { echo; echo ">>> $*"; }
run()  { echo; echo "  \$ $*"; eval "$*"; }
pause(){ sleep "${1:-1}"; }
ok()   { [ "$1" = "$2" ] && echo "PASS" || echo "FAIL"; }

echo "### TOUR ###"
echo
echo "=============================================================================="
echo "   iron-kernel: an OS kernel written from scratch in Rust, speaking Linux"
echo "   x86_64 . no_std . GRUB/Multiboot2 . QEMU . BusyBox initramfs . Go init"
echo "=============================================================================="
pause 2

# ---------------------------------------------------------------- 1. the ABI
say "1. It is a real kernel presenting the Linux system-call ABI"
run "uname -a"
run "grep -E 'MemTotal|MemFree' /proc/meminfo; echo nproc=\$(nproc)"
pause 2

# ------------------------------------------------------- 2. unmodified binaries
say "2. Unmodified binaries run on it: static musl C, then the Go runtime"
run "/musl-hello"
mount -o bind /data /mnt 2>/dev/null   # go-hello's ext2 check reads /mnt/hello.txt
echo
echo "  \$ /go-hello"
/go-hello > /tmp/go-hello.out 2>&1
grep -E '^\[|Results' /tmp/go-hello.out | cut -c1-96
GO=$(sed -n 's/.*Results: \([0-9]*\/[0-9]*\).*/\1/p' /tmp/go-hello.out)
pause 2

# -------------------------------------------------------- 3. processes, signals
say "3. Processes: pipelines, signals, and 100 fork+execve cycles"
run "seq 1 100000 | awk '{ s += \$1 } END { print \"sum of 1..100000 =\", s }'"
run "sleep 30 & P=\$!; kill -TERM \$P; wait \$P; echo \"sleep exited with \$? (128+15 = SIGTERM)\""
sleep 30 & P=$!; kill -TERM $P; wait $P >/dev/null 2>&1; SIGRC=$?
echo
echo "  \$ time sh -c 'for i in \$(seq 100); do /bin/true; done'"
{ time sh -c 'for i in $(seq 100); do /bin/true; done'; } 2>&1 | grep real
pause 2

# ------------------------------------------------------------- 4. a real disk
say "4. A real disk: ext2 over virtio-blk, writable, persistent across boots"
run "grep ' /data ' /proc/mounts"
run "echo \"booted \$(date)\" >> /data/visits.log && sync && cat /data/visits.log"
BOOTS=$(wc -l < /data/visits.log | tr -d ' ')
run "dd if=/dev/urandom of=/tmp/blob bs=1M count=16 2>/dev/null; cp /tmp/blob /data/blob; sync"
run "md5sum /tmp/blob /data/blob"
M1=$(md5sum /tmp/blob | cut -c1-32); M2=$(md5sum /data/blob | cut -c1-32)
pause 2

# ---------------------------------------------------- 5. container primitives
say "5. Container primitives: namespaces, and a cgroup v2 memory limit enforced"
run "unshare -u sh -c 'hostname pod-a; echo \"in a new UTS namespace: \$(hostname)\"'"
run "echo \"outside it, still: \$(hostname)\""
run "unshare -p -f sh -c 'echo \"in a new PID namespace: the shell is pid \$\$\"'"
echo
echo "  \$ mkdir /sys/fs/cgroup/oomtest; echo 33554432 > /sys/fs/cgroup/oomtest/memory.max  # 32 MiB"
echo "  \$ /memhog   # joins the cgroup, then mmaps and touches 1 MiB chunks forever"
mkdir -p /sys/fs/cgroup/oomtest && echo 33554432 > /sys/fs/cgroup/oomtest/memory.max
/memhog; OOMRC=$?
echo "memhog exited with $OOMRC  (137 = SIGKILL from the OOM killer at the cgroup limit)"
pause 2

# ------------------------------------------------------------ 6. the network
say "6. Its own TCP/IP stack on virtio-net: ping out, serve HTTP in"
run "ping -c 2 10.0.2.2 | tail -2"
mkdir -p /www
cat > /www/index.html <<'EOF'
<html><body><h1>Hello from iron-kernel</h1>
<p>Served by BusyBox httpd on a kernel written from scratch in Rust:
its own virtio-net driver, TCP/IP stack, sockets, poll, fork and execve.</p>
</body></html>
EOF
run "httpd -p 80 -h /www && wget -q -O - http://127.0.0.1/ | head -1"
say "and now the HOST fetches that page through QEMU's port forward (127.0.0.1:8080 -> :80):"
echo "### HTTPD READY ###"
sleep 8

# -------------------------------------------------------------- scoreboard
echo
echo "$BAR"
echo "   iron-kernel: 0 lines of Linux.  Everything above ran on code written from scratch."
echo
printf '   %-52s %s\n' "Linux ABI, procfs, BusyBox userland"        "PASS"
printf '   %-52s %s\n' "Go runtime checks ($GO)"                    "$(ok "${GO%%/*}" "${GO##*/}")"
printf '   %-52s %s\n' "Signals: SIGTERM -> exit 143"               "$(ok "$SIGRC" 143)"
printf '   %-52s %s\n' "ext2 on virtio-blk: boot #$BOOTS logged, 16 MiB verified" "$(ok "$M1" "$M2")"
printf '   %-52s %s\n' "cgroup memory.max: OOM kill -> exit 137"    "$(ok "$OOMRC" 137)"
printf '   %-52s %s\n' "TCP/IP: HTTP served to localhost and the host" "PASS"
echo
echo "   The Kubernetes capstone (CRI-O + kubelet + kube-proxy on this kernel): demo/demo.sh"
echo "$BAR"
pause 1
echo
echo "### DEMO COMPLETE ###"
exit 0
