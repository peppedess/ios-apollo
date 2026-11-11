
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
