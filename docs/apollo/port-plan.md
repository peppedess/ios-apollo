# iOS on Xiaomi 10T Pro (apollo) — port plan

Branch `apollo`, forked from DenialOfGravity/ios-redfin `known-good-r57a-kernel` (the Pixel 5 port, itself
from ios-flame / ios-sweet). Started 2026-11-04. Test phone: Xiaomi 10T Pro, bootloader unlocked,
LineageOS 24 (`apollon`) with TWRP.

Sources for the values below: LineageOS `android_kernel_xiaomi_sm8250` (lineage-23.0,
`arch/arm64/boot/dts/vendor/qcom/kona.dtsi`, `xiaomi-sm8250-common.dtsi`, `apollo-sm8250.dtsi`,
`dsi-panel-j3s-37-02-0a-dsc-video.dtsi`) and `android_device_xiaomi_sm8250-common` /
`android_device_xiaomi_apollon` (lineage-24.0, BoardConfig). **Source DT ≠ live DT**: everything marked
*verify* waits for `tools/apollo-recon.ps1 twrp` (live DTB, iomem, reserved memory, partitions).

## How apollo differs from redfin

| | redfin (Pixel 5) | **apollo (10T Pro)** |
|---|---|---|
| SoC | SM7250 (lito) | **SM8250 (kona)**: 1x A77 prime + 3x A77 + 4x A55 |
| GPU | A620, a650 fw | **A650**, a650_gmu/sqe + a650_zap |
| Panel | S6E3HC2 **command mode**, DSC, 1080x2340 | j3s 37 02 0a **video mode**, DSC 2x540, **1080x2400, 144 Hz** |
| Touch | sec_ts, SPI QUP0 SE0 | "xiaomi,spi-for-tp", **SPI QUP SE4**, 10 MHz; IRQ TLMM 39, reset 38, CS 11 — chip *verify* |
| Vol+ | PM8150L GPIO5 (SID 4) | **PM8150 GPIO6 (SID 0)** |
| Boot image | header v3 + vendor_boot | **header v2, DTB inside boot.img**, base 0, page 4096 |
| boot partition | 0x06000000 | **0x08000000** |
| Bootloader | Google ABL (needs LZ4 + AVB footer) | Xiaomi ABL: raw Image (LineageOS ships `Image`) — LZ4/gzip images built as fallbacks |
| Wi-Fi | WCN3998 (icnss, SNOC) | **QCA6390 over PCIe (cnss2)**: new work |
| A/B | yes | **no** (single slot) |

## Hardware facts (source DT)

| Item | redfin | apollo | Source | State |
|---|---|---|---|---|
| Splash framebuffer | 0xa0000000 / 0x2300000 | **0x9c000000 / 0x2300000** (rdump 0x2400000) | kona.dtsi cont_splash_region | shim console.h; *verify* |
| IMEM restart_reason | 0x146ab65c | **0x146bf65c** | kona.dtsi msm-imem@146bf000 + 0x65c | shim.c |
| PON reason | PM8150 SID0 0x88f | same | | shim.c |
| WDT / PS_HOLD | 0x17c10000 / 0x0c264000 | same | kona.dtsi | unchanged |
| GIC-600 | GICD 0x17a00000, GICR 0x17a60000 | same | kona.dtsi | unchanged |
| SPMI | 0x0c440000 ... | same | kona.dtsi | unchanged |
| UFS | 0x01d84000 | same | kona.dtsi ufshc@1d84000 | unchanged; userdata found by GPT |
| MDSS/SDE | 0x0ae00000 | same | kona.dtsi | sde.c unchanged; video mode → no autorefresh needed |
| SMEM | 0x80900000 | same (0x80900000 + 0x200000) | kona.dtsi | later (Wi-Fi) |
| cmd-db | 0x80860000 + 0x20000 | same | kona.dtsi | later |
| GPU zap (pil_gpu) | 0x8bc15400 | **0x8681a000** + 0x2000 | kona.dtsi | later (GPU) |
| RAM | 8 GB, 0x80000000.. | 8 GB *verify* map | live DT | shim probes 0x100000000 / 0x180000000 / 0x1fbf00000 |
| Display pipe | VIG0+VIG1 → CTL0 → DSC0/1 → INTF1 | *verify* (probe log) | | probe 1 |

