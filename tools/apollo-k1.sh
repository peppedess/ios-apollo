#!/bin/bash
# Build the apollo k1 boot image: XNU (read-only first boot) + ADT in a SWEETXNU payload, inside the shim's boot image.
#   tools/apollo-k1.sh KERNEL(.gz) DTB OUT.img [EXTRA BOOT-ARGS...]
# k1 = the first XNU boot: RAM only, the shim never writes UFS (SHIM_NO_UFS_WRITE) and the kernel refuses UFS writes
# (ufsrw=0 rootrw=0, no log thread: sweetlog=0). Expected: XNU console on screen, 8 CPUs, UFS userdata found read-only,
# then "cannot mount root" (userdata still holds Android) until flamereboot resets to fastboot.
# Drivers that still carry Pixel 5 (lito) addresses stay off: USB, touch, GPU/Metal, cpufreq (kona's cpufreq-hw differs).
set -euo pipefail
cd "$(dirname "$0")/.."
K=${1:?kernel} DTB=${2:?dtb} OUT=${3:?out.img}; shift 3
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
case "$K" in *.gz) gunzip -c "$K" > "$W/kernel";; *) cp "$K" "$W/kernel";; esac
# mkpayload reads kernel symbols with `nm`: it must understand Mach-O (LLVM's nm, not GNU's)
mkdir -p "$W/bin"; ln -s "$(command -v llvm-nm)" "$W/bin/nm"; export PATH="$W/bin:$PATH"
python3 tools/mkadt.py "$W/apollo-hi.adt" --highmem >/dev/null
args="debug=0xc serial=3 cpus=8 keepsyms=1 -enable_kprintf_spam -noprogress"
args="$args rd=ufsroot0 ufsrw=0 rootrw=0 sweetlog=0 flamereboot=150 wdt=-1"
args="$args sweetfb_noconsole=0 sweetfb_hz=60 sweetfb_thread=0"
args="$args sweetusb=0 flametouch=0 sweettouch=0 sectouch=0 sweetkeys=1 sweetgpu=0 sweetmtl=0 sweetddr=0"
args="$args flamecpufreq=0 sweetbattery=0 sweettherm=0"
# Extra KEY=VALUE args replace the defaults above (the kernel takes the first occurrence of a key)
for a in "$@"; do
	k=${a%%=*}
	args=$(printf '%s\n' $args | grep -v -x -e "$k" -e "$k=.*" | tr '\n' ' ')
done
args="$args $*"
python3 -I tools/mkpayload.py "$W/kernel" "$W/apollo-hi.adt" "$W/payload" --cmdline "$args"
SHIM_CFLAGS="-DSHIM_NO_UFS_WRITE" SHIM_KERNEL=raw DTB="$DTB" bash shim/build.sh "$W/payload" "$OUT"
# Shrink the AVB padding (fastboot boot needs no full 128 MiB partition image; the bridge takes <100 MB per file)
AVB=${AVBTOOL:-python3 downloads/avb/avbtool.py}
$AVB erase_footer --image "$OUT"
size=$(stat -c %s "$OUT"); part=$(( (size + 4096 * 2 + 0xfffff) / 0x100000 * 0x100000 ))
truncate -s %4096 "$OUT"
$AVB add_hash_footer --image "$OUT" --partition_size $part --partition_name boot
echo "$args" > "$OUT.cmdline"
ls -l "$OUT"; sha256sum "$OUT"
echo "boot-args: $args"
