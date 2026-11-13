
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

## 1159-apollo-wlan-dig-rail.patch

The assert is readable after all. Exactly one place in amss20.bin loads the immediate 502 (`r0 = #502` at
0x156bfb4, in the segment at 0x14fa000), and disassembling around it with llvm-mc's Hexagon backend shows a
register poll helper being called with a mask of 0x80000000 on 0xe0c30004 and, as its name argument, the
string at 0x15a4a32: **"WCSS_CC_WCSS_WLAN1_GDSCR/PWR_ON"**, inside a routine whose own name string sits
right before it, `_whal_pmm_wlan_pwr_seq_hwdtim_sleep___RAM`. The helper returns -1 and the next packet is
the assert. So WMI_INIT is where the firmware powers up the WCSS, and its GDSC never reports PWR_ON.

apollo's `qcom,cnss-qca6390@b0000000` node names the rails: vdd-wlan-aon pm8150_s6, **vdd-wlan-dig
pm8009_s2 ("smpf2")**, vdd-wlan-io pm8150_s4, vdd-wlan-rfa1 pm8150_s5 (1.9 V), vdd-wlan-rfa2 pm8150a_s8
(1.35 V). We had read an earlier dtbo as saying the digital rail was S6 and never turned PM8009 S2 on. The
always-on domain runs without it, which is why everything up to and including the firmware's QMI and WMI
handshakes worked; the WCSS core does not.

## 1160-apollo-cmddb-dump.patch

k13l: `smpf2 lookup matches=0`. The rail is named in apollo's own device tree, and the Android driver
resolves it through cmd-db the same way, so either this board really has no PM8009 or we are reading only
part of the dictionary — "rfclka2", which an sm8250 should have, is missing too, which points at the
second. `sweetrpmhdump=1` lists every cmd-db header and every resource name with its address.

## 1161-apollo-hpm-and-gdsc-peek.patch

The cmd-db dump settles the rail question: this board has no PM8009 resources at all (no smpf*, no ldof*,
and no rfclka2 either), and apollo's overlay fragment 132 moves `vdd-wlan-dig` onto pm8150_s6, which we
already vote. So all five WLAN rails are on and the WCSS still will not power up. Two things:

* The rail votes now set PMIC5 mode 7 (forced PWM) as well as the voltage, the way cnss2's load-current
  request does. A rail in auto or PFM may not carry the inrush of a power domain coming up.
* `gdsc_peek` reads 0xc30004 and its neighbours through the BAR window before and after INIT. The Q6 polls
  0xe0c30004 for PWR_ON and its peripheral window starts at 0xe0000000, so the same register should be
  readable from the host — and then we can see whether SW_COLLAPSE is even clearing.

## 1162-apollo-release-soc-wake.patch

The strings around the assert name the whole power sequence: `_whal_pmm_wlan_pwr_seq_hwdtim_sleep___RAM`,
`whal_power_enter_lightsleep___RAM`, `WCSS_CC_WCSS_WLAN1_GDSCR/PWR_ON`, `WCSS_CC_WCSS_MAC0_MAC_CBCR/CLK_OFF`
— and a `ccpm` power manager voting `wcss_cx`/`wcss_mx`. So the step that times out is the firmware taking
the WCSS power domain through a transition, and the host can block exactly that: we have been holding
`PCIE_SOC_WAKE_PCIE_LOCAL_REG` (0x3004) asserted ever since mission mode, while ath11k writes it only in
`ath11k_pci_power_down`. A chip the host is holding awake cannot collapse that domain, and the poll times
out after the ~95 ms we have been seeing.

Release it before INIT, stay off the bus for 400 ms while the firmware sequences, then take it back for our
own register polling. `sweetwake=1` restores the old behaviour. The GDSC peek from 1161 is behind
`sweetgdsc=1` and off: 0xc30004 is not mapped in the host's view and reading it hung the phone.

## 1163-apollo-sleep-clock.patch

Disassembling the poll call itself settles what the firmware is doing: `poll(0xe0c30004, mask 0x80000000,
expected 0, "_whal_pmm_wlan_pwr_seq_hwdtim_sleep___RAM", line 495, "WCSS_CC_WCSS_WLAN1_GDSCR/PWR_ON")`. It
waits for PWR_ON to **clear** — the WCSS is being powered **down**, not up. At INIT, with no vdev yet, the
firmware puts the MAC into HW-DTIM sleep, and the domain never collapses.