## Test plan (compressed)

1. **Recon** — `apollo-recon.ps1 android`, `twrp`, `backup`. Read-only. Gives the live DTB and memory map.
2. **Probe 1** — `fastboot boot apollo-probe-safe.img` (CI artifact `apollo-shim`). RAM only, never
   writes storage (`SHIM_NO_UFS_WRITE`), shows its log on screen 20 s per page, then resets to fastboot.
   Photograph each page. If ABL refuses the image, try `-lz4`, then `-gz`.
   Expected: console on 0x9c000000, CPUs/PSCI, SPMI + PON, vol+ PM8150 GPIO6, UFS userdata found,
   SDE pipe dump (video mode: `tear 0`), GIC, RAM probes, "done, resetting".
3. **XNU in RAM, read-only** — adapt the redfin kernel patches (0900-1030) that hard-code lito values:
   framebuffer and geometry, keys, battery/charger, cpufreq clusters (kona has 3), USB SMMU SID, touch
   (off). ADT from `mkadt.py` with the apollo framebuffer. Expected: XNU console, 8 CPUs, "cannot mount
   root" (userdata is still Android's).
4. **iOS root on userdata** — wipes Android data. Only after explicit confirmation.
5. **Touch** — new SPI driver for the apollo touch chip (identity from recon).

## Not in git

The live DTB, recon output, partition backups and the stock DTB (CI downloads it each run) stay out of git,
as do Apple's files (IPSW parts, root image). See AGENTS.md.

## Probe 1 (2026-11-04, `apollo-probe-safe.img`, raw kernel): shim runs on the 10T Pro

`fastboot boot` accepted (Xiaomi ABL, unlocked, header v2 + DTB, 4 MiB image with AVB footer). Photos of
the 3 log pages:

- EL1, MIDR 0x51df805e, MPIDR 0x81000000; DTB at 0xafdfd000; initrd 0xafffe000-0xafffe045 (only our ramdisk:
  no vendor ramdisk with v2; ABL ends the ramdisk just below 0xb0000000).
- PSCI 1.1 (CPU_ON, RESET yes; RESET2 0; SYSTEM_SUSPEND no). SPMI arb v5, 512 APIDs.
- PON spare 0 -> 4, IMEM 0x146bf65c = 0x77665500; PS_HOLD hard reset 7/0x80 (already set).
- vol+ PM8150 SID0 GPIO6 @0xc500: subtype 0x11, status 0x81 (released = high). Confirmed.
- UFS 3.0 (ver 0x300), TUR ok, userdata first 0x2c0000 blocks 0x3891ffb (= recon partitions.txt),
  `save: write rc -1` (SHIM_NO_UFS_WRITE).
- SDE hw 0x60000000 (SDE 6.0). CTL0 -> one SSPP VIG0 1080x2400 at 0x9c000000, stride 0x10e0, fmt 0x237ff
  (a8r8g8b8) -> LM0 -> PP0/PP1 -> DSC0 -> INTF1. **Video mode**: tear 0, autorefresh 0, counters 0/0; the
  panel scans the buffer continuously, so the console shows with no display work.
- GIC-600: same as redfin (8 redistributors, aff core<<8). RAM probes at 0x100000000, 0x180000000,
  0x1fbf00000 read back. "done, resetting" -> fastboot.

Recon (LineageOS 24 recovery, adb root): RAM 0x80000000+0x3bb00000, 0xc0000000+0xc0000000,
0x180000000+0x100000000 (System RAM 0xffc20000-0x27fffffff, reserved only above 0x275d80000). userdata = sda34.
Live DT confirms imem restart_reason @0x146bf65c, vol_up = pm8150 gpio 6, touch "xiaomi,spi-for-tp" on
spi@990000, panel j3s 1080x2400 video. Backup: 114 partitions, SHA-256 checked (PC only).

