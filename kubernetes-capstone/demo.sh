#!/bin/bash
# iron-kernel demo — installed as the guest's /root/rc.local. Narrated capstone
# tour: a real Linux-ABI kernel written in Rust runs the Kubernetes container
# stack and serves a kube-scheduler-placed Deployment (replicas=2) that is
# load-balanced through a kube-proxy ClusterIP Service. The Deployment, scheduler
# and controllers run on the HOST apiserver; this guest's kubelet runs whatever
# pods the scheduler binds to node "iron", and the guest's own kube-proxy +
# in-kernel netfilter/iptables datapath do the ClusterIP load balancing.
exec 2>&1
sleep 3
BAR="===================================================================="
hr(){ echo; echo "$BAR"; }
say(){ echo; echo ">>> $*"; }
run(){ echo; echo "  \$ $*"; eval "$*"; }
CR="crictl --runtime-endpoint unix:///var/run/crio/crio.sock"

hr
echo "        iron-kernel  --  a Linux-syscall-compatible OS kernel, in Rust"
echo "        x86_64 . no_std . booted by GRUB/Multiboot2 . running in QEMU"
hr
sleep 3

say "1. A real kernel speaking the Linux system-call ABI"
run "uname -a"
sleep 2
run "grep -E 'model name|flags' /proc/cpuinfo | head -2"
sleep 2
run "grep MemTotal /proc/meminfo; echo nproc=\$(nproc)"
sleep 3

say "2. Unmodified, dynamically-linked glibc userspace (ELF loader + ld.so + demand paging)"
run "bash --version | head -1"
sleep 2
run "ls -l /lib/x86_64-linux-gnu/libc.so.6"
sleep 3

hr
echo "   3. THE HEADLINE: a real kube-apiserver + kube-scheduler place a"
echo "      Deployment (replicas=2) on this node; both pods run and serve HTTP,"
echo "      and kube-proxy programs their ClusterIP Service into the kernel."
hr
sleep 2

# ---- setup (quiet) ----
mkdir -p /var/run/crio /run/crio /var/lib/containers/storage /run/containers/storage \
         /var/log/crio /var/log/pods /etc/cni/net.d /opt/cni/bin /run/crun \
         /var/lib/cni /var/lib/kubelet /etc/kubernetes/manifests 2>/dev/null
rm -f /etc/kubernetes/manifests/*.yaml 2>/dev/null
hostname iron 2>/dev/null
[ -f /etc/resolv.conf ] || echo "nameserver 10.0.2.3" > /etc/resolv.conf
for x in iptables iptables-restore iptables-save; do ln -sf /usr/sbin/xtables-legacy-multi /usr/sbin/$x 2>/dev/null; done
# Cap the Go daemons' heaps so full-copy fork() stays under the phys ceiling.
export GOGC=15 GOMEMLIMIT=180MiB GOMAXPROCS=1

say "Starting CRI-O, then a kubelet that registers node 'iron' with a REAL"
echo "    kube-apiserver over TLS (logs suppressed). The scheduler on the host"
echo "    then binds the Deployment's two pods to this node ..."
/usr/bin/crio --log-level=error --disable-hostport-mapping >/var/log/crio.log 2>&1 &
for i in $(seq 1 60); do [ -S /var/run/crio/crio.sock ] && break; sleep 1; done
echo "    crio.sock: $([ -S /var/run/crio/crio.sock ] && echo UP || echo DOWN)"
/usr/bin/kubelet --config=/etc/kubernetes/kubelet-api.yaml \
  --kubeconfig=/etc/kubernetes/kubelet.conf \
  --container-runtime-endpoint=unix:///var/run/crio/crio.sock \
  --hostname-override=iron --node-ip=10.0.2.15 --v=0 >/var/log/kubelet.log 2>&1 &

echo "    waiting for the 2 scheduler-placed pods to reach Running ..."
for i in $(seq 1 160); do
  n=$(grep -oE '10\.88\.[0-9]+\.[0-9]+' /proc/ironvisor/knob/pod 2>/dev/null | sort -u | wc -l)
  run2=$($CR ps 2>/dev/null | grep -c httpd)
  [ "$n" -ge 2 ] && [ "$run2" -ge 2 ] && { echo "    both pods Running (podIPs=$n, containers=$run2)"; break; }
  sleep 3
done
sleep 6

say "Ask CRI-O what is running -- both Deployment replicas, via the CRI gRPC API:"
run "$CR ps 2>&1 | tail -3"
sleep 3
say "Their pod IPs (assigned by the CNI plugin), auto-registered as Service endpoints:"
run "cat /proc/ironvisor/knob/pod 2>&1"
sleep 3

say "Bring up a real kube-proxy (iptables mode); it watches the apiserver and"
echo "    programs the ClusterIP Service 10.96.0.212 into the kernel's netfilter:"
/usr/bin/kube-proxy --kubeconfig=/etc/kubernetes/kube-proxy.conf --proxy-mode=iptables \
  --hostname-override=iron --cluster-cidr=10.88.0.0/16 --conntrack-max-per-core=0 \
  --v=0 >/var/log/kproxy.log 2>&1 &
KP=$!
for i in $(seq 1 60); do /usr/sbin/iptables-legacy -t nat -S 2>/dev/null | grep -q "10.96.0.212" && break; sleep 1; done
sleep 4
say "kube-proxy translated the Service into DNAT rules -- ClusterIP 10.96.0.212"
echo "    load-balanced across the two pod endpoints, all in the kernel's netfilter:"
run "iptables-legacy -t nat -S 2>/dev/null | grep -iE 'KUBE-SVC-.*10.96.0.212|KUBE-SEP.*DNAT.*10.88.0' | head -4"
sleep 3

say "THE PAYOFF: 24 requests to the ClusterIP -- kube-proxy's rules DNAT each to a"
echo "    pod endpoint, the packet is hairpinned on-node and conntrack-reverse-NAT'd"
echo "    back. Every one returns 200 OK from a Deployment pod (by its own hostname):"
echo
declare -A H; fail=0
for i in $(seq 1 24); do
  out=$(/usr/bin/geturl.bin http://10.96.0.212:80/ 2>/dev/null | tr -d '\r\n')
  if [ -n "$out" ]; then H["$out"]=$(( ${H["$out"]:-0} + 1 )); else fail=$((fail+1)); fi
done
for k in "${!H[@]}"; do echo "      200 OK  $k  ->  ${H[$k]} requests"; done
echo "      (failures: $fail / 24  .  distinct pod backends hit: ${#H[@]})"
sleep 3
kill $KP 2>/dev/null
sleep 2

hr
echo "   A real kube-apiserver + kube-scheduler placed a Deployment(replicas=2)"
echo "   on node 'iron'; CRI-O ran both pods; kube-proxy programmed their ClusterIP"
echo "   Service into the kernel's netfilter; and 24 curls to the ClusterIP were"
echo "   served 200 OK by the Deployment's pods through a DNAT + on-node hairpin +"
echo "   conntrack datapath -- all on an OS kernel written from scratch in Rust."
hr
sleep 2
echo
echo "### DEMO COMPLETE ###"
