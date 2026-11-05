#!/bin/bash
# apollo: put SweetMetal2.bundle (Metal on Turnip, the redfin/sunfish metal2 CI build) into the iOS root image in WSL,
# so `apollo-wsl.sh install delta` carries it to the phone. Boot with sweetmtl=2 (and sweetgpu=1) afterwards.
#   bash tools/apollo-metal2-wsl.sh [REF]      REF: branch of DenialOfGravity/ios-redfin with the bundle (builds-metal2)
# Writes into the image (WSL's own disk, /root/apollo-root/iosroot.img), never to the phone:
#   /System/Library/Extensions/SweetMetal2.bundle   (SweetMetal2, libvulkan_freedreno.dylib with FD650, Info.plist, ...)
#   /private/var/local/mtl2-clients                 "* -chronod" (HANDOFF.md: every process on Metal but chronod,
#                                                   whose widgets stay white with a Metal device)
#   /private/var/local/mtl2.log                     empty, mode 666 (each client's log)
# Then recomputes the per-GiB SHA-256 list (redfin-mkroot-wsl.sh finish) that install delta compares against.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD
export REDFIN_WORK=${REDFIN_WORK:-/root/apollo-root}
W=$REDFIN_WORK
IMG=$W/iosroot.img
REF=${1:-builds-metal2}
say() { echo "[$(date +%T)] $*"; }
[[ -f $IMG ]] || { echo "no $IMG: build the root first (apollo-wsl.sh root)"; exit 1; }

say "SweetMetal2 bundle from DenialOfGravity/ios-redfin $REF"
M=$W/metal2-src
rm -rf "$M"; git init -q "$M"
git -C "$M" fetch -q --depth 1 https://github.com/DenialOfGravity/ios-redfin.git "$REF"
git -C "$M" checkout -q FETCH_HEAD
B=$M/SweetMetal2.bundle
for f in SweetMetal2 libvulkan_freedreno.dylib Info.plist _CodeSignature/CodeResources; do
	[[ -s $B/$f ]] || { echo "incomplete bundle: no $B/$f"; exit 1; }
done
cat "$M/BUILD.txt" 2>/dev/null || true
grep -qa FD650 "$B/libvulkan_freedreno.dylib" || { echo "this Turnip build has no FD650 (Adreno 650)"; exit 1; }
echo "Turnip knows FD650"

say "hfsplus"
bash tools/redfin-mkroot-wsl.sh hfsmod
grep -qw hfsplus /proc/filesystems || { echo "no hfsplus in the WSL kernel"; exit 1; }

say "mount $IMG"
fsck.hfsplus -fy "$IMG" | grep -v 'Illegal name' || true
mkdir -p "$W/mnt"
mountpoint -q "$W/mnt" && umount "$W/mnt"
mount -t hfsplus -o loop,force "$IMG" "$W/mnt"
trap 'mountpoint -q "$W/mnt" && umount "$W/mnt"' EXIT
E=$W/mnt/System/Library/Extensions
[[ -d $E ]] || { echo "no System/Library/Extensions in the image"; exit 1; }
rm -rf "$E/SweetMetal2.bundle"
cp -a "$B" "$E/"
chown -R 0:0 "$E/SweetMetal2.bundle"
chmod 755 "$E/SweetMetal2.bundle" "$E/SweetMetal2.bundle/SweetMetal2" "$E/SweetMetal2.bundle/libvulkan_freedreno.dylib"
L=$W/mnt/private/var/local
mkdir -p "$L"
printf '* -chronod\n' > "$L/mtl2-clients"
: >> "$L/mtl2.log"
chmod 644 "$L/mtl2-clients"; chmod 666 "$L/mtl2.log"
ls -la "$E/SweetMetal2.bundle"; cat "$L/mtl2-clients"
df -h "$W/mnt" | tail -1
sync
umount "$W/mnt"
trap - EXIT
fsck.hfsplus -f -y "$IMG" | grep -v 'Illegal name' || true
fsck.hfsplus -f -n "$IMG" || echo "warning: fsck_hfs still reports minor issues; continuing"

say "per-GiB SHA-256 for install delta"
bash tools/redfin-mkroot-wsl.sh finish
echo "METAL2-EXIT=0"
