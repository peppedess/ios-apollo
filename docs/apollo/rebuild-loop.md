# Rebuilding the apollo test loop in a fresh session

Everything needed to *reason* about this port is in the repo. What is not in the repo, deliberately, is
the phone's own firmware and the recon data pulled off it — those stay out of git. A session that starts
from a clean container therefore has to rebuild a handful of local artefacts before it can package a test
image. This is the list, and where each one comes from.

## The loop, end to end

1. **Build the kernel** — `go\1-build.bat` on the PC. It drives `wsl\apollo-wsl.sh` in WSL Ubuntu-24.04,
   which clones/updates the repo, applies `xnu/patches/*.patch` in order and builds XNU. The result lands
   in `C:\Users\giuse\Desktop\ios-apollo\builds\xnu\apollo-<short sha>\kernel.development.sweet.gz`, and
   the build log in `wsl\wsl-xnu.log` (grep it for `kernel ok`).
2. **Package the image** — in the container, stage that `kernel.development.sweet.gz` and run
   `tools/apollo-k1.sh`. It needs the environment below. The output is `apollo-<tag>.img`, which goes back
   to the PC under `img\`.
3. **Run it** — `go\i-run.bat` reboots to the bootloader, `fastboot boot`s the newest `img\apollo-k1*.img`,
   waits out the iOS window, puts the phone back in recovery if it landed in fastboot, then waits for adb
   and pulls the kernel log. The phone needs **Advanced → Enable ADB** in recovery each time; that is the
   one manual step left.
4. **Read the log** — the kernel log lives on UFS at `/dev/block/sda34`,
   `dd bs=4096 skip=59317242 count=1025`. Its header gives the length at bytes 16..24 and the text starts
   at offset 4096; `tools/sweet-log.py` decodes it.

Keep the iOS window short while iterating: `flamereboot=150` makes the phone come back by itself after
150 s instead of the default half hour.

## Local artefacts the packaging needs

`tools/apollo-k1.sh <kernel.gz> <dtb> <out.img> <boot args...>` plus these environment variables:

- `WLANFW=<dir>` — the QCA6390 firmware: `amss20.bin`, `m3.bin`, `regdb.bin`, `bd_j3s.elf`,
  `bdwlan.elf`. **From the phone**: mount the modem partition in recovery
  (`mount -t vfat -o ro /dev/block/by-name/modem /firmware`) and copy `/firmware/image/qca6390/*`.
  The linux-firmware alternatives (`amss_lf.bin`, `m3_lf.bin`, `bd_lf.elf`) come from
  CirrusLogic/linux-firmware under `ath11k/QCA6390/hw2.0`; `bd_lf.elf` is the `board-2.bin` entry
  `bus=pci,qmi-chip-id=0,qmi-board-id=255`, extracted with `tools/wlan-fw.bat`'s helper. Both sets
  behave identically, so either will do for a test.
- `GPUFW=<dir>` — Adreno 650 firmware (`a650_sqe.fw`, `a650_gmu.bin`, `a650_zap.mdt`/`.b02`) from the
  phone's `vendor/firmware`.
- `NVTFW=<file>` — the NT36675 touch firmware (`nvt_a.bin`), also from the phone.
- `BACKLIGHT=1` — no file, just the flag.
- the **DTB**: apollo's own device tree, pulled from the boot image / recovery
  (`tools/apollo-dtb.sh`, or in a pinch `tar` up `/sys/firmware/devicetree/base` from recovery and
  rebuild it).

## The baseline boot-args line

Each image inherits the working boot-args from the last known-good image's `.cmdline`, with the
per-run junk filtered out: `debug=`, `serial=`, `cpus=`, `keepsyms=`, `-enable_kprintf_spam`,
`-noprogress`, `sweettime=`, `nvtlog=`, `sweetsample=`, `flamereboot=`. The line has a hard limit of
**592 bytes** — past it the image silently fails to build, so check the length after packaging. Add
`sweettime=$(date +%s)` so the log can be matched to the run.

## Standing rules for this project

- Reply in Italian. Complete files, never diffs. One copyable command block.
- No destructive step without asking first.
- **Never flash ABL, XBL or the modem. Never relock the bootloader.** Writing the boot partition — which
  is what making iOS boot without the PC would take — needs the user's explicit consent.
- Backups, recon data, Apple files and phone firmware stay out of git.
- Don't open personal files unless asked.
