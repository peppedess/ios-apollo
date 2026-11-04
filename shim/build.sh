#!/bin/bash
# Build the apollo (Xiaomi 10T Pro, SM8250) shim and wrap it in a boot image v2
# (LineageOS sm8250-common BoardConfigCommon.mk, non-virtual-A/B: BOARD_BOOT_HEADER_VERSION 2,
# base 0x00000000, page 4096, DTB inside boot.img, boot partition 0x08000000).
# v2 carries its own DTB: ABL picks the entry matching the board (msm-id/board-id) from the
# concatenated kona DTBs, applies the dtbo partition and passes it in x0. The stock DTB
# comes from a LineageOS apollon boot.img (tools/apollo-dtb.sh): set DTB=path.
#
#   DTB=dtb shim/build.sh [PAYLOAD] [OUT]   PAYLOAD: tools/mkpayload.py output (ramdisk);
#                                           none -> probe-only image
#   SHIM_CFLAGS="-DSHIM_NO_UFS_WRITE -DSHIM_HOLDLOG" DTB=dtb shim/build.sh "" OUT
#                                           first probe: never write UFS (Android data still
#                                           in userdata), show the log on screen page by page, reset
#   SHIM_KERNEL=raw|lz4|gz                  kernel format in the image (default raw: LineageOS
#                                           apollon ships an uncompressed Image)
# Needs llvm + lld + lz4 + gzip + mkbootimg (AOSP) + avbtool.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd .. && pwd)
if [ -d /opt/homebrew/opt/llvm/bin ]; then
	LLVM=/opt/homebrew/opt/llvm/bin LLD=/opt/homebrew/opt/lld/bin
else
	LLVM=$(dirname "$(command -v clang)") LLD=$(dirname "$(command -v ld.lld)")
fi
CC="$LLVM/clang --target=aarch64-none-elf"
CFLAGS="-O2 -ffreestanding -nostdlib -fno-builtin -fno-pic -fno-pie -mgeneral-regs-only -mstrict-align
	-fno-stack-protector -fno-asynchronous-unwind-tables -Wall -Wextra ${SHIM_CFLAGS:-}"
SRCS="start.S shim.c console.c log.c util.c mmu.c fdt.c loader.c ufs.c spmi.c sde.c showlog.c diag.c disptest.c gpuprobe.c gpufw.S smmuprobe.c ramlog.c"
mkdir -p out
objs=
for f in $SRCS; do
	$CC $CFLAGS -c "$f" -o "out/${f%.*}.o"
	objs="$objs out/${f%.*}.o"
done
# The image runs wherever ABL puts it with no relocation pass: only the
# header's image_size (start.o, linked at 0) may be an absolute address.
abs=$($LLVM/llvm-readelf -r $(echo "$objs" | sed 's| out/start.o||') | grep -c R_AARCH64_ABS64 || true)
[ "$abs" = 0 ] || {
	$LLVM/llvm-readelf -r $(echo "$objs" | sed 's| out/start.o||') | grep -B5 R_AARCH64_ABS64 >&2
	echo "error: $abs absolute relocations in C objects" >&2
	exit 1
}
$LLD/ld.lld -static -nostdlib -T shim.ld --build-id=none -N $objs -o out/shim.elf
$LLVM/llvm-objcopy -O binary out/shim.elf out/Image
# ABL copies the file; pad to image_size so .bss/stacks exist as zeroed bytes.
size=$($LLVM/llvm-nm out/shim.elf | awk '$3=="_end"{print $1}')
truncate -s $((16#$size)) out/Image
case "${SHIM_KERNEL:-raw}" in
	raw) cp out/Image out/kernel ;;
	lz4) lz4 -q -9 -B7 -f out/Image out/kernel ;;
	gz) gzip -9 -n -c out/Image > out/kernel ;;
	*) echo "error: SHIM_KERNEL must be raw, lz4 or gz" >&2; exit 1 ;;
esac
if [ -n "${1:-}" ]; then
	cp "$1" out/ramdisk.bin
else
	# ABL dislikes a zero-size ramdisk on some builds: an empty newc cpio.
	# (Python fallback where cpio is missing, e.g. Git Bash on Windows: same bytes, a
	# newc archive holding only "." and the trailer.)
	if command -v cpio >/dev/null; then
		(cd out && rm -rf rd && mkdir rd && cd rd && find . | cpio -o -H newc --quiet | gzip -9 > ../ramdisk.bin)
	else
		python3 -I - out/ramdisk.bin <<'PY'
import gzip, sys
def ent(name, mode, nlink):
    n = name.encode() + b'\0'
    h = b'070701' + b''.join(b'%08X' % v for v in (0, mode, 0, 0, nlink, 0, 0, 0, 0, 0, 0, len(n), 0))
    h += n
    return h + b'\0' * (-len(h) % 4)
data = ent('.', 0o40755, 2) + ent('TRAILER!!!', 0, 1)
data += b'\0' * (-len(data) % 512)
open(sys.argv[1], 'wb').write(gzip.compress(data, 9))
PY
	fi
fi
OUT=${2:-out/shim-boot.img}
MKBOOTIMG=${MKBOOTIMG:-$(command -v mkbootimg || echo "python3 $ROOT/downloads/mkbootimg/mkbootimg.py")}
[ -n "${DTB:-}" ] && [ -s "$DTB" ] || { echo "error: set DTB to the stock apollon DTB (tools/apollo-dtb.sh)" >&2; exit 1; }
$MKBOOTIMG \
	--header_version 2 --base 0x00000000 --pagesize 4096 \
	--kernel out/kernel --ramdisk out/ramdisk.bin --dtb "$DTB" \
	--os_version 14.0.0 --os_patch_level 2023-11 \
	--cmdline "console=null" -o "$OUT"
# Unsigned hash footer (algorithm NONE), padded to the boot partition size like a
# LineageOS boot.img. Xiaomi's ABL does not need it when unlocked; it keeps
# "fastboot boot" and "fastboot flash boot" behaving the same.
AVBTOOL=${AVBTOOL:-$(command -v avbtool || echo "python3 $ROOT/downloads/avb/avbtool.py")}
$AVBTOOL add_hash_footer --image "$OUT" \
	--partition_size 134217728 --partition_name boot	# 0x08000000 (sm8250-common)
ls -l out/Image "$OUT"
