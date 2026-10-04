#!/bin/bash
# tour-run.sh — host side of the iron-kernel capabilities tour (`make demo`).
#
# Boots build/kernel.iso (built with KCMDLINE="demo datadisk=0", so go-init
# runs /demo-tour.sh and virtio-blk device 0 is the /data disk) under QEMU
# with user-mode networking and a copy of the repo's ext2 test disk
# (build/disk.img -> build/demo-data.img, so the tour's writes persist across
# runs without touching the build artifact). It relays the guest's serial
# console to stdout and plays the host's part when the guest asks for it:
# when the tour starts its web server it prints `### HTTPD READY ###`, and
# this script fetches a page through QEMU's port forward (host 127.0.0.1:8080
# -> guest :80) so the recording shows a request entering the kernel's TCP
# stack from outside the VM. It stops at `### DEMO COMPLETE ###` (or a halt /
# panic), then kills QEMU.
#
# Tunables (environment): ISO (default build/kernel.iso), DATA_IMG
# (build/demo-data.img), QEMU, QEMU_MEM (1024M), DEMO_HTTP_PORT (8080),
# DEMO_TIMEOUT (seconds of console silence before giving up; 900), DEMO_ACCEL
# ("kvm" / "tcg"; auto-detected).
#
# Record it:  asciinema rec -c demo/tour-run.sh demo/tour.cast   (make demo-cast)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
ISO=${ISO:-$ROOT/build/kernel.iso}
QEMU=${QEMU:-$(command -v qemu-system-x86_64 2>/dev/null || echo /usr/libexec/qemu-kvm)}
MEM=${QEMU_MEM:-1024M}
PORT=${DEMO_HTTP_PORT:-8080}
TIMEOUT=${DEMO_TIMEOUT:-900}

DATA_IMG=${DATA_IMG:-$ROOT/build/demo-data.img}

[ -r "$ISO" ] || { echo "tour-run: no ISO at $ISO (make iso KCMDLINE=\"demo datadisk=0\")" >&2; exit 2; }
if [ ! -f "$DATA_IMG" ]; then
    [ -r "$ROOT/build/disk.img" ] || { echo "tour-run: no $ROOT/build/disk.img to seed $DATA_IMG (make initramfs)" >&2; exit 2; }
    cp "$ROOT/build/disk.img" "$DATA_IMG"
fi

ACCEL=${DEMO_ACCEL:-}
if [ -z "$ACCEL" ]; then
    if [ -w /dev/kvm ]; then ACCEL=kvm; else ACCEL=tcg; fi
fi
case "$ACCEL" in
    kvm) ACCEL_ARGS="-enable-kvm -cpu host" ;;
    *)   ACCEL_ARGS="-cpu max" ;;
esac

QPID=
cleanup() {
    [ -n "$QPID" ] && { kill "$QPID" 2>/dev/null; sleep 0.5; kill -9 "$QPID" 2>/dev/null; }
}
trap cleanup EXIT INT TERM

echo "tour-run: $(basename "$QEMU") ($ACCEL), -m $MEM, /data = ${DATA_IMG#"$ROOT"/}, host 127.0.0.1:$PORT -> guest :80"
echo

# The guest's serial console is QEMU's stdout (-serial stdio; stdin is
# /dev/null so QEMU never touches the terminal's modes), read line by line
# below through a process substitution so QEMU's pid is still ours to kill.
# shellcheck disable=SC2086
exec 3< <("$QEMU" -cdrom "$ISO" -serial stdio -display none -monitor none \
    -no-reboot -no-shutdown -m "$MEM" $ACCEL_ARGS \
    -drive file="$DATA_IMG",if=virtio,format=raw \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"$PORT"-:80 \
    -device virtio-net-pci,netdev=net0 </dev/null 2>/dev/null)
QPID=$!

# The host's part: one request into the guest's web server through the port
# forward. curl if there is one, else wget, else python.
fetch() {
    local url="http://127.0.0.1:$PORT/"
    if command -v curl >/dev/null 2>&1; then
        curl -s -m 8 -i "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O - -T 8 -S "$url" 2>&1
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import sys,urllib.request as u; r=u.urlopen(sys.argv[1],timeout=8); print(r.status, r.reason); print(r.read().decode())' "$url"
    else
        echo "(no curl/wget/python3 on the host to make the request)"
    fi
}

rc=1
while IFS= read -r -t "$TIMEOUT" line <&3; do
    line=${line%$'\r'}
    case "$line" in
        *"[syscall] unhandled"*|*"[hb"*) continue ;;
    esac
    printf '%s\n' "$line"
    case "$line" in
        *"### HTTPD READY ###"*)
            echo
            echo "  host\$ curl -i http://127.0.0.1:$PORT/     # QEMU forwards this to the guest's :80"
            fetch | sed 's/^/  /' | tr -d '\r'
            echo
            ;;
        *"### DEMO COMPLETE ###"*) rc=0; break ;;
        *"KERNEL PANIC"*|*"Halting."*) break ;;
    esac
done
exec 3<&-
exit $rc