A sleep sequence needs a sleep clock, and we have been telling the firmware to use the chip's internal one:
ath11k sets nm_modem 0x1e because its QCA6390 hw_params carry `internal_sleep_clock`, which exists for the
non-Qualcomm platforms ath11k runs on. apollo is a Qualcomm platform with a PMIC sleep clock and cnss2
leaves both that bit and HOST_CSTATE clear. `sweetnm` sets the field, default 0x18.

Releasing PCIE_SOC_WAKE around INIT (1162) changed nothing on its own, and forcing the rails into PWM
(1161) changed nothing either; both stay in.

## 1164-apollo-aspm-l1.patch

nm_modem 0x18 changed nothing, so the sleep clock is not it either. Next: the link. ath11k turns L0s and L1
off for the firmware download and puts them back in `ath11k_pci_start`, right before WMI, and the comment
there says leaving ASPM disabled causes "MHI M2 problems" — the low-power path. We never enabled ASPM at
all, and the firmware dies in a light-sleep sequence. Enable L1 on both ends (endpoint first) and L1.1/1.2
where both ends offer them, after mission mode and before HTC. `sweetaspm=0` turns it off again.

## 1165-apollo-diag-channel.patch

ASPM changed nothing either, so stop guessing and read the firmware's own log. apollo's cnss node
configures MHI channels 4 and 5 as DIAG, exactly like the IPCR pair we already drive, and the firmware
writes its F3 messages there — the printf formats are in `amss20.bin`, and the terse form carries their
addresses, so the bytes can be resolved off the phone.

`sweetdiag=1` starts the two channels immediately before INIT (not earlier: the firmware has been logging
since boot and would flood), posts eight 4 KiB buffers, and prints the first 60 packets as hex while
polling the event ring through the 400 ms the firmware takes to die.

## 1166-apollo-device-wake-and-diag-mask.patch

k13r: both DIAG channels start (completion code 1) and the firmware sends nothing — diag emits no F3
messages until the host sets the runtime masks. Send DIAG_EXT_MSG_CONFIG_F subcommand 5 with every level
on, and a version request ahead of it to show the outbound half works.

The more interesting half of this patch: assert the **MHI device wake**. `mhi_assert_dev_wake` writes 1 to
doorbell 127 of the channel doorbell block, and ath11k takes that vote around every register access past
BAR+4K-32 — which is every access it makes — so on a working host the chip is held awake for as long as
the driver is driving it. We never asserted it once, and what kills us is the firmware deciding it may
sleep. `sweetdwake=0` turns it off.

## 1167-apollo-rddm-flush.patch

The device wake changed nothing and diag still sends nothing even with the masks requested. Before chasing
either further: the assert we have been reasoning from was read in k13b, and the driver has changed a great
deal since — the data-path rings, the TLV tags, the rails, ASPM, the device wake. Re-read it. The RAM dump
printer now pauses for a log flush after each step, so an early return cannot swallow the result the way it
did in k13e and k13i.

## 1168-apollo-srng-msi.patch

k13u re-read the crash record with everything since k13b in place, and it is unchanged: `cmnos_thread.c`,
`Asserted in:0x1503340:0x1530258, line#502`. (The search that found the one site loading 502 was also
redone properly — the first pass had masked Hexagon's parse bits and would have missed two encodings out
of three. Still one site.) So the diagnosis stands and the WCSS still will not collapse.

What ath11k does to every ring and we do to none: `HAL_SRNG_FLAGS_MSI_INTR`, an MSI address and data in
each ring's registers, so a completion is delivered as a write the hardware retires itself. Polling the
ring pointers instead leaves each ring's interrupt asserted into the WCSS aggregate interrupt status with
nobody to clear it — and `WCSS_WCMN_R0_APPS_AGGRE_INTR_STATUS/PMM_WCMN_WLAN1_LS_DONE_INTR` is among the
strings in the same power sequence. Point every copy-engine and data-path ring at the scratch page the
endpoint's MSI capability already uses.

## 1169-apollo-drain-ce-after-init.patch

