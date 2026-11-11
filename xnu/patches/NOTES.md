
## 1151-apollo-wmi-idle-probe.patch

Three things, after k13c showed the minimal resource config (1 vdev, 4 peers, 8 tids) asserting exactly like
the full one — `cmnos_thread.c`, `Asserted in:0x1503340:0x1530258, line#502` — which rules the config out.

* `sweetwmiidle=<seconds>`: sit still after the service-ready events instead of sending INIT, polling the
  event rings. If SYS_ERR arrives anyway, INIT is not the trigger and the firmware is missing something the
  host owes it (the HAL data-path rings that `ath11k_dp_alloc` and `ath11k_dp_pdev_reo_setup` build before
  `ath11k_wmi_cmd_init`). If it survives, INIT is the trigger.
* `flags2` was off by one: the word index in `wmi_resource_config` is 68, not 67, so
  `CALC_NEXT_DTIM_COUNT_SET` was landing in `msdu_flow_override_config1`.
* HTC header: `NEED_CREDIT_UPDATE` on the credit-controlled WMI endpoint and the per-endpoint sequence
  number in the second word, as `ath11k_htc_prepare_tx_skb` writes them.
* The crash record is now dumped as words around the `Asserted in:` string, not only as text.

## 1152-apollo-dp-rings.patch

k13d settled the question the idle probe was built for: the firmware sits happily for 15 s after the
service-ready events and dies 95 ms after WMI_INIT, with the same `cmnos_thread.c` line 502 assert for every
resource config. So the message is not what it is missing — the host's data path is. ath11k builds the whole
HAL ring set (`ath11k_dp_alloc`, then `ath11k_dp_pdev_reo_setup`) *before* `ath11k_wmi_cmd_init`, and at INIT
the firmware brings up its own data path on top of it.

`sweetdp=1` builds that set, after ath11k with the QCA6390 register map:

* a 3 MiB ring block and a 4 MiB bank of 32768 128-byte link descriptors from the GPU pool, plus the
  head/tail array the hardware writes (`hal->rdp`), indexed by ring id;
* the WBM idle link ring (32767 entries) filled with every link descriptor — no scatter list is needed at
  this size — and its head rung;
* `wbm_rel`, `tcl_cmd`, `tcl_status`, `tcl_data0` (its entries pre-filled with empty TCL_DATA_CMD TLVs),
  `tx_comp0`, `reo_reinject`, `rx_rel`, `reo_except`, `reo_cmd` (entries numbered), `reo_status`;
* `ath11k_hw_ipq8074_reo_setup` (fragments to REO2SW1, aging on, the hash-to-ring map in all four
  DEST_RING_CTRL registers) and the 48 DSCP-to-TID tables;
* the four REO destination rings last, as `ath11k_dp_pdev_reo_setup` does.

## 1153-apollo-wmi-array-tags.patch

The WMI array TLV tags were all one too high: `WMI_TAG_FIRST_ARRAY_ENUM` is 16, so ARRAY_UINT32 is 0x10,
ARRAY_BYTE 0x11, ARRAY_STRUCT 0x12 and ARRAY_FIXED_STRUCT 0x13, and we were sending 0x11, 0x12, 0x13 and
0x14. WMI_INIT's third TLV — the (empty) host memory chunk array — therefore carried a tag the firmware's
parser does not expect at that position, which is exactly the kind of failure that does not depend on any
value in the resource config. The same mistake was in the vdev-create and start-scan commands, never
reached. The WMI endpoint also asks for both of the target's credits now, as ath11k does with one WMI
endpoint, instead of one.

## 1154-apollo-wmi-transport-probe.patch

k13f fixed the tags and changed nothing: still `cmnos_thread.c` line 502, still 96 ms after INIT. So before
porting any more of ath11k, separate the two possibilities. `sweetwmiprobe=1` sends the same 332-byte frame
on the same endpoint with command id 0x3ffe, which no firmware has a handler for. A firmware that ignores it
and stays alive has a working transport and something to say about INIT itself; one that dies the same way
is being handed something other than what we think we are sending. The normal path now also prints the CE3
head and tail right after INIT, so we can see whether the firmware consumed the descriptor at all, and the
RAM-dump printer waits for two log flushes before the test reboots.

## 1155-apollo-wmi-init-bisect.patch

k13g answered the transport question: command id 0x3ffe is ignored, the firmware lives, and CE3's head, tail
and hardware tail all read 4, so the descriptor was consumed. INIT itself is what kills it. `sweetwmivar`
bisects the message — 1 sends the INIT command TLV alone (36 bytes, no resource config, no chunk array),
which answers whether merely dispatching WMI_INIT is fatal; 2 sends the whole frame padded to the 336 bytes
ath11k sends; 3 leaves off the chunk array.

## 1156-apollo-rf-clock.patch

k13h is the answer: WMI_INIT with nothing but its 32-byte command TLV — no resource config, no chunk array —
kills the firmware the same way, 95 ms later. The message is irrelevant; what fails is what the firmware
does when it gets it, which is bring the radio up. Everything before that is digital and works.

The QCA6390 PMU takes RPMH_RF_CLK2 as its "xo" (the `qcom,qca6390-pmu` binding), a 38.4 MHz buffer from the
PMIC that the SoC's PCIe reference clock does not replace: the digital side boots without it and the RF PLL
never locks. Vote it, and its neighbours, before WLAN_EN. An RPMh VRM clock is enabled by writing 1 at the
resource's enable offset, the same offset the regulator votes use.

## 1157-apollo-bdf-and-segments.patch

k13i: "rfclka2" is not in apollo's cmd-db (ENODEV), rfclka1, rfclka3 and lnbclka2 vote fine, and the
firmware still dies. Two things to look at next:

* `sweetbdf=1` sends `bdwlan.elf` instead of Xiaomi's `bd_j3s.elf`. The chip reports board id 0xff, which is
  cnss2's "not fused" value, and its rule for that is the plain file, not a variant. Wrong board data is
  one of the few things that lets everything digital work and only breaks when the radio is configured.
* The firmware's own DDR segments are read before the RAM dump now, not after — the dump takes seconds over
  BHIe and has twice ended the log early — and their first words are printed before INIT as well, so we can
  see whether the firmware is using that memory at all.

## 1158-apollo-fwmem-alignment.patch

k13j: `bdwlan.elf` changes the service-ready event (340 bytes instead of 336, so the board data is read)
and nothing else — same assert. Segment 0 holds firmware data, so the DDR is in use; the caldb segment is
untouched.

Next suspicion: alignment. Linux allocates these regions with `dma_alloc_coherent`, which for a request of
megabytes returns a buddy block naturally aligned to its own order — the 6 MB region lands on an 8 MB
boundary and the 864 KB one on 1 MB. The Q6 maps host DDR with large pages, so a 16 KB-aligned base (what
the GPU pool gives) can only work for as long as the firmware stays inside the first page, which is exactly
until INIT asks it to allocate thread stacks and tables there — and the assert is in `cmnos_thread.c`.
Round each segment up to its own power of two.

The RAM dump is behind `sweetrddm=1` now: pulling it over BHIe has ended the log, and twice panicked the
kernel, in every run since the firmware started crashing this way.
