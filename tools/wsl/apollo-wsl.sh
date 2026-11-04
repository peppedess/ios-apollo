#!/bin/bash
# Run inside WSL (Ubuntu 24.04) as root, from tools on the Windows Desktop.
#   apollo-wsl.sh setup        packages + toolchain (UniXNU clang, ld64, mig, iig): once, ~1 h
#   apollo-wsl.sh xnu [REF]    build the SWEET kernel from peppedess/ios-apollo REF (default apollo)
# Outputs land in the Windows folder Desktop\ios-apollo\builds\xnu\<ref>-<sha>\
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
export BR=/root/apollo-build P=/mnt/c/Users/giuse/Desktop/ios-apollo
# No Xcode SDKs: the kernel only needs the macOS SDK's TargetConditionals.h (staging scripts 0019/0026 copy it, and
# xnu.sh's fakeroot). A minimal "SDK" holding UniXNU's copy of that header stands in for it.
export IOS_SDK=/nonexistent MAC_SDK=/root/apollo-macsdk
export JOBS=${JOBS:-8}   # WSL has 7 GB of RAM: 12 parallel LLVM compiles would swap
LB=/root/apollo-lb
say() { echo "[$(date +%T)] $*"; }
lb_scripts() {
	if [ ! -f "$LB/env.sh" ]; then
		rm -rf /root/lb-src && git init -q /root/lb-src
		git -C /root/lb-src fetch -q --depth 1 https://github.com/DenialOfGravity/ios-redfin.git tools-localbuild
		git -C /root/lb-src checkout -q FETCH_HEAD
		mkdir -p "$LB" && cp -a /root/lb-src/tools-claude/localbuild/. "$LB/"
	fi
	sed -i 's|^REPO_URL=.*|REPO_URL=https://github.com/peppedess/ios-apollo.git|' "$LB/env.sh"
	# The HFS staging patches (0031, 0041, 1030) need the 0026 script's output; xnu.sh runs it with MACHINE_CONFIG set.
	grep -q REPO_URL=https://github.com/peppedess "$LB/env.sh" && say "localbuild scripts ready ($LB)"
}
case ${1:-} in
setup)
	say "apt packages"
	apt-get update -qq && apt-get install -y -qq --no-install-recommends git patch flex bison bzip2 cpio rsync curl wget \
		ca-certificates tcsh unifdef cmake clang lld llvm mtools build-essential pkg-config ninja-build python3 python3-dev \
		xz-utils libssl-dev zlib1g-dev libbsd-dev uuid-dev llvm-dev libclang-dev device-tree-compiler ruby lz4 >/dev/null \
		|| { echo "APT FAILED"; exit 1; }
	lb_scripts
	cd "$LB" && time bash setup.sh xnu-tools
	echo "SETUP-EXIT=$?"
	;;
xnu)
	lb_scripts
	mkdir -p "$MAC_SDK/usr/include"
	cp "$BR/src/UniXNU/scripts/linux/TargetConditionals.h" "$MAC_SDK/usr/include/" || exit 1
	# libcc_kext (compiler-rt profile runtime) includes Libc's inttypes.h, which wants the SDK's Availability*.h:
	# XNU ships the same headers in EXTERNAL_HEADERS (pristine 13.5 source, cloned by xnu.sh into $BR/src).
	for d in "$BR"/src/xnu-8796.141.3/EXTERNAL_HEADERS "$BR"/work/xnu/xnu/EXTERNAL_HEADERS; do
		[ -f "$d/Availability.h" ] && cp "$d"/Availability*.h "$MAC_SDK/usr/include/" && break
	done
	# The SDK's Availability.h also has the SPI macros (Libc's private headers use them); XNU's copy does not.
	grep -q apollo-spi "$MAC_SDK/usr/include/Availability.h" || cat >> "$MAC_SDK/usr/include/Availability.h" <<'H'
/* apollo-spi: SPI availability macros of the macOS SDK's Availability.h, as no-ops (local WSL builds only) */
#ifndef __SPI_AVAILABLE
#define __SPI_AVAILABLE(...)
#endif
#ifndef __SPI_DEPRECATED
#define __SPI_DEPRECATED(...)
#endif
#ifndef __SPI_DEPRECATED_WITH_REPLACEMENT
#define __SPI_DEPRECATED_WITH_REPLACEMENT(...)
#endif
#ifndef __SPI_UNAVAILABLE
#define __SPI_UNAVAILABLE(...)
#endif
H
	ls "$MAC_SDK/usr/include"
	# BearSSL for xnu/patches/0020: bearssl.org's git answers 502 on and off. Keep a verified local copy of the
	# pinned commit (retried until it comes through) and hand it over as BEARSSL_DIR for when the live fetch fails.
	export BEARSSL_DIR=/root/bearssl-src/current
	bsha=7bea48e5e850ab4cafbe68d3765cdaba13a86d6f
	if [ "$(git -C "$BEARSSL_DIR" rev-parse HEAD 2>/dev/null)" != "$bsha" ]; then
		rm -rf "$BEARSSL_DIR"; mkdir -p "$BEARSSL_DIR"; git init -q "$BEARSSL_DIR"
		for t in $(seq 1 3); do
			git -C "$BEARSSL_DIR" fetch -q --depth 1 https://www.bearssl.org/git/BearSSL "$bsha" 2>/dev/null && break
			say "bearssl.org fetch $t failed, retrying"; sleep 15
		done
		git -C "$BEARSSL_DIR" checkout -q FETCH_HEAD 2>/dev/null
	fi
	if [ "$(git -C "$BEARSSL_DIR" rev-parse HEAD 2>/dev/null)" = "$bsha" ]; then
		say "BearSSL cached ($bsha)"
	elif [ -f "$BR/work/xnu/xnu/libkern/crypto/sweet_bearssl/src/inner.h" ]; then
		# An earlier run staged this commit's files into the build tree (18:07, when bearssl.org answered once):
		# rebuild the source layout 0020 copies from, with inner.h's include put back as upstream has it.
		export BEARSSL_DIR=/root/bearssl-src/from-tree
		rm -rf "$BEARSSL_DIR"; cp -a "$BR/work/xnu/xnu/libkern/crypto/sweet_bearssl" "$BEARSSL_DIR"
		python3 - "$BEARSSL_DIR/src/inner.h" <<'PY'
import sys
p = sys.argv[1]; t = open(p).read()
k = '#if defined(KERNEL)\n#include <machine/limits.h>\n#else\n#include <limits.h>\n#endif'
assert t.count(k) == 1, 'inner.h: staged include block not found'
open(p, 'w').write(t.replace(k, '#include <limits.h>'))
PY
		say "BearSSL from the earlier staged tree: $BEARSSL_DIR"
	else
		say "WARN BearSSL not available"
	fi

	cd "$LB" && time bash build.sh xnu "${2:-apollo}"
	echo "XNU-EXIT=$?"
	ls -la "$P"/builds/xnu/*/ 2>/dev/null | tail -12
	;;
*) echo "usage: apollo-wsl.sh setup | xnu [REF]"; exit 2;;
esac