Per-ring MSI (1168) changed nothing. But the window after INIT, added in 1162 to stay off the bus, polls
only the MHI event ring — and the firmware's answer to INIT comes back on CE2. So for the last several
boots a WMI_READY sent before the crash would have sat unread in the ring, and we would never have known
that INIT had in fact succeeded. Drain the copy engines in that window too and say whether the ready flag
is set. This is the difference between a failed INIT and a successful one followed by a power sequence we
are not prepared for, and it has been invisible.

## 1170-apollo-dump-format-pointers.patch

k13w: no WMI_READY, and nothing else on CE2 either — the firmware answers INIT with silence and then dies.
So INIT does not complete, and the power sequence is inside it.

Diag is still mute, but the firmware's log is also in RAM, as records that point at their printf format
strings, and those strings are in the image between 0x16ad000 and 0x181a000. Print every word of the first
RAM-dump piece that falls in that range together with its offset; `tools/diagdec.py` resolves them against
`amss20.bin`, and a run of them in offset order is the last thing the firmware had to say before the
assert.

## 1171-apollo-cal-done.patch

Reading the sleep sequence further shows it logging through QSHRINK'd messages — ids, not strings — so the
diag route would not have been readable even once the channel worked. Back to what the host declares.

`cal_done` in the QMI host capability has been 0, which is what ath11k sends on a first boot: it tells the
firmware its calibration is not valid yet, and at INIT the firmware then runs a cold boot calibration —
exactly a sequence that powers the radio up, measures, and powers it back down. `sweetcal=1` (the default
now) says the calibration is already done. `sweetnm=0` drops the PCIe capability claims as well, since
PME_D3COLD is ath11k telling an x86 host's firmware it may use a power state this board may not have.

The board file is not the problem, incidentally: the phone carries `bd_j3s.elf`, `bd_j3sgl.elf` and
`bd_j3sin.elf` beside the generic `bdwlan.e01`-`e25`, and J3S is apollo's own name.

## 1172-apollo-wlan-en-power-cycle.patch

`cal_done=1` and `nm_modem=0` change nothing either. But here is something we have never done at all: we
only ever drove WLAN_EN **high**. Never low. So the chip has never been power-cycled by this driver — not
once in this whole investigation. Whatever state it was left in survives into the next run: the SoC reboots
between tests, the WLAN chip does not, and every test since the firmware started crashing has ended with
its WCSS power domain half collapsed and its PMU mid-sequence. That is an excellent way to make a power
domain refuse to collapse, and an excellent way to make every experiment produce the same answer.

Hold WLAN_EN low for 100 ms before raising it, which is what cnss2's power-off and power-on do between
them.

## 1173-apollo-m3-alignment.patch

The power cycle (1172) works — the chip enumerates from a genuinely cold start now — and the crash is
unchanged, so the wedged-state theory was wrong, though the fix stays.

Chasing the assert record further settled a doubt: the two hex values in `Asserted in:0x%x:0x%x, line#%d`
are the stripped file and function name pointers, and `cmnos_thread.c` is the file of the *printer*, which
lives at 0x15836c0 and loads that string itself. So the record names its own helper, not the caller, and
line 502 still belongs to the one site in the image that loads it — the GDSC poll. The diagnosis holds.

This patch aligns the M3 image the way `dma_alloc_coherent` would: 266668 bytes comes out of a 512 KiB
buddy block on a 512 KiB boundary, and we were giving it 16 KiB alignment from the GPU pool. The M3 is the
chip's own always-on core; the main firmware waits on it during exactly the power sequences that fail, so
an M3 that cannot run is a good reason for them to time out. Same class of mistake as 1158, in the one
buffer 1158 did not cover.

## 1174-apollo-linux-firmware-set.patch

M3 alignment did not help either, and the list of host-side differences from ath11k is now empty. So turn
the experiment around: the host sequence we have built is ath11k's, and ath11k is written against
**linux-firmware's** QCA6390 blobs, not the phone's. The phone's firmware expects Qualcomm's own cnss2
host, which differs in ways that are not visible from outside it.

Both sets now travel in the payload: `amss20.bin`/`m3.bin`/`bd_j3s.elf` as before, and `amss_lf.bin`,
`m3_lf.bin` and `bd_lf.elf` from linux-firmware's ath11k/QCA6390/hw2.0 — the last extracted from
`board-2.bin`, whose entry for chip id 0, board id 255 is exactly what this chip reports. (That container
also carries Xiaomi_Pad_5Pro variants, which are sm8250 devices with the same radio, so a closer board file
is there if the default one works but behaves oddly.) `sweetlf=1` selects the linux-firmware set.

