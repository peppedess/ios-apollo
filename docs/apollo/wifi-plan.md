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
2. **MHI** (kernel): BAR0 map, MHI register space, power up to the PBL, BHI download of amss.bin (+ m3 over MHI
   later), AMSS execution environment, channels up. Risk: SMMU (stream 0x1c00 must reach memory).
3. **QMI over MHI** (userland, as wland's QMI): WLFW handshake (host cap, BDF download, M3 dump area, mode on).
4. **ath11k data path** (CE rings over PCIe, HTC/WMI/HTT as wland does for ath10k): scan, join, TX/RX frames into
   /dev/wlan; en0, wifid and Settings come from the redfin side unchanged.

Estimate: phase 1 days, 2 about a week, 3-4 weeks. Every phase is RAM boots; nothing is flashed.
