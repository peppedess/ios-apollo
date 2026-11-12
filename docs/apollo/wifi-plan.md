# apollo Wi-Fi plan (QCA6390 over PCIe)

The Pixel 5 (redfin) has an integrated WCN3998 (SNOC, ath10k): phone/wifi/wland talks to it through /dev/pmem and
hands frames to the kernel's /dev/wlan bridge (bsd/dev/flame_wlan.c, en0, wifid). The Xiaomi 10T Pro (apollo, kona)
has a discrete **QCA6390 on PCIe root complex 0** (cnss2 + MHI + ath11k in Linux). The wifid/en0/Apple80211 side
can stay; everything under it is new.

## Hardware (live DT of apollo)

- `qcom,cnss-qca6390@b0000000`: wlan-en GPIO **20** (TLMM 0x0f000000 tile), bt-en GPIO 21, sw-ctrl GPIO 124,
  wlan-rc-num 0, MHI 30 channels, buffer 0x8000.
  Supplies (RPMh): vdd-wlan-aon **smpa6** 0.95 V, vdd-wlan-dig **smpf2** (PM8009 S2) 0.95-0.952 V, vdd-wlan-io
  **smpa4** 1.8 V, vdd-wlan-rfa1 **smpa5** 1.9 V, vdd-wlan-rfa2 **smpc8** 1.35 V; cmd-db "smpf2" for its own vote.
- `qcom,pcie@1c00000` (RC0, qcom,pci-msm): parf 0x01c00000, phy 0x01c06000, dm_core 0x60000000, elbi
  0x60000f20, iatu 0x60001000, config 0x60100000, I/O 0x60200000, MEM 0x60300000 (61 MB).
  PERST# GPIO 79, WAKE# GPIO 81. vreg-0p9 / vreg-1p8 / cx. Clocks (GCC): pipe, ref src, aux, cfg_ahb, mstr_axi,
  slv_axi, ldo, slv_q2a_axi, tbu, phy_refgen, ddrss_sf_tbu. Resets: pcie_0 core, pcie_0 phy. GDSC pcie_0.
  PHY: 99 (offset, value, delay) triples in `qcom,phy-sequence` (power-down 0x840, status 0x814 bit 6).
  SMMU stream 0x1c00/0x1c01 (cnss: IOVA pool 0xa0000000 + 256 MB).
- Firmware in vendor/firmware (phone, not in git): `amss.bin`, `m3.bin`, board data (`bdwlan*`), regdb.

## Phases (each ends in a log line that says yes or no)

1. **Link up** (DONE in k12b, patches 1121-1122) (kernel, sweetpcie=1): RPMh votes for the five supplies + the RC's 0p9/1p8, WLAN_EN high, GDSC and
   GCC clocks on, PHY reset + the DT sequence, PERST# release, LTSSM to L0, then config read of bus 1:
   expect vendor 0x17cb device 0x1101. Risk: GCC/GDSC offsets, the refclk path.
2. **MHI** (DONE in k12q, patches 1123-1137: BAR0, BHI SBL, MSI, MHI host, BHIe AMSS -> mission mode): BAR0 map, MHI register space, power up to the PBL, BHI download of amss.bin (+ m3 over MHI
   later), AMSS execution environment, channels up. Risk: SMMU (stream 0x1c00 must reach memory).
3. **QMI over MHI** (bring-up in the kernel first, 3a IPCR + QRTR from patch 1138; then wland's QMI): WLFW handshake (host cap, BDF download, M3 dump area, mode on).
4. **ath11k data path** (CE rings over PCIe, HTC/WMI/HTT as wland does for ath10k): scan, join, TX/RX frames into
   /dev/wlan; en0, wifid and Settings come from the redfin side unchanged.

Estimate: phase 1 days, 2 about a week, 3-4 weeks. Every phase is RAM boots; nothing is flashed.

## Phase 4 state (12 November 2026)

Phases 1-3 are done and 4a works: CE rings, HTC READY, the WMI and HTT endpoints, HTC setup complete, and
the firmware's service-ready events (2 RF chains, 0 memory requests) all arrive. What is left is one wall.

### The wall: WMI_INIT

Every `WMI_INIT` kills the firmware ~95 ms later, with MHI going to SYS_ERR and EE 3 (RDDM). The crash
record in the RAM dump reads `cmnos_thread.c`, `Asserted in:0x1503340:0x1530258, line#502`.

What it is **not**, each ruled out by a boot of its own:

| suspicion | test | result |
|---|---|---|
| resource config values | `sweetwmimin=1`: 1 vdev, 4 peers, 8 tids | same assert |
| the message at all | `sweetwmivar=1`: the 32-byte INIT command TLV alone | same assert |
| our transport | `sweetwmiprobe=1`: command id 0x3ffe | **ignored, firmware lives**; CE3 head, tail and hardware tail all 4 |
| nothing to do with INIT | `sweetwmiidle=15`: sit still for 15 s | firmware alive, dies only once INIT is sent |
| missing data-path rings | `sweetdp=1`: the whole HAL ring set (patch 1152) | same assert |
| WMI array TLV tags off by one | fixed in 1153 | same assert |
| board data | `sweetbdf=1`: `bdwlan.elf` instead of `bd_j3s.elf` | service-ready grows by 4 bytes, same assert |
| firmware DDR alignment | 1158: each segment on its own power of two | same assert |
| the RF clock buffers | 1156: rfclka1/3, lnbclka2 (rfclka2 is not on this board) | same assert |
| a missing rail | cmd-db dump (1160): no PM8009 at all, and apollo's overlay puts vdd-wlan-dig on pm8150_s6, which we vote | same assert |
| rails not in high power mode | 1161: PMIC5 mode 7 on all four | same assert |
| the host holding the chip awake | 1162: release PCIE_SOC_WAKE around INIT | same assert |
| the sleep clock selection | 1163: nm_modem 0x18, not ath11k's 0x1e | same assert |
| ASPM pinned off | 1164: L1 and L1.1/1.2 on both ends | same assert |

### What the assert actually is

Exactly one place in `amss20.bin` loads the immediate 502 (`r0 = #502` at 0x156bfb4). Disassembled with
llvm-mc's Hexagon backend, the packet before it is a register-poll helper called as

```
poll(0xe0c30004, mask 0x80000000, expected 0,
     "_whal_pmm_wlan_pwr_seq_hwdtim_sleep___RAM", line 495,
     "WCSS_CC_WCSS_WLAN1_GDSCR/PWR_ON")
```

It waits for PWR_ON to **clear**. So at INIT the firmware brings the MAC up and then parks it in HW-DTIM
sleep, and the WCSS power domain never collapses. The neighbouring strings name the rest of that machinery:
`whal_power_enter_lightsleep___RAM`, `WCSS_CC_WCSS_MAC0_MAC_CBCR/CLK_OFF`,
`WFSS_PMM_R0_WLAN1_STATUS_REG2/WLAN1_SM`, `whal_umac_check_reo_idle`, and a `ccpm` power manager voting
`wcss_cx`/`wcss_mx` with op modes DISABLED / HI_PERF / LOW_PERF / SCAN IMPS / HW_DTIM.

### Next

Guessing at what holds the domain has now cost ten boots. The firmware says what it is doing, in plain
printf format strings that are in the image — it emits them as Qualcomm F3 diag messages on **MHI channels
4 and 5 (DIAG)**, which apollo's own cnss node configures (32 elements, event ring 1, AMSS). Channels 20
and 21 already work, so bringing up two more is a small step, and each F3 message carries the address of
its format string, which we can resolve against `amss20.bin` and print. That turns every further question
in this port from a boot-sized experiment into a log line.