## 1175-apollo-bt-enable.patch

k14c is the most informative run yet: linux-firmware's QCA6390 blobs (a different build, 2021-11-04,
version 0x10121492, with its own board file from `board-2.bin`) go through the whole handshake and die at
WMI_INIT **exactly** like the phone's. Two unrelated firmware builds, two board files, same death. So it
is not the firmware, and it is not the board data.

And the rails are right: the earlier reading of the device tree had been picking up the *next* node's
`qcom,resource-name`. pm8150_s4 really is smpa4, s5 smpa5, s6 smpa6 and pm8150a_s8 smpc8, all as voted.

What is left is the one enable we never touched. apollo's cnss node carries `qcom,bt-en-gpio` (21) beside
`wlan-en-gpio` (20), and mainline's QCA6390 power sequencer drives **both** high. The two sides of the chip
share one internal PMU, and the RF common supply it produces is not the WLAN side's alone — which would
leave the digital side working, as it does, and the radio unable to finish a power transition, which is
precisely where both firmwares die.

## 1176-apollo-print-crash-record.patch

BT_EN made no difference. Before fixing anything else on the strength of the GDSC reading, verify it: print
the crash record itself as text, four flushed lines around the message, before the hex dump that has never
survived to the log. What sits around `Asserted in:` — the faulting thread's name, the real file string —
is what says whether that reading is right.

## 1177-apollo-all-clock-buffers.patch

k14e printed the crash record in full and the reading holds: a file field of `cmnos_thread.c` — which is
the assert *printer's* own file, at 0x15836c0, which loads that string itself — followed by
`Asserted in:0x1503340:0x1530258, line#502`, the form the firmware uses when the caller's file and
function names have been stripped. Line 502 still belongs to the single site in the image that loads it,
in the WCSS GDSC poll.

So: vote every clock buffer this board has. The `qca6390-pmu` binding takes RPMH_RF_CLK2 as the chip's
"xo", apollo's cmd-db has no `rfclka2` at all, and the chip's digital side can perfectly well run off the
PCIe reference clock — it boots and its Q6 runs — while the radio needs the real 38.4 MHz buffer. That is
the shape of the failure we have, and whatever feeds that input here is one of the eight names cmd-db does
list.

## 1178-apollo-parf-l1-entry.patch

Every clock buffer the board has is voted now (rfclka1, rfclka3, rfclkd3, rfclkd4, lnbclka1-3; rfclka2
does not exist here) and nothing changed.

`PARF_PM_CTRL` (PARF + 0x20) bit 5 is REQ_NOT_ENTR_L1: while it is set the SoC's PCIe controller refuses
to let the link enter L1. We have never read or written that register — whatever the bootloader left is
what every run so far has used. Enabling ASPM in the two config spaces (1164) does nothing if the
controller is holding the link out of L1 anyway, and a link pinned in L0 keeps the endpoint out of the
low-power states its firmware waits on. Clear it, and log what it was.

## 1179-apollo-deassert-device-wake.patch

The reference the user asked for is now in hand, and it is the phone's own recovery. Its kernel carries
Qualcomm's `cnss2` bound to `qcom,cnss-qca6390` with `/sys/kernel/cnss/fs_ready` writable, so the stock
driver can be made to run its whole power-up with one write. With the modem partition mounted at
`/firmware`, SELinux set permissive and `amss20.bin` copied where `ueventd` looks for it, that write
produces:

```
cnss: Setting MHI state: INIT(0)
cnss: Setting MHI state: POWER_ON(2)
ueventd: found /etc/firmware/qca6390/amss20.bin
cnss: MHI status cb is called with reason MISSION_MODE(6)
```

So on this board, with this firmware image, the chip boots to mission mode under the stock driver. The
hardware, the rails, the clock buffers, the PCIe link and `amss20.bin` are all fine; nothing in the long
elimination table was ever the problem. Our own bring-up reaches mission mode too. What is left is what
the host does between QMI and `WMI_INIT`.

