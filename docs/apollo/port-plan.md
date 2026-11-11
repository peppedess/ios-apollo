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

k2c (1106 kernel + sweettime=<now> + sweetfb_noconsole=1 sweetsample=-): reset at ~32.5 s, no panic log, last
line backboardd polling IOAcceleratorES. k2d = same without sweettime: clean iOS lock screen, no console overlay.
Probably NOT sweettime: k2c had already booted when power + volume down was held to enter fastboot (forced reset,
hence no panic). k2c repeated (03:05) without touching the keys: lock screen with the real date (Wednesday, November 4, PST).
sweettime works.

Touch (NT36675): k3 (1107/1108) chip id `0e 00 00 72 66 03` over SPI SE4 OK; no firmware running after ABL
(reset state 0x2f, fw info broken), none in vendor/odm/system/product/backups. The LineageOS kernel embeds the
firmware: four 128 KiB blobs (end flag "NVTffZB" at 0x1ba253d/0x1bc453d/0x1be653d/0x1c0853d in the recovery Image;
header end 0x100, ILM 0x100 -> SRAM 0 size 0x13c3f or 0x11c73, DLM 0x18100 -> 0x27140). k3c: blob A passed with
NVTFW= (mkadt --nvtfw; extracted locally from the phone's own kernel, not in git).

**MILESTONE 2026-11-05 03:45: touch works on iOS** (k3c: kernel f233926 = 1107-1109, nvttouch=1, firmware blob A
host-downloaded to the NT36675 over SPI). Next: make it the default boot (k4), unlock / home screen, Setup.
k3c, 03:46: unlocked by swipe -> iOS 16 **home screen** (Photos, App Store, Settings, Photos widget; dock Phone,
Safari, Messages) and the **Settings app** opens and scrolls (Wi-Fi Off, Bluetooth Unavailable). Setup skipped by the
root image tweaks.

GPU (Adreno 650, kona; 2026-11-05): patch 1110 puts kona's values on the existing A620 (A650-family) path. The block
addresses (kgsl-3d0 0x3d00000, GMU 0x3d6a000, RSCC 0x3de0000, GPUCC 0x3d90000, SMMU 0x3da0000, PDC 0xb290000/0xb490000,
cmd-db 0x80860000) match lito. Changed: chipid 0x06050002, zap a650_zap in pil_gpu_region 0x8681a000, OPP 305/400/490/587
MHz, GMEM 1 MB + 128 KB, hang detect 0xcfffff, PC_DBG_ECO 0x300000, UBWC (hbb 16, ubwc-mode 4, mal 32), 3 CCUs
(RB_CCU_CNTL 0x18000000), PC/VFD power 2, accelerator reports 650. Firmware (a650_sqe.fw, a650_gmu.bin,
a650_zap.mdt/.b02 from vendor/firmware, not in git) goes in with GPUFW=DIR tools/apollo-k1.sh. Test k5: sweetgpu=1
(log "a6:"/"zap:"/"rpmh:" lines in sweetlog), then sweetmtl=2.

**MILESTONE 2026-11-05 16:22: Adreno 650 up** (k5a: kernel fb9280f = 1110, sweetgpu=1 sweetfb_thread=0 sweetddr=0):
GMU fw 6a1e904 BOOTED, HFI perf vote 490 MHz, oob gpu_set acked (GX GDSC on), CP me_init idle, zap a650 auth at
0xc8100000 rc 0, "GPU ready in 303 ms"; the framebuffer present already scales frames on the GPU (submits ~1.5 ms).
Touch was dead in k5a: warm reboot left stale NT36675 firmware (stuck finger 2 at 1000,780) -> 1111.
k5b (1111, sweetfb_thread=1 sweetddr=1): touch back, GPU present ~0.8 ms per frame, but CA renders on the CPU (no
cpufreq): 1-8 fps while in use (frames 100-170 ms), 60 fps only in idle animations. k6a: SweetMetal2 (builds-metal2
96f29b9, Turnip with FD650) put into the WSL root (apollo-wsl.sh metal2, mtl2-clients "* -chronod"), install delta
(10 GiB rewritten, verify ok), boot with sweetmtl=2.
k6a with metal2: first boot refused every Metal device (ShaderCache Permission denied: /var/local/m2v-cache missing,
/var/local root 755) -> apollo-metal2-wsl.sh makes it 1777. Second k6a: backboardd got "Turnip Adreno (TM) 620",
made its pipelines, drew 6 frames ('b3a8' surfaces) at 25-26 s, then nothing (black screen, spindump at 51 s):
Turnip was given FD620's device info -> 1112.
k6b (1112): Metal renders on the A650 (no stall), lock screen drawn but every texture as noise -> 1113 (8-channel macrotile).
k6c (1113): worse, all noise (BGRA framebuffer now, 60 fps swaps) -> 1114 redfin swizzle + register readback.
k6d (1114, redfin swizzle): same picture as k6b (bands of noise, garbled text) -> swizzle is not it; 1115 sweetgmemkb to test GMEM/bins.
k6e (sweetgmemkb=512): 11 bands instead of 5 -> the bands are Turnip's GMEM bins (each: noise on top, black below); GMEM rendering broken on the A650. Next: TU_DEBUG=sysmem via /var/local/mtl2-env (tools/wsl/mtl2-env.sh).
k6d/k6f with TU_DEBUG=sysmem (/var/local/mtl2-env): **Metal renders correctly** (home screen, dock blur), stable for
30 min; but slow: backboardd 35-75 ms of GPU per frame (redfin 10-15 ms) and the CPUs still at ABL's clocks.
Next: 1116 cpufreq (EPSS), then GPU/DDR clocks, then GMEM (bins: noise top, black bottom).
**k7a (1116, flamecpufreq=1): cpufreq works on kona EPSS.** Tables: silver 300-1804 MHz (ABL left 1420), gold
710-2419 (ABL 710), prime 844-2841 (ABL 844); boot max writes read back. UI clearly smoother: up to ~25-30 shown
fps scrolling, now GPU-bound (backboardd 20-50 ms GPU per frame in sysmem, 95 % busy in bursts).
k8a (1117 sweetucgmem=0, TU_DEBUG=gmem): UI runs (up to ~35 shown fps, backboardd ~75 ms GPU per frame, GPU 99 % busy) but the screen stays black (k6 bins were noise + black); GPU pool full (876 MB) at 149 s. k8b = same with the range set, forced GMEM, for comparison.
k8b (range set, forced GMEM): every bin noise + black again. So the UCHE GMEM range decides noise (GMEM read back
through UCHE) vs black (sysmem at VA 0x100000 = nothing): the resolve path reads GMEM, but what the draws should
have put there is not in it. Linux 6.12 comparison (a6xx_hw_init, a6xx_catalog): A650 = family GEN3 like the A620,
gmem 1 MB + 128 KB, hwcg a650_hwcg, protect a650_protect, gmu_cgc_mode 0x20202 (A620 0x20200), HW_APRIV; Linux
skips the UCHE GMEM range on the whole family. Suspects for GMEM contents not sticking: GX memory power/retention,
clock gating (we leave hwcg off), APRIV. Plan: a kernel GMEM self-test (CP writes to GMEM via the UCHE range and
reads back) to test those without rebuilding the root; meanwhile back to TU_DEBUG=sysmem.
Back to TU_DEBUG=sysmem (delta 12:12-12:33), k9a = 1117 kernel, sysmem, flamecpufreq=1: the usable configuration.
k10a (1118, sweetwled=1 sweetbl=1): SPMI to PM8150L SID 5 works (WLED APIDs 0x62/0x63 owned by EE 0, writes complete),
but 1118 had the wrong offsets (0x51/0x52 are SRC_SEL/WIDTH_SEL; brightness is 0x53/0x54 = 0x099 from ABL at boot).
CoreBrightness only sent "brightness" 512, then 1/0 and IOMFBBrightnessLevel 0-0.49 nits (auto-brightness with no
real ambient light sensor?). -> 1119.
k10b (1119, sweetwledtest=60): **WLED brightness works** (panel dims at boot, every write reads back). iOS side: CoreBrightness sends IOMFBBrightnessLevel 0-1 nits / brightness 0-1 whatever the slider (auto-brightness off): L_minimum, no panel luminance (redfin 0973). k10c: BACKLIGHT=1 (mkadt --backlight).
k10c (BACKLIGHT=1): no change: CoreBrightness sends 404, then 0-0.49 nits at 19-22 s and nothing for the slider afterwards. Needs CoreBrightness's own log (shell over USB). 1120: sweetwledfix=N.
k11a: sweetwledfix=512 (half brightness held) + BACKLIGHT=1, sysmem Metal, cpufreq: the current daily image. Wi-Fi plan: docs/apollo/wifi-plan.md.
k12a (1121, sweetpcie=1): boots normally. RC LDO votes OK; SMPS votes refused (cmd-db duplicates); GDSC on, cfg/aux/mstr/slv clocks on, pipe off; PHY NOT READY (status 0x69). k12b: 1122 (refclk 0x8c004, phy aux 0x6f004, SMPS duplicates accepted).
k12b (1122): **PCIe link up, Wi-Fi phase 1 done.** All six RPMh votes OK; PHY ready (status 0xa6); RC 17cb:010b; LTSSM 0x11 (L0) in ~210 ms, link status 0xb012; endpoint 1:0.0 = 17cb:1101 class ff0000 (QCA6390), BAR0 64-bit. iOS boots normally to SpringBoard. Next: phase 2 (MHI, BHI of amss.bin).
Wi-Fi firmware (tools/wlan-fw.bat, recon/wlan, out of git): modem.img image/qca6390/: amss20.bin (4.2 MB), m3.bin, regdb.bin, bdwlan.e01-e25/.elf and per-model bd_*.elf (apollo = j3s: bd_j3s.elf). k12c: 1123 (phase 2a, MHI/BHI read-only dump).
k12c (1123): **Wi-Fi phase 2a OK.** BAR0 1 MiB 64-bit at 0x60300000 (command 6). MHI: reglen 0x100, MHIVER reads 0xdeadbeef (normal before power-up), cfg 0x800080, chdb 0x300, erdb 0x700, BHI 0x100, BHIe 0x224; MHI state RESET, not ready. BHI v1.2, **EE PBL**, status 0, serial 0x648fd0f3, hw id 0x301050e1 (QCA6390 v2 -> amss20.bin). Next 2b: BHI download of the SBL (first 512 KiB of amss20.bin) from DMA memory, then BHIe for the rest.
k12d (1124): firmware reached the kernel via /chosen/wlanfw (boot image 23.5 MB, fine), but "no contiguous memory": XNU's RAM starts at 4 GiB. k12e: 1125 (SBL in pil_wlan_fw_region 0x86700000).
k12e (1125): no panic; SBL in 0x86700000 read back fine; BHI ERROR after 325 ms (status 0xffffffff, ERRCODE 0xef128100, ERRDBG 0x86700000/0/0x80000), EE PBL: the chip's DMA read is refused (apps SMMU, stream 0x1c01). k12f: 1126 (SMMU identity bank for 0x1c00/0x1c01).
k12f (1126): SMMU sCR0 0x2e0406 (USFCFG=1), ID0 0x4c017e57 (87 SMRs), ID1 0x6000004a (74 banks). CB6 configured, SMR5 write did not stick (reads 0), S2CR5=6. Global FSR 0 after BHI (the hypervisor may take the unmatched-stream faults). BHI: same ERRCODE 0xef128100. k12g: 1127 (SMR top-down until one sticks).
k12g (1127): every free SMR tried (86..71) read back 0; BHI same error; the phone hung at ~27 s and ended in fastboot (16 SMR writes suspected). k12h: 1128 (PARF BDF-to-SID table as Linux config_sid_1_9_0; valid SMR list; 2 tries only).
k12h (1128): no log of its own (died before the first UFS flush), into fastboot. k12i: 1129 (late start + a flush before each risky step).
k12i (1129): boots fine with the late start (k12h's early death not reproduced). SID table set (hash 0 / 21). ABL SMRs: 0x4a0, 0xc0, 0x4e0, 0xe0, 0x820 mask 0x402 (S2CR 0-4). SMR86/85 refuse 0x80011c00. BHI ERROR 0xef128100 again, global FSR 0. k12j: 1130 (Linux-style SMRs).
k12j (1130): **BHI SUCCESS** (45 ms, ERRDBG = 0x86700000 / 0x80000). SMR5 <- 0x80001c01 and SMR6 <- 0x80001c00 (mask 0, lowest free) stick; the masked form 0x80011c00 is what the hypervisor refused. QCA6390 stream -> CB6, translation off, IOVA == PA. EE still reads PBL and MHI state RESET for 3 s afterwards (SBL waits for the host's MHI init, ready bit not logged yet). Next 2c: MHI READY -> host context (MHICTRLBASE, channel/event contexts, command ring), M0, SBL EE event, BHIe download of amss20.bin.
k12k (1131): BHI success again (ERRCODE 0), 2c memory at 0xd3568000 (pool), but "not ready after 2000 ms": MHICTRL 0, MHISTATUS 0, EE PBL: the SBL never came up. k12l: 1132 (ath11k_pci_sw_reset sequence before BHI).
k12l (1132): sw reset OK (link regs set; MHISTATUS 0xff04 = SYS_ERR from k12k's SBL), BHI success, no READY in 5 s. k12m: 1133 (15 s watch, SYS_ERR details).
k12m (1133): after BHI success, 15 s with no change at all (MHISTATUS 0, EE PBL). BHI_STATUS low bits = our IMGTXDB session id, so the success is real; the SBL does not announce itself. k12n: 1134 (per-second chip/link dump).
k12n (1134): BHI_STATUS turns 0xffffffff, ERRCODE 0xef0e0003 within a second of BHI success (SBL error); Q6 cookie 0, link and config fine. k12o: 1135 (ath11k clear_vector + BHI_STATUS clear).
k12o (1135): BHIe/vector registers held random data (cleared); same ERRCODE 0xef0e0003 after BHI success. k12p: 1136 (SBL from pool RAM instead of the PIL region).
k12p (1136): SBL from pool RAM, same ERRCODE 0xef0e0003 a second after BHI success. k12q: 1137 (endpoint MSI enabled, landing word in pool RAM).
k12q (1137): **Wi-Fi phase 2 done: the QCA6390 runs its mission firmware.** MSI cap 0x50 (32 vectors) enabled with address in pool RAM -> the SBL starts (EE SBL, MHI READY at once), init_mmio, M0, BHIe of all 9 segments DONE in 85 ms, events: state M0, EE SBL, EE AMSS; EE 2 (AMSS), MHI state M0. The missing piece since k12k was the endpoint's MSI (ERRCODE 0xef0e0003 = SBL could not set up its interrupt). Next: phase 3, QMI (WLFW) over MHI channels 20/21 (IPCR).
k12r (1138): **Wi-Fi phase 3a OK.** START_CHAN 20/21 complete (code 1), channels RUNNING; our HELLO goes out (TX completion on ring 1); the chip is QRTR node 7: HELLO, then NEW_SERVER service 0x45 (WLFW) instance 0x101 at 7:1. Next 3b: WLFW ind_register, host_cap, request_mem/respond_mem, fw_mem_ready.
k12s (1139): **Wi-Fi phase 3b OK.** ind_register and host_cap accepted (result 0); request_mem: 2 segments (6160384 bytes type 1 DDR, 884736 bytes type 4 CALDB), served from the pool (0xcfd68000, 0xd0348000); respond_mem OK; fw_mem_ready indication. Next 3c: target cap 0x24, BDF download 0x25 (regdb.bin, bd_j3s.elf), M3 info 0x3c, fw_init_done / fw_ready, wlan_ini/cfg/mode.
k12t (1140): cap: chip family 0xb, board id 0xff (so Xiaomi's bd_j3s.elf), soc id unset, fw 0x101f046e WLAN.HST.1.0.1.r1-01134 (2022-06-30). Board data segments 0-3 OK, 5th unanswered: QRTR flow control (our RESUME_TX was malformed). k12u: 1141.
k12u (1141): **Wi-Fi phase 3 done.** With RESUME_TX fixed: bd_j3s.elf in 10 segments accepted, m3.bin (266668 bytes) announced, m3_info OK, indication fw_init_done (0x38). No fw_ready (0x21) indication: as in ath11k for the QCA6390, FW_INIT_DONE is the go for firmware start (wlan_cfg with the CE pipe tables, wlan_mode mission), which needs the copy engines = phase 4. The test image reboots itself to fastboot (sweetpciereboot=1); tools/go-*.bat chain boot, recovery and log pull (ADB in recovery is the one manual step).
Phase 4 plan: 4a CE SRNG rings + shadow registers + wlan_cfg/wlan_mode + HTC ready; 4b HTC services, WMI service ready/init/ready; 4c vdev + scan; 4d HTT/DP rings and data, en0 glue.
k12v (1142): **Wi-Fi phase 4a OK.** wlan_cfg/wlan_mode accepted, CE rings up, HTC READY (2 credits of 2176, 5 endpoints), WMI control 0x100 -> endpoint 1, HTT 0x300 -> endpoint 2, setup complete; firmware sent SERVICE_AVAILABLE (3), SERVICE_READY (1, "QCA_ML", fw 0x101f046e), and two ext events (0x4009, 0x4022). k12w: 1143 (WMI_INIT).
k12w (1143): service ready parsed (2 RF chains, 0 memory requests), the two ext events are 0x4009 SERVICE_READY_EXT and 0x4022 EXT2. WMI_INIT sent -> MHI SYS_ERR 93 ms later (firmware crash): resource config fields were shifted by one. k12x: 1145.
k12x (1145): resource config now matches ath11k exactly; still SYS_ERR 98 ms after WMI_INIT. Either the missing DP/HAL ring setup (ath11k_dp_alloc runs before wmi_cmd_init) or something else in the INIT path. k12y: 1146 adds the firmware crash text.