## Kernel k1 (patch 1100-apollo-basics)

Early console framebuffer 0x9c000000 1080x2400, vol+ PM8150 GPIO6, panel height 2400 for touch/GPU
constants, ADT framebuffer + CPU clocks for kona. First boot is read-only and minimal:
`rd=ufsroot0 ufsrw=0 rootrw=0 sweetlog=0 sweetusb=0 flamecpufreq=0 flamereboot=150`, touch/GPU/Metal off.
flamecpufreq=0 because kona's cpufreq-hw is not at lito's addresses (to do).

## k1: first XNU boot (2026-11-04, local WSL kernel c82d2d1, `apollo-k1.img`)

Kernel built in WSL (tools/wsl, UniXNU toolchain, 151 s). `fastboot boot` OK (19 MB image, AVB footer on a
20 MiB partition size). Screen: the XNU console at 1080x2400 on 0x9c000000. Log read back from DRAM after the
reset with the new read-only shim mode `SHIM_RAMSHOW` (`apollo-ramshow.img`: XNU's uncached ring mirror at
0x1fa000000 survives the warm reset):

- Darwin 22.6.0 xnu-8796.141.3; pmap/VM/zone init fine; 251305 free pages.
- AMFI/sandbox stand-ins, vnguard, LOG mirror, device-tree platform expert, FLAME WDT petting every 5 s.
- SPMI arb v5; AKS; IOWatchdog; IOCoreSurfaceRoot; HID buttons + touch services; SWEET MOTION services;
  battery static fallback (sweetbattery=0); AMFI published.
- 8 CPUs registered (ml_processor_register, one cluster). `SWEET CPU: requested=8 selected=8`;
  cpu0 alive (SGI1 OK); cpu1 `PSCI CPU_ON target=0x100 rc=0`, `arm_cpu_init(): cpu 1 online`,
  `cpu=1 entered initCPU mpidr=0x100 EL1 IRQs=0` — but **no "cpu=1 came alive"** and no cpu_start(2).
- SWEET BL: DSI0 ctrl 0x1f7 status 0x2008 (video-mode DSI read fine); SWEET FB: AppleCLCD 1080x2400 stride
  4320 at 0x9c000000, presented as 1125x2436.
- **Last line at 9.765 s.** Then nothing: the hardware watchdog reset the phone into fastboot (~2 min).

Reading: the boot CPU waits for cpu1's alive handshake (SGI) and the whole kernel stops (WDT not petted).
Next: k1b = same kernel with `cpus=1` to see the rest of the boot (UFS, root mount); then SMP on kona.

## k1 result (2026-11-04, k1k: kernel apollo-c91fd7f03e, cpus=1)

Read-only XNU boot reaches the expected end: `SWEET UFS: "userdata" on LUN 0: first block 0x2c0000, 231711 MiB,
read-only`, then `hfs_ValidateHFSPlusVolumeHeader: unknown Volume Signature : 39a4` (userdata still holds Android)
and `cannot mount root, errno = 19` in a loop. No UFS write ever happens (ufsrw=0, SHIM_NO_UFS_WRITE).

Fixed on the way (all redfin values that differ on kona):
- 1103: PM8150 RTC (SPMI APID 2) belongs to EE1; its observer read hung bsd_init.
- mkadt: virtual timer INTID 27 (kona DT PPIs 13/14/11/12), not 19: without it no thread ever woke from a sleep.
- 1104: backlight DCS packet / MDP test / scanout carve-out moved inside kona's splash (0x9c000000+0x2300000).
- 1105: flamecpufreq=0 no longer reads lito's cpufreq-hw (kona: cpufreq-hw-epss 0x18591000/2000/3000).

k1l (cpus=8, same kernel): all 8 CPUs come alive (SweetCPU panics otherwise), boot again ends at cannot mount root.

Still to do before userland: kona cpufreq, brightness test (sweetbl_dcs=1 with 1104), RTC via
another route, then phase 4 (iOS root on userdata: wipes Android, only after explicit confirmation).