One host behaviour governs exactly the thing the firmware dies on. MHI's device wake is a vote to keep the
chip in M0: `mhi_assert_dev_wake` writes 1 to doorbell 127 and `mhi_deassert_dev_wake` writes 0, and a
working host only holds it while it is actually touching the device. 1172 asserted it on the theory that
the firmware should not be sleeping at all, and it has been held ever since. But the crash record says the
opposite: the firmware *wants* to sleep — `_whal_pmm_wlan_pwr_seq_hwdtim_sleep` polls
`WCSS_CC_WCSS_WLAN1_GDSCR/PWR_ON` for 0 and asserts at line 502 when the domain never collapses. A held
device wake is precisely what would keep that domain up.

So deassert it: with `sweetdwake=0` write 0 to the doorbell rather than leaving the vote wherever it was,
and keep `sweetwake=0` releasing `PCIE_SOC_WAKE` across the INIT window, so nothing on our side is holding
the chip awake while it sequences.

## 1180-apollo-quiet-init-window.patch

The same thought, one level up. ath11k is interrupt-driven across `WMI_INIT`: between sending the command
and the firmware's answer it touches nothing. We poll the copy engine registers every 10 ms, and each of
those reads is a PCIe transaction that pulls the link out of L1 and the chip out of MHI M2 — exactly the
states the firmware's power sequence is trying to reach. `sweetquiet=<ms>` stays off the bus entirely for
that long first.

## 1181-apollo-mhi-wake-after-init.patch

1179 worked. With the device wake deasserted, the firmware lived through the entire INIT window for the
first time since this started — 437 ms, against the 95 ms it had never once survived — and
`after INIT: firmware alive`. It died in the next breath, when we took the wake back:

```
[  41.773] SWEET MHI: device wake deasserted (doorbell 0x6f8)
[  41.773] SWEET WMI: INIT (variant 0, 332 bytes, 2 chains, mask 0x3)
[  42.210] SWEET WMI: WMI ready flag 0 after the INIT window
[  42.216] SWEET WMI: after INIT: CE3 head 0 tail 0 (hardware 4), firmware alive
[  42.216] SWEET MHI: *** SYS_ERR: the QCA6390 firmware crashed ***
```

So the diagnosis was right and the cure is only half-applied. We let the chip collapse and then woke it by
writing `PCIE_SOC_WAKE` and reading registers 5 us later, at a chip still in M2. ath11k never does that:
every register access past the MHI block goes through `mhi_device_get_sync`, which asserts the device wake
vote and waits for `MHISTATUS` to report M0 before anything touches the bus. Do the same — assert doorbell
127, poll `MHISTATUS` (BAR + 0x48, state in bits 15:8) for M0 with a 200 ms budget, and only then take
`PCIE_SOC_WAKE` and start draining the rings. The copy-engine poll loop moves after the wake too, since
every read in it was hitting a collapsed chip as well.

## 1182-apollo-watch-mhistatus.patch

k14g corrected k14f's reading. With a 300 ms quiet window and the proper MHI wake afterwards:

```
[  41.809] SWEET WMI: quiet window, 300 ms with no bus access
[  42.334] SWEET MHI: wake after INIT: mhistatus 0xff05 (state 255) after 200 ms
[  42.778] SWEET WMI: after INIT: CE3 head 0 tail 0 (hardware 4), firmware alive
[  42.778] SWEET MHI: *** SYS_ERR: the QCA6390 firmware crashed ***
```

`0xff05` is READY | SYSERR: the firmware was already dead when the window ended, and the wake loop spent
its whole 200 ms budget waiting for an M0 that was never coming. So k14f's "firmware alive" meant only
that no SYS_ERR *event* had arrived — the event rides a DMA write the chip cannot make once it is
collapsed or dead, which is why it appeared the instant we woke it. The device wake was never the thing
keeping the firmware alive for 437 ms; it was keeping us from hearing that it had died.

The instrument that settles this costs nothing: `MHISTATUS` lives at BAR + 0x48 in the MHI block, which is
always accessible and needs no wake vote. Poll it every 5 ms across the window and print the first
millisecond at which SYSERR sets. That gives the crash latency directly, under each configuration, and
tells us whether 1179 moved it at all from the 95 ms it has always been.

### What 1182 measured

Two runs of the same kernel, differing only in the wake flags, with `sweetquiet=600`:

| run  | device wake | PCIE_SOC_WAKE | SYSERR in MHISTATUS |
|------|-------------|---------------|---------------------|
| k14h | asserted    | held          | +80 ms after INIT   |
| k14i | deasserted  | released      | +80 ms after INIT   |

