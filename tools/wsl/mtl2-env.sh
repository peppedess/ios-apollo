#!/bin/bash
# apollo: write /private/var/local/mtl2-env (KEY=VALUE lines SweetMetal2 puts into every Metal client's environment)
# in the WSL iOS root image, then the per-GiB SHA-256 list for install delta.
#   bash mtl2-env.sh 'TU_DEBUG=sysmem'      (one argument per line; no argument: remove the file)
# k6d/k6e: Turnip's GMEM (tiled) rendering on the A650 leaves every bin as noise + black (bins shrink with
# sweetgmemkb); sysmem rendering skips GMEM.
set -euo pipefail
export REDFIN_WORK=/root/apollo-root
W=$REDFIN_WORK IMG=/root/apollo-root/iosroot.img R=/root/apollo-repo
cd "$R"
bash tools/redfin-mkroot-wsl.sh hfsmod
fsck.hfsplus -fy "$IMG" | tail -1
mkdir -p "$W/mnt"
mountpoint -q "$W/mnt" && umount "$W/mnt"
mount -t hfsplus -o loop,force "$IMG" "$W/mnt"
F=$W/mnt/private/var/local/mtl2-env
if [[ $# -gt 0 ]]; then printf '%s\n' "$@" > "$F"; chmod 644 "$F"; echo "== $F"; cat "$F"; else rm -f "$F"; echo "removed $F"; fi
sync; umount "$W/mnt"
fsck.hfsplus -f -y "$IMG" | tail -1
bash tools/redfin-mkroot-wsl.sh finish
echo "ENV-EXIT=0"