k1m (sweetbl_dcs=1, kernel with 1104): `SWEET BL: DSI0 ctrl 0x1f7 status 0x2008 trig 0x4: brightness via DCS 0x51`,
no reset, boot continues to cannot mount root. But the j3s panel ("xiaomi 37 02 0a video mode dsc dsi panel", dtbo)
uses `qcom,mdss-dsi-bl-pmic-control-type = "bl_ctrl_wled"` (PM8150L WLED5 at SPMI 0xd800/0xd900, levels 2..0xfff):
DCS 0x51 does nothing on apollo. Brightness needs a WLED driver (SPMI writes; check the APID owner first, as for the RTC).

## iOS root image (2026-11-05)

Built in WSL (`wsl/wsl-root.bat` = `apollo-wsl.sh root`): iOS 16.7.16 iPhone X (20H392) rootfs + SystemOS + AppOS
cryptexes, case-sensitive journaled HFS+ "iOSRoot", 16 GiB (sparse, ~11.6 GB used), fsck clean,
`/root/apollo-root/iosroot.img` in WSL; per-GiB SHA-256 in work/iosroot/iosroot.gib.sha256 (WSL clone). Not on the
phone yet: installing it means writing userdata (sda34), i.e. wiping Android (phase 4, explicit confirmation only).

Phase 4 done 2026-11-05 01:28-01:53 (confirmed by Giuseppe): iosroot.img written to userdata (sda34) from LineageOS
recovery with tools/apollo-install-root-wsl.sh; all 16 GiB verified against the per-GiB SHA-256. Next: k2
(img/apollo-k2.img: rd=ufsroot0 ufsrw=1 rootrw=1 ignition_level=1 ..., sweetlog=1 ufslogsecs=2, cpus=8).

k2 (2026-11-05 01:54): **iOS 16 userland boots on apollo.** Root mounted from userdata, launchd starts the daemons
(xpcproxy, bluetoothd, fairplayd.H2, spindump, softwareupdateservicesd, appleaccountd, localizationswitcherd, ...),
backboardd (pid 57) presents the Apple logo through AppleCLCD (`SWEET FB: 5s: swaps 5 shown 5 dropped 0`), and
reads the motion/pressure HID properties. Touch, USB, Wi-Fi, GPU still off (Pixel drivers).

k2 log (pulled from the end of userdata in recovery, `log-pull.bat`): SpringBoard aborts every ~5.5 s with
`NSInternalInconsistencyException: Failed to load bounding path bitmap data from the asset manager for asset name:
BoundingPathBitmap-1125x2436-375x812-3.00x` (also the Poster extensions). Cause: the local ADT had no /product node
(research/ipsw-x/d22ap.adt missing where the boot image was built), so no artwork-device-subtype 2436. k2b: same
args, ADT built with the d22ap.adt from the WSL root build (copied out with wsl/adt-copy.bat; Apple file, not in git).

k2b: same BoundingPath abort. The first boot (k2, no /product) left a MobileGestalt disk cache
(/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/
com.apple.MobileGestalt.plist), keyed by build + UUID only, so the new /product is never read (ios-sweet hit the
same: "reflashed clean to clear it"). Fix: `apollo-wsl.sh install delta` from recovery rewrites the GiBs that differ
from the pristine image.

**MILESTONE 2026-11-05 02:43: iOS 16 lock screen on the Xiaomi 10T Pro.** k2b after `install delta` restored the
pristine root (10 of 16 GiB rewritten, all 16 verified): SpringBoard stays up and draws the iOS 16 lock screen
(clock 4:03 = 1969-12-31 16:03 PST: no RTC yet; default blue poster; quick-action button bottom right), through
backboardd + AppleCLCD (`SWEET FB: 5s: swaps 18 shown 17 dropped 1`).
Next: time of day without the PM8150 RTC (boot-arg epoch), touch (xiaomi,spi-for-tp on spi@990000), WLED backlight,
USB, kona cpufreq, then Setup skip / activation as on ios-sweet.