Identical, to the resolution of the probe. The wake state has no bearing on the crash: the firmware dies
80 ms after `WMI_INIT` whether the host is holding it awake, polling it, or standing completely off the
bus. 1179, 1180 and 1181 are therefore all corrections to how we observe and resume, not to the failure —
worth keeping, because they are what ath11k does and they are what made the measurement possible, but the
cause lies elsewhere. The "437 ms" of k14f was an artefact: the SYS_ERR event needs a DMA the dead chip
cannot make, so it only appeared when we woke the link.

## 1183-apollo-qmi-wlan-ini.patch

Reading ath11k's QMI path against ours line by line turned up three divergences, all in what the host
tells the firmware about itself before mission mode.

`QMI_WLANFW_WLAN_INI_REQ` (0x2f) is the one we never send at all. `ath11k_qmi_firmware_start` sends it
ahead of `wlan_cfg` and `wlan_mode` whenever `hw_params.fw_wmi_diag_event` is set, and QCA6390 sets it. It
carries one optional byte, `enablefwlog`, which ath11k sets to 1. Added here, behind `sweetini`.

The other two are already boot-args and need no code:

- `nm_modem`. ath11k builds it as `SLEEP_CLOCK_SELECT_INTERNAL_BIT | HOST_CSTATE_BIT` (QCA6390 has
  `internal_sleep_clock`), `| PLATFORM_CAP_PCIE_GLOBAL_RESET` (it has `global_reset`), `|
  PLATFORM_CAP_PCIE_PME_D3COLD` — 0x02 | 0x04 | 0x08 | 0x10 = **0x1e**. We have been sending 0x18, which
  is the two PCIe bits with both sleep-clock and C-state bits clear.
- `cal_done`. ath11k sends `ab->qmi.cal_done`, which is only set after a cold boot calibration, and
  QCA6390 has `cold_boot_calib = false` — so ath11k sends **0** and we have been sending 1. Telling the
  firmware its calibration is already valid when nothing ever calibrated is exactly the kind of lie that
  leaves a power sequence waiting on a domain that never settles.

`sweetnm=30 sweetcal=0` tests those two on their own, against the +80 ms the 1182 probe now measures.

## 1184-apollo-cold-boot-calibration.patch

1183 landed and changed nothing: `response 0x2f: result 0 error 0`, and still SYSERR at +80 ms. Nor did
`nm_modem=0x1e cal_done=0` (k14j). Our QMI exchange now matches ath11k message for message, byte for byte
where it matters, and every single request is accepted — and the firmware still dies 80 ms after INIT,
to the resolution of the probe, whatever the host does before or after. That number has not moved once.

Two things were confirmed rather than changed along the way. The phone's own device tree, read out of
recovery, gives the cnss node as `vdd-wlan-io 1.8 V`, `aon` and `dig` **on the same regulator** at 0.95 V,
`rfa1 1.9 V`, `rfa2 1.35 V` — exactly the four rails we vote (smpa4, smpa6, smpa5, smpc8) at exactly those
voltages. And our `wlan_cfg` CE table and service-to-pipe map are identical, entry for entry, to
ath11k's `ath11k_target_ce_config_wlan_qca6390` and `ath11k_target_service_to_ce_map_wlan_qca6390`.

What is left is something ath11k never does on a laptop but cnss2 does on *this phone*. QCA6390 has
`cold_boot_calib = false` in ath11k, so mainline goes straight to mission mode. The recovery log does not:

```
cnss: Posting event: COLD_BOOT_CAL_START(5), state: 0x0
```

Before this chip is ever used on apollo, it is brought up in calibration mode and calibrated. We have
never run that pass. Worse, we hand the firmware a CAL memory segment (QMI type 4, 864 KiB) full of
zeroes while `host_cap` claims the calibration is already done — and the thing it dies in is a *power*
sequence, `_whal_pmm_wlan_pwr_seq_hwdtim_sleep`, the kind of sequence whose timing comes from PMU trim
values that calibration is what produces.

