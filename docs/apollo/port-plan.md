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
