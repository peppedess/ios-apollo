#!/bin/bash
# Stock DTB for apollo (Xiaomi 10T Pro / Mi 10T / Redmi K30S Ultra, "apollon" in LineageOS).
# A boot image v2 must carry it: ABL picks the matching kona entry and applies dtbo.
#
#   tools/apollo-dtb.sh OUT.dtb [boot.img]
#     with boot.img: extract from it (e.g. backup\boot.img from apollo-recon.ps1)
#     without:       download the latest LineageOS apollon boot.img and extract from it
#
# The DTB is a build artifact of LineageOS's GPL kernel (no serial or IMEI in it), but
# like everything taken from the phone it stays out of git (AGENTS.md): CI makes it on
# each run. Needs python3 and AOSP mkbootimg's unpack_bootimg.py (UNPACK=...).
set -euo pipefail
OUT=${1:?usage: tools/apollo-dtb.sh OUT.dtb [boot.img]}
BOOT=${2:-}
UNPACK=${UNPACK:-python3 $(cd "$(dirname "$0")/.." && pwd)/downloads/mkbootimg/unpack_bootimg.py}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [ -z "$BOOT" ]; then
	API=https://download.lineageos.org/api/v2/devices/apollon/builds
	curl -fsSL "$API" -o "$TMP/builds.json"
	URL=$(python3 -I - "$TMP/builds.json" <<'PY'
import json, sys
builds = json.load(open(sys.argv[1]))
for b in builds:
    for f in b.get("files", []):
        if f.get("filename") == "boot.img":
            print(b.get("version", "?"), b.get("date", "?"), f["url"], file=sys.stderr)
            print(f["url"])
            sys.exit(0)
sys.exit("no boot.img in the LineageOS apollon builds")
PY
)
	curl -fsSL "$URL" -o "$TMP/boot.img"
	BOOT=$TMP/boot.img
fi

$UNPACK --boot_img "$BOOT" --out "$TMP/u" > "$TMP/info.txt"
grep -E "boot image header version|page size|dtb size" "$TMP/info.txt" || true
[ -s "$TMP/u/dtb" ] || { echo "error: $BOOT has no DTB (not a header v2 apollo boot.img?)" >&2; exit 1; }
# Concatenated FDTs: count them, and check one is for apollo (kona, msm-id 356).
python3 -I - "$TMP/u/dtb" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
n, off = 0, 0
while off + 8 <= len(d):
    magic, size = struct.unpack(">II", d[off:off + 8])
    if magic != 0xd00dfeed or size == 0:
        break
    n += 1
    off += size
print(f"dtb: {n} FDT(s), {len(d)} bytes, apollo strings: {d.count(b'apollo')}")
if n == 0:
    sys.exit("error: no FDT found")
PY
cp "$TMP/u/dtb" "$OUT"
sha256sum "$OUT"
