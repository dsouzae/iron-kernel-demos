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
# the repo in a few minutes; demo/demo.sh is the Kubernetes capstone.
#
# The host runner (demo/tour-run.sh) watches for two markers:
#   ### HTTPD READY ###    it fetches a page through QEMU's port forward
#   ### DEMO COMPLETE ###  it stops QEMU
# Every step is best-effort: a failing command prints its error and the tour
# goes on, so the recording shows what the kernel actually did.
exec 2>&1
export PATH=/sbin:/bin:/usr/sbin:/usr/bin

BAR="===================================================================="
hr()   { echo; echo "$BAR"; }
say()  { echo; echo ">>> $*"; }
run()  { echo; echo "  \$ $*"; eval "$*"; }
pause(){ sleep "${1:-1}"; }

hr
echo "        iron-kernel  --  a Linux-syscall-compatible OS kernel, in Rust"
echo "        x86_64 . no_std . booted by GRUB/Multiboot2 . running in QEMU"
echo "        rootfs: a BusyBox cpio initramfs; init: go-init (a Go binary, PID 1)"
hr
pause 2

# ----------------------------------------------------------------------------
say "1. A real kernel speaking the Linux system-call ABI"
run "uname -a"
run "cat /proc/version"
run "head -6 /proc/cpuinfo"
run "grep -E 'MemTotal|MemFree' /proc/meminfo; echo nproc=\$(nproc)"
run "cat /proc/cmdline"
pause 2

# ----------------------------------------------------------------------------
say "2. Processes: fork/execve, pipelines, signals, job control"
run "cat /proc/ironvisor/ps"
run "seq 1 100000 | awk '{ s += \$1 } END { print \"sum of 1..100000 =\", s }'"
run "yes | head -3; echo \"(yes was ended by SIGPIPE when head closed the pipe)\""
run "sleep 30 & P=\$!; kill -TERM \$P; wait \$P; echo \"sleep exited with \$? (128+15: killed by SIGTERM)\""
run "{ time sh -c 'i=0; while [ \$i -lt 100 ]; do /bin/true; i=\$((i+1)); done'; } 2>&1 | grep real  # 100 x fork+execve"
pause 2

# ----------------------------------------------------------------------------
say "3. Files: an ext2 disk on virtio-blk, tmpfs, links, 16 MiB through the page cache"
run "grep -E 'ext2|/data' /proc/mounts; ls -l /data"
run "cat /data/hello.txt /data/subdir/nested.txt"
run "echo \"booted \$(date)\" >> /data/visits.log && sync && cat /data/visits.log  # persists across reboots"
run "mkdir -p /mnt/scratch && mount -t tmpfs none /mnt/scratch && grep scratch /proc/mounts"
run "echo 'written on iron-kernel' > /mnt/scratch/note; ln -s note /mnt/scratch/link; busybox ln /mnt/scratch/note /mnt/scratch/hard"
run "ls -l /mnt/scratch; cat /mnt/scratch/link; busybox stat -c '%n: %h links, inode %i' /mnt/scratch/hard"
run "dd if=/dev/urandom of=/mnt/scratch/blob bs=1M count=16 2>&1 | tail -1"
run "md5sum /mnt/scratch/blob; cp /mnt/scratch/blob /mnt/scratch/copy; md5sum /mnt/scratch/copy"
run "df /mnt/scratch"
pause 2

# ----------------------------------------------------------------------------
say "4. Unmodified userland: static musl C, and the Go runtime (threads, futexes, signals)"
run "/musl-hello"
run "mount -o bind /data /mnt   # go-hello's ext2 check reads /mnt/hello.txt"
run "/go-hello"
pause 2

# ----------------------------------------------------------------------------
say "5. The kernel's own instruments under /proc/ironvisor"
run "head -14 /proc/ironvisor/mem"
run "head -3 /proc/ironvisor/cpus"
run "cat /proc/ironvisor/clock"
pause 2

# ----------------------------------------------------------------------------
say "6. Container primitives: namespaces, chroot, cgroup v2 memory limits"
run "unshare -u sh -c 'hostname pod-a; echo \"inside the new UTS namespace: \$(hostname)\"'; echo \"outside, still: \$(hostname)\""
run "unshare -p -f sh -c 'echo \"in a new PID namespace, the shell is pid \$\$\"; tail -2 /proc/ironvisor/ps'"
run "mkdir -p /jail/bin && cp /bin/busybox /jail/bin/ && chroot /jail /bin/busybox sh -c 'echo \"chroot: / now holds: \$(busybox ls /)\"; busybox ls /bin'"
echo
echo "  \$ mkdir /sys/fs/cgroup/oomtest; echo 33554432 > /sys/fs/cgroup/oomtest/memory.max   # 32 MiB"
echo "  \$ /memhog     # joins the cgroup, then mmaps + touches 1 MiB chunks forever"
mkdir -p /sys/fs/cgroup/oomtest && echo 33554432 > /sys/fs/cgroup/oomtest/memory.max
/memhog; echo "memhog exited with $?  (137 = SIGKILL: the cgroup's OOM killer, not a stray SIGSEGV)"
run "cat /sys/fs/cgroup/oomtest/memory.max /sys/fs/cgroup/oomtest/memory.current 2>&1"
pause 2

# ----------------------------------------------------------------------------
say "7. Networking: the kernel's own TCP/IP stack on virtio-net (QEMU user-mode net)"
run "cat /proc/ironvisor/net"
run "ip route"
run "ping -c 2 10.0.2.2"
say "Start BusyBox httpd on :80 and fetch a page over loopback and over eth0:"
mkdir -p /www
cat > /www/index.html <<'EOF'
<html><body><h1>Hello from iron-kernel</h1>
<p>This page was served by BusyBox httpd running on an OS kernel written from scratch in Rust:
its own virtio-net driver, TCP/IP stack, sockets, epoll/poll, fork and execve.</p>
</body></html>
EOF
run "httpd -p 80 -h /www && echo 'httpd listening on 0.0.0.0:80'"
sleep 1
run "wget -q -O - http://127.0.0.1:80/"
run "wget -S -q -O /dev/null http://10.0.2.15:80/ 2>&1 | head -3"
say "Now the HOST makes a request into the VM through QEMU's port forward (127.0.0.1:8080 -> :80):"
echo "### HTTPD READY ###"
sleep 8
run "cat /proc/ironvisor/tcp"
pause 1

# ----------------------------------------------------------------------------
hr
echo "   One kernel, written from scratch in Rust: paging, scheduling, signals,"
echo "   VFS + ext2 on virtio-blk + tmpfs + procfs, namespaces, cgroups, a TCP/IP"
echo "   stack -- running unmodified BusyBox, musl and Go binaries, and serving"
echo "   HTTP to the host."
echo "   The Kubernetes capstone (CRI-O + kubelet + kube-proxy) is in demo/demo.sh."
hr
pause 1
echo
echo "### DEMO COMPLETE ###"
exit 0
