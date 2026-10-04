# iron-kernel demos

**iron-kernel** is an operating system kernel written from scratch in Rust
that speaks the Linux system-call ABI. It is not a Linux fork and contains no
Linux code: its paging, scheduler, VFS, signals, namespaces, cgroups,
netfilter, eBPF and TCP/IP stack are its own, and **unmodified Linux
binaries** run on them: BusyBox, glibc and musl programs, Go, and all the way
up to CRI-O, a kubelet and kube-proxy.

The kernel's source is not public. These recordings are what it does.

---

## A real Kubernetes node, on a kernel that is not Linux

![Kubernetes on iron-kernel](kubernetes-capstone/demo.gif)

A real **kube-apiserver + kube-scheduler** place a `Deployment` (replicas=2)
on node `iron`. The node's **kubelet** and **CRI-O** run both pods. A real
**kube-proxy** programs the pods' **ClusterIP Service** into the kernel's own
netfilter. Then 24 requests to the ClusterIP come back `200 OK` from the
pods, load-balanced through the kernel's DNAT, on-node hairpin and conntrack
reverse-NAT.

All of that userland is stock: Debian 13, the upstream Kubernetes and CRI-O
binaries, unmodified. Only the kernel underneath is new.

Details, the scripts and the asciicast: [`kubernetes-capstone/`](kubernetes-capstone/README.md).

---

## The 40-second tour

The same kernel, booting a BusyBox initramfs under QEMU, running a shell
script live on its serial console. Six beats, each ending in a line you can
check without knowing the kernel.

**Boot.** GRUB loads the kernel by Multiboot2; it sets up memory, finds the
virtio NIC and disk, mounts the initramfs, and starts `init`.

![boot](tour/gifs/00-boot.gif)

**1. It presents the Linux ABI.** `uname`, procfs, a BusyBox shell.

![the Linux ABI](tour/gifs/01-linux-abi.gif)

**2. Unmodified binaries run on it.** A static musl C program, then a Go
program whose runtime needs threads, futexes, signals, sockets, eBPF and a
PTY from the kernel. 21 of 21 checks pass.

![musl and Go](tour/gifs/02-unmodified-binaries.gif)

**3. Processes.** A 100,000-line `seq | awk` pipeline; a background `sleep`
killed with SIGTERM comes back as exit 143; 100 `fork`+`execve` cycles, timed.

![processes and signals](tour/gifs/03-processes.gif)

**4. A real disk.** An ext2 filesystem on a **virtio-blk** device, mounted
writable at `/data`. The boot log it appends to survives reboots; 16 MiB
written through the page cache checksums identically on both sides.

![ext2 on virtio-blk](tour/gifs/04-ext2-disk.gif)

**5. Container primitives.** A new UTS namespace with its own hostname, a
new PID namespace where the shell is pid 1, and a **cgroup v2 memory limit**:
`memhog` joins a 32 MiB cgroup, allocates past it, and is OOM-killed, exit
137, not a stray segfault.

![namespaces and cgroups](tour/gifs/05-containers.gif)

**6. Its own TCP/IP stack.** `ping` out to the gateway over virtio-net;
BusyBox `httpd` serves a page over loopback; then **the host** fetches that
page through QEMU's port forward, a request entering the kernel's TCP stack
from outside the VM.

![networking](tour/gifs/06-network.gif)

**Scoreboard.**

![scoreboard](tour/gifs/07-scoreboard.gif)

The whole thing in one piece: [`tour/tour.gif`](tour/tour.gif) (3 MB), or
the asciicast [`tour/tour.cast`](tour/tour.cast) for copy-pasteable text
(`asciinema play tour/tour.cast`). Recorded under QEMU TCG, no KVM, in a
4-vCPU container; the kernel boots to the tour in about ten seconds there.

### What made it

Copied here for reference; they run from the kernel's own build tree.

- [`tour/demo-tour.sh`](tour/demo-tour.sh): the guest side, BusyBox `ash`,
  run by the kernel's init when it boots with the `demo` token.
- [`tour/tour-run.sh`](tour/tour-run.sh): the host side. Boots the ISO under
  QEMU with user-mode networking and the ext2 test disk, relays the serial
  console (boot chatter trimmed to a few lines), makes the host-side HTTP
  request when the guest says `### HTTPD READY ###`.
- [`tour/split-cast.py`](tour/split-cast.py): cuts the asciicast at each
  section heading and renders the pieces with
  [`agg`](https://github.com/asciinema/agg).

---

## Beyond the recordings

Debian 13 boots from an ext2 disk root into a real `agetty`/`bash` login over
serial; dynamically-linked glibc binaries run through `ld.so`; CoreDNS runs
as a pod and Services resolve by name; `NetworkPolicy` objects are reconciled
into in-kernel drop rules; a sound eBPF verifier feeds an x86-64 JIT; and the
aarch64 port runs as a Kubernetes node on a Raspberry Pi 5 under KVM.

---

*Built with substantial help from Claude (Anthropic) as a pair-programming
collaborator.*