`sweetmode=<n>` sets the mode in `wlan_mode` (0x22). Mode 7 is `ATH11K_FIRMWARE_MODE_COLD_BOOT`: the
firmware calibrates on its own, with no WMI at all, and answers with `QMI_WLFW_COLD_BOOT_CAL_DONE_IND`
(0x3e), which we already register for and now latch. The run watches MHISTATUS alongside it, so the
answer is unambiguous: either the chip completes a calibration — and then it can run its power sequences
and mission mode is simply missing their result — or it dies in that too, and the failure is upstream of
anything WMI.

### What 1184 measured

The firmware refuses the mode outright:

```
[  41.677] SWEET WLFW: response 0x22: result 1 error 90 (7 bytes)
[  41.677] SWEET WLFW: wlan_mode refused: result 1 error 90
```

Every request before it is accepted — ind_register, host_cap, respond_mem, cap, ten board-data segments,
m3, fw_init_done, wlan_ini, wlan_cfg — and then `wlan_mode` with mode 7 comes back `result 1 error 90`.
This build of `amss20.bin` has no calibration mode to enter, which matches ath11k's
`cold_boot_calib = false` for QCA6390: the `COLD_BOOT_CAL_START(5)` in the recovery log is cnss2's own
state-machine event name for the first power-up, not a QMI calibration pass. So the calibration theory is
dead, and the firmware itself killed it. `sweetmode` stays, since it cost nothing and the refusal is the
answer.

## 1185-apollo-wait-for-service-ready-ext.patch

k14n eliminated BT_EN too — driving it the way the stock driver does, WLAN_EN alone, still gives SYSERR at
+80 ms. But the log of that run shows something that had been sitting in plain sight for every run:

```
[  41.742] SWEET WMI: ep 1 event 0x1    tag 0x20  len 128 (336 bytes)
[  41.742] SWEET WMI: service ready: 2 RF chains, 0 memory requests
[  41.743] SWEET WMI: ep 1 event 0x4009 tag 0x1ac len 76 (1036 bytes)
[  41.743] SWEET WMI: ep 1 event 0x4022 tag 0x334 len 40 (80 bytes)
[  41.743] SWEET WMI: INIT (variant 0, 332 bytes, ...)
```

`WMI_TLV_CMD(WMI_GRP_PDEV)` is `(4 << 12) | 1` = 0x4001, and counting down that group's event list puts
`WMI_SERVICE_READY_EXT_EVENTID` at 0x4009 and `WMI_SERVICE_READY_EXT2_EVENTID` at 0x4022. The firmware
answers HTC setup complete with all three capability events back to back, and **we fire INIT in the same
millisecond as EXT2**, while it is still publishing what it can do.

ath11k never does that. `ath11k_service_ready_event` deliberately does not complete its service-ready
wait when the service bitmap advertises `WMI_TLV_SERVICE_EXT_MSG`; it waits for EXT, then EXT2, parses
the mac/phy and hw-mode capabilities out of them, and only then calls `ath11k_wmi_cmd_init`.

This patch latches both events and waits for them before INIT, then lets the chip settle
(`sweetsettle`, default 200 ms) with the rings drained. `sweetext=0` goes back to the old behaviour for a
controlled comparison. The +80 ms probe from 1182 is what reads the answer.

### What 1185 measured

Both events arrive and are latched, the chip settles for 200 ms, and then:

```
[  41.722] SWEET WMI: ext 1 ext2 1, settling 200 ms before INIT
[  41.942] SWEET WMI: INIT (variant 0, 332 bytes, ...)
[  42.032] SWEET MHI: SYSERR in mhistatus 0xff05 at +80 ms after INIT
```

So the race was real but harmless: INIT arriving mid-stream was not what killed it. The patch stays,
because it is what ath11k does and because having EXT and EXT2 latched is what any later capability
parsing will need. The run also turned up `WMI_SERVICE_AVAILABLE` (event 0x3, tag 0x22f) ahead of
service ready, which we had never logged either.

With 1179-1185 the host side is, as far as the ath11k source goes, exhausted: every QMI message, every
WMI message, the CE table, the service map, the rails and their voltages, the GPIO sequence, the wake
discipline and the event ordering all match, every request is accepted, and the firmware still dies at
+80 ms in the same WCSS power-collapse poll. That points away from what the host *says* and towards what
the chip *has* — and the one input to a PMU state machine that nothing in the QMI exchange can supply is
its sleep clock. Next: dump every RPMh resource cmd-db knows about (`sweetrpmhdump=1`) and look for a
clock the bootloader was holding up that we are not.
