# The Kubernetes capstone

A real **kube-apiserver + kube-scheduler place a Deployment (replicas=2)** onto
a node whose kubelet + CRI-O run both pods, and a real **kube-proxy** programs
their **ClusterIP Service** into the kernel's own netfilter — all on an OS
kernel written from scratch in Rust.

![demo](demo.gif)

The tour shows, in order:

1. **A real Linux-ABI kernel** — `uname`, `/proc/cpuinfo`, `/proc/meminfo`.
2. **Unmodified glibc userspace** — GNU bash 5.2 and `libc.so.6` (ELF loader +
   `ld.so` + demand paging all working).
3. **The Kubernetes control + container stack** — the guest's kubelet registers
   node `iron` with a real kube-apiserver over TLS; the **kube-scheduler** (on
   the host) binds a `Deployment(replicas=2)` to the node; CRI-O runs both pods
   to `Running` (`crictl ps` shows the two `iron-web-*` httpd pods); and a real
   **kube-proxy** (iptables mode) syncs the `iron-web` ClusterIP Service into the
   guest's in-kernel netfilter — the `KUBE-SERVICES → KUBE-SVC → KUBE-SEP` DNAT
   rules to the two `10.88.0.x` pod endpoints are shown live.
4. **The payoff** — 24 requests to the ClusterIP `10.96.0.212` each return
   `200 OK` from a Deployment pod, served through the kernel's own
   DNAT + on-node hairpin + conntrack reverse-NAT datapath.

## Watch it

- **asciinema cast**: [`demo.cast`](demo.cast) — sharp and copy-pasteable.
  Play locally with `asciinema play demo.cast`.
- **GIF**: [`demo.gif`](demo.gif) — regenerate with `agg`, see below.

## Reproduce it

The recording is made on a KVM host that also runs the k8s control plane
(etcd + kube-apiserver + the controllers/scheduler, and the `iron-web`
Deployment + ClusterIP Service). `demo.sh` is the guest's `rc.local` (the
narrated tour); `demo-run.sh` boots the kernel ISO + rootfs under QEMU, relays
the serial console to stdout (dropping kernel-internal noise), and stops when
the demo prints its completion marker.

```sh
# guest side: demo.sh is installed as /root/rc.local in the rootfs image
# host side: record the serial console into an asciicast
asciinema rec -y --idle-time-limit 3 --cols 155 --rows 42 -c ./demo-run.sh demo.cast
agg --theme monokai --font-size 14 demo.cast demo.gif   # optional GIF (wide)
```

`demo-run.sh` expects `kernel.iso` (the iron-kernel ISO) and `root.img` (the
Debian rootfs, with the CRI-O/kubelet/kube-proxy binaries, the httpd image
preloaded into the containers-storage vfs store, a CNI plugin in `/opt/cni/bin`,
and the kubeconfigs pointing at the host apiserver) alongside it, and boots with
`-m 8192` (the full control-plane workload needs the headroom). The pods take a
few minutes to schedule and start under KVM; the `--idle-time-limit` flag
compresses that wait in the recording.

> Note: the CNI plugin satisfies the CNI contract so each pod gets a
> `10.88.0.x` IP and reaches `Running`, kube-proxy programs the real Service DNAT
> rules into the kernel's netfilter, and the 24 curls reach a pod end to end via
> the in-kernel DNAT + on-node hairpin + conntrack datapath (all `200 OK`), and
> the 24 requests are load-balanced across **both** pod endpoints (e.g. 11/13) —
> kube-proxy's `statistic` DNAT picks a backend per connection, and each pod runs
> in its own network namespace (real `setns` placement) so its `0.0.0.0:80`
> listener is a distinct pod-IP listener rather than colliding on the shared
> stack. The exact split varies per boot; both endpoints serve.
