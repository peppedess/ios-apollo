
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

## 1186-apollo-vote-divclkc1.patch

`sweetrpmhdump=1` printed every resource cmd-db knows about on this board. The slave-4 table has 66
entries, and exactly eight of them are clocks:

```
rfclka1=0x42700 rfclka3=0x42800 rfclkd3=0x43000 rfclkd4=0x40600
lnbclka1=0x42400 lnbclka2=0x42500 lnbclka3=0x42600 divclkc1=0x45b00
```

We vote seven of them (and `rfclka2`, which the dump confirms does not exist on this board — the lookup
has always refused it). The eighth, **`divclkc1`, we have never voted.**

On a Qualcomm PMIC a `divclk` output is the divided 32.768 kHz sleep clock, and on these boards it is
what feeds a companion WLAN/BT chip. That matters here more than any other missing vote: a PMU state
machine sequences a power collapse against its sleep clock, and the firmware's failure is a power
collapse that never completes — `WCSS_CC_WCSS_WLAN1_GDSCR/PWR_ON` polled for 100 ms and never moving,
from the first sample to the last. Not a race, not a slow settle: a domain that never responds at all,
which is what a missing sequencing clock looks like.

cnss2 asks for no clocks at all on this phone (`Failed to get optional clock rf_clk, err = -2`), so
under Android the vote is simply inherited from whatever the bootloader left up — a vote our kernel
would have dropped when it took over RPMh. That also explains why the stock driver reaching mission mode
proved nothing about this: the Q6 and MHI run off the XO, and nothing in that path ever needs the sleep
clock. Only the WLAN section does, and the stock driver never got that far.

### What 1186 measured

The vote goes through — `SWEET RPMH: divclkc1 addr=0x45b00 ... SWEET PCIE: rpmh clock divclkc1 -> 0` —
and SYSERR still lands at +80 ms after INIT. Eliminated. All eight clock resources this board has are now
voted, and none of them is what the WCSS is waiting for.

### Where the host-side search stands

Measured with the 1182 probe, every one of these leaves the crash at +80 ms, unmoved:

| run  | what changed |
|------|--------------|
| k14h/k14i | MHI device wake and PCIE_SOC_WAKE, held vs released |
| k14i | no bus access at all across the window |
| k14j | `nm_modem` 0x1e and `cal_done` 0, ath11k's values |
| k14k | `QMI_WLANFW_WLAN_INI` added |
| k14m | `wlan_mode` 7 — *refused by the firmware*, result 1 error 90 |
| k14n | BT_EN left off, WLAN_EN alone, as the stock driver does |
| k14o | wait for SERVICE_READY_EXT and EXT2, settle 200 ms, then INIT |
| k14q | `divclkc1` voted |

The one item left from the ath11k diff is `shadow_reg_v2` in `wlan_cfg`, which QCA6390 sets
(`supports_shadow_regs = true`) and we send empty. After that the host side is genuinely exhausted, and
the question becomes one we have never actually answered: **has this chip's WLAN section ever worked on
this phone?** The stock driver in recovery proved the Q6 boots and MHI reaches mission mode, but it never
touched the WCSS — nothing in that path does. Android no longer boots, so we have no witness. The way to
get one is the recovery's own `qcacld` driver, which is built into that kernel (`wlan_hdd_state wlan
major(485) initialized`, `/dev/wlan` present); it is gated on QMI, which is gated on QRTR's name service.

### Two more eliminations, and the recovery route closed

`sweetdp=1` builds the whole HAL data path before INIT the way ath11k does — 15 rings up, 32766 link
descriptors, REO and TCL programmed — and the crash does not move:

```
[  42.091] SWEET DP: 15 rings up, 2072 KiB used; REO gen 0xc0000dc, TCL ctrl 0x9e000
[  42.091] SWEET WMI: INIT (variant 0, 332 bytes, ...)
[  42.181] SWEET MHI: SYSERR in mhistatus 0xff05 at +80 ms after INIT
```

And the recovery route to a full stock reference is closed for good: that kernel has **no QRTR at all** —
no module, nothing in `/proc/net/protocols`. cnss2's QMI rides QRTR over MHI, so it can never complete
there, whatever is done from userspace; `qrtr-ns` is beside the point. The `qcacld` driver is built in
(`/sys/module/wlan`, `/dev/wlan`) and would drive the WCSS if it could ever be told the firmware is
ready, but it cannot. The vendor partition is not mapped either (`/dev/block/mapper` is empty), so there
is nothing to borrow. Getting a witness for this chip's WLAN section would take a recovery kernel built
with QRTR, which is a project of its own.

## 1187-apollo-cnss2-host-cap.patch

The user settled the open question: Wi-Fi worked on this phone for years, under MIUI and under LineageOS.
The chip's WLAN section is sound, the radio works, and whatever is wrong is ours. That also means there
is a host that is known to drive this exact chip on this exact board — and it is not ath11k. It is
`cnss2`, in the phone's own kernel, which we had never read.

Its `host_cap` is not ath11k's. Reading `cnss_wlfw_host_cap_send_sync` and the
`wlfw_host_cap_req_msg_v01_ei` table out of `LineageOS/android_kernel_xiaomi_sm8250` gives the real TLV
map and three differences:

- **no `nm_modem` (0x13).** ath11k sends it because its QCA6390 hw_params carry `internal_sleep_clock`,
  which exists for the non-Qualcomm platforms ath11k runs on. cnss2 never sends it on a Qualcomm
  platform. We have been sending it every single run, in every variant — 0x18, 0x1e, 0 — and "0" is not
  the same message as *absent*: it tells the firmware "use the external sleep clock", where absent lets
  the firmware decide from its board data.
- **no `mem_cfg_mode` (0x1c).** Also ath11k's.
- **`ddr_range` (0x1f)**, two 64-bit words — start and size of the window of host DDR the chip may
  touch. On Android that is the SMMU IOVA range, `0xa0000000` for `0x10010000`. We have never sent it, so
  the firmware has only ever learned where its memory is from `respond_mem`, one segment at a time.

This patch sends cnss2's shape: num_clients, bdf_support, m3_support, m3_cache_support, cal_done and
ddr_range, with nothing else. `host_cap` goes out before `respond_mem`, so the segments do not exist yet
and the range covers the window the pool allocates from — runs have placed the firmware's DDR anywhere
between 0xd0000000 and 0xd2800000, so a single guessed region would leave the next run outside it.
`sweethostcap=0` restores ath11k's shape for a controlled comparison.

### The carveout question, answered

A suggestion worth checking: that Android's WLAN firmware memory sits in a fixed reserved region which
TrustZone's XPU protects, and that our pool being elsewhere would block the chip. The phone's own device
tree settles it. `cnss_wlan_region` is a `shared-dma-pool`:

```
compatible   shared-dma-pool     reusable
size         0x1400000           alignment    0x400000
alloc-ranges 0x0 0x0 0x0 0xffffffff
```

Reusable CMA, 20 MiB, 4 MiB-aligned, and **no fixed address at all** — `alloc-ranges` is the whole low
4 GB. Under Android the firmware's DDR lands wherever CMA happens to put it, boot to boot. There is no
stock address to match and no page-level requirement to violate; our pool at 0xd0000000 is as valid as
any. (`pil_wlan_fw_region@86700000` is a 1 MiB removed-dma-pool for the PIL-loaded integrated WCN, not
for the PCIe part.) Dismissed on evidence.

Also corrected: the first attempt at cnss2's `host_cap` came back `result 1 error 1`. `ddr_range` is a
`STATIC_ARRAY` of `QMI_WLFW_MAX_HOST_DDR_RANGE_SIZE_V01` = 3 structs of two u64, so the TLV carries all
48 bytes with the unused entries zeroed; sending only the first 16 is a malformed message.

## 1188-apollo-shadow-registers.patch

The last item in the ath11k diff. QCA6390 carries `supports_shadow_regs`, and `wlan_cfg` has a TLV for
the list — 0x14 in the firmware's own message definition, a byte count followed by one u32 address per
entry, up to 36. We have always sent it empty.

There is no static table to copy. ath11k builds the list at probe time from the SRNG register map:
`ath11k_hal_srng_shadow_config` walks every ring type that is neither a copy engine nor an LMAC ring, in
enum order, over each type's `max_rings`, and `ath11k_ce_shadow_config` then adds the copy engines that
have entries — source rings once, destination rings twice (the ring and its status ring). Each entry is
the ring's HP register, or HP + 4 for a destination ring, since a destination ring shadows its tail.

Walking that with `qca6390_regs` gives thirty addresses: REO at 0xa38000 with its HP block at +0x3000
(four REO_DST, the exception ring, reinject, command, status), TCL at 0xa44000 with HP at +0x2000 (three
TCL_DATA, command, status), WBM at 0xa34000 (idle link, SW2WBM release, five WBM2SW release), and the
copy engines at 0xa00000 and 0xa01000 stepping 0x2000 — CE0, CE3, CE4 and CE7 as sources, CE1, CE2 and
CE5 as destinations with their status rings. Thirty of a possible thirty-six.

`sweetshadow=0` sends it empty again.

### What 1187 and 1188 measured

Both accepted, neither moves the crash:

```
[  41.491] SWEET WLFW: host_cap (cnss2 shape): cal_done 0, ddr_range 0xc0000000 + 0x40000000
[  41.502] SWEET WLFW: response 0x34: result 0 error 0
...
[  42.141] SWEET MHI: SYSERR in mhistatus 0xff05 at +80 ms after INIT
```

```
[  41.685] SWEET WLFW: wlan_cfg with 30 shadow registers
[  41.707] SWEET WLFW: response 0x23: result 0 error 0
...
[  42.077] SWEET MHI: SYSERR in mhistatus 0xff05 at +80 ms after INIT
```

**The host-side diff is now exhausted.** Against ath11k and against cnss2 — the driver that ran this chip
on this board for years — every QMI message, every TLV, the CE table, the service map, the shadow
register table, the rails and their voltages, every clock resource the board has, the GPIO sequence, the
wake discipline, the event ordering and the data path all match or have been tried both ways. Every
request is accepted. The crash has not moved by one millisecond across sixteen experiments.

### What the failure actually says

Worth stating plainly, because it narrows what is left. The firmware asserts at line 495 of
`_whal_pmm_wlan_pwr_seq_hwdtim_sleep`, polling the WLAN1 GDSC for PWR_ON to clear. It does **not** assert
in the clock-off polls that precede it (`WCSS_CC_WCSS_MAC0_MAC_CBCR/CLK_OFF`,
`WCSS_CC_WCSS_PHYA_320_CBCR/CLK_OFF` are separate call sites with their own line numbers), and it does
not assert on the way up. So at INIT the WCSS powers **on** correctly, its clocks turn **off**
correctly, and then the domain refuses to collapse — for the firmware's whole 100 ms budget, from the
first sample to the last.

A GDSC that powers on but will not collapse is either in hardware control, where SW_COLLAPSE is ignored
and the domain follows hardware requests, or still has a power request asserted into it from another
block. Neither is something the host writes directly. The next step is therefore not another host-side
guess: it is to disassemble the path from the `WMI_INIT` handler to this sequence and find what selects
it, through the ops table at 0x14280e0 that holds the function pointer.

## 1189-apollo-global-board-data.patch

We have been sending the wrong board file since the first run.

The chip reports board id 0xff, and the note on 1140 said cnss2's rule for 0xff is the plain
`bdwlan.elf`. That is ath11k's rule, not cnss2's. In the phone's own kernel,
`cnss_get_bdf_file_name` hands `board_id == 0xFF` to `cnss_get_xiaomi_bdf_elf_file_name`, which picks by
hardware platform **and country**:

```c
case HARDWARE_PLATFORM_APOLLO:
	switch (hw_country_ver) {
	case CountryGlobal: ELF_BDF_FILE_NAME_J3S_GLOBAL;  /* bd_j3sgl.elf */
	case CountryIndia:  ELF_BDF_FILE_NAME_J3S_INDIA;   /* bd_j3sin.elf */
	default:            ELF_BDF_FILE_NAME_J3S;         /* bd_j3s.elf   */
	}
```

And this phone's own cmdline settles which branch it takes:

```
androidboot.hwc=GLOBAL
```

So for the years this chip worked, the driver loaded **`bd_j3sgl.elf`**. Every run of ours has sent
`bd_j3s.elf`, the China variant — a different file, 57968 bytes against 58040, differing in 4981 of
them. Both are on the modem partition, along with seventeen other variants, so nothing ever complained.

Board data is where the PMM's power and clock-gating configuration lives. It is the one input that can
let everything digital work — boot, QMI, HTC, WMI capabilities, all of which do work — and then break
precisely when the firmware sequences the radio's power domains, which is where we die. `sweetbdf` now
picks: 0 the global file (the default), 1 `bd_j3s.elf`, 2 the generic `bdwlan.elf`.

### k14v: the global board file is not it either

`k14v` loaded `bd_j3sgl.elf` and died exactly as before:

```
[  41.328] SWEET WLFW: board file bd_j3sgl.elf, 57968 bytes (7f454c46)
[  41.758] SWEET WMI: INIT (variant 0, 332 bytes, 2 chains, mask 0x3): ...
[  41.848] SWEET MHI: SYSERR in mhistatus 0xff05 at +80 ms after INIT
```

±0 ms against every other run. The board file was the right thing to fix — we had been sending the
China variant for months — but it is not the cause.

## 1190-apollo-wlaon-shutdown-en.patch

One bit, latched in a domain that never loses power.

`WLAON_QFPROM_PWR_CTRL` (0x1f8031c) has two bits that matter: `VDD4BLOW_SW_EN` (bit 2) and
`SHUTDOWN_EN` (bit 0). ath11k's `ath11k_pci_sw_reset` clears **only** bit 2, and so have we since the
first run, because that is the code we ported. ath11k is right for the cards it drives. It is wrong here,
and apollo's own device tree says so:

```
soc/qcom,cnss-qca6390@b0000000/qcom,set-wlaon-pwr-ctrl
```

That property is what makes the stock cnss2 run `cnss_pci_set_wlaon_pwr_ctrl()` on this board, and the
function clears bit 0 together with bit 2, immediately before `cnss_pci_start_mhi()`:

```c
if (set_shutdown) val |=  QFPROM_PWR_CTRL_SHUTDOWN_EN_MASK;
else              val &= ~QFPROM_PWR_CTRL_SHUTDOWN_EN_MASK;
```

The same function **sets** bit 0 on every power-down (`set_wlaon_pwr_ctrl(pci_priv, false, true, …)` in
all three teardown paths) and then sleeps 1-2 ms to let it take. WLAON is the always-on domain: it
survives a WCSS power collapse, a Q6 reset and our `soc_global_reset`. So the shutdown request the last
Android left behind — or the one cnss2 itself set during our recovery experiments, which power-cycled the
chip through that very path — is still standing when iOS boots, and nothing of ours has ever cleared it.

It fits every symptom, including the ones that made the fault look impossible:

- A shutdown request in the always-on domain does not stop the Q6, MHI, QMI, HTC or WMI capability
  exchange. All of that is digital and all of it works.
- It stops a **power-domain collapse**. Which is precisely and only where we die: WLAN1's GDSC powers on
  (no assert on the way up), its clocks gate off (the `CLK_OFF` polls at their own line numbers pass),
  and then the domain refuses to collapse, so `_whal_pmm_wlan_pwr_seq_hwdtim_sleep` line 495 times out
  polling `WCSS_CC_WCSS_WLAN1_GDSCR/PWR_ON` for 0 — on the firmware's own 100 ms budget, hence ±0 ms
  every single run.
- It is board-specific. A generic ath11k card has no `qcom,set-wlaon-pwr-ctrl`, so upstream never needed
  the write and we never inherited it.

`sweetqfprom=0` reverts to clearing bit 2 alone. The register is read and logged at both points it can be
touched — in the reset path and once more just before INIT — so the run says outright whether bit 0 was
set when we arrived, and whether the firmware's own boot re-arms it between the two.

### k15: SHUTDOWN_EN was already clear

```
[  35.308] SWEET MHI: WLAON_QFPROM_PWR_CTRL 0x6 -> 0x2 (shutdown_en was 0, vdd4blow was 1)
[  41.737] SWEET WMI: WLAON_QFPROM_PWR_CTRL before INIT 0x2 -> 0x2
[  41.827] SWEET MHI: SYSERR in mhistatus 0xff05 at +80 ms after INIT
```

Bit 0 was 0 when we arrived and stayed 0. The write is still right — it is what the stock driver does on
this board and it costs nothing — but the bit was never the problem. ±0 ms, as every run since the first.

## 1191-apollo-power-state-probe.patch

cnss2's register map gives us the one thing we had been missing: a host address for the registers the
firmware dies on.

```c
#define QCA6390_WCSS_WFSS_PMM_WFSS_PMM_R0_PMM_CTRL 0x00B60164
#define QCA6390_WCSS_PMM_TOP_PMU_CX_CSR            0x00B70080
```

The firmware's own strings name those same registers at `0xe0b60164` and `0xe0b70080`. The two views are
the same blocks with the top nibble swapped — so every address in the power sequence we disassembled has
a host address, and `0xe0c300c4`, the WLAN1 GDSCR the firmware dies polling for PWR_ON, is `0x00c300c4`
from here.

WCSS is unsafe to read directly while its clocks are off (k13n hung the phone on `0xc30004`), but WLAON
is the always-on domain and carries the host-visible mirrors the stock driver reads in its own crash
dump: `WL_PWR_STATUS_REG` (0x1f8002c) and `WCSS_TCSR_PMM_SR_STATUS_LO/HI` (0x1f806d0 / 0x1f806cc). This
patch dumps ten WLAON power registers once before INIT — including `GDSC_DELAY_SETTING` and
`SETTING2`, which configure the GDSC handshake timing itself — and then polls the three status registers
every 5 ms alongside MHISTATUS, printing every change.

That turns the 80 ms from a black box into a timeline. Until now everything we know about the failure
came from reading the firmware's disassembly and inferring; this is the first probe that watches the
power state machine while it fails. `sweetpwr=0` reverts to MHISTATUS alone.

### k16: the first direct look at the failure

```
[  41.729] SWEET WMI: INIT (variant 0, 332 bytes, 2 chains, mask 0x3): ...
[  41.730] SWEET PWR: WLAON soc_power_ctrl 0x117 wl_pwr_status 0x9 pmm_sr_lo 0 pmm_sr_hi 0
                      gdsc_delay 0x25112222/0x222 rfa_mem_slp 0 wcssaon_cfg 0 clk_kdf 0 clk_hfrc 0
[  41.730] SWEET PWR: +0 ms  wl_pwr_status 0x9 pmm_sr 0:0
[  41.798] SWEET PWR: +60 ms wl_pwr_status 0xf pmm_sr 0:0
[  41.820] SWEET MHI: SYSERR in mhistatus 0xff05 at +80 ms after INIT
```

`WL_PWR_STATUS` moves — 0x9 to 0xf, bits 1 and 2 appearing — twenty milliseconds before the assert. So
the sequence is not stalled from the start: something in the power state machine does happen, late, and
then the firmware gives up. The GDSC delay settings are programmed (0x25112222 / 0x222), the save/restore
status stays flat at zero, and the three WLAON config registers that are zero are zero in the stock
driver too — cnss2 only ever reads them, in its crash dump; nothing writes them.

The firmware's own strings settle how far it gets:

```
WFSS_PMM_R0_PMM_WLAN1_CFG_REG1/MAC1_IDLE_STATUS
WCSS_WCMN_R0_APPS_AGGRE_INTR_STATUS/PMM_WCMN_WLAN1_LS_DONE_INTR
WCSS_CC_WCSS_WLAN1_GDSCR/PWR_ON
```

Three waits, in that order, each with its own line number and its own assert. The one that fires is the
third. So MAC1 goes idle, the low-power-state handshake completes, and only then does the GDSC refuse to
drop PWR_ON.

## 1192-apollo-wcss-debug-status.patch

More resolution, and a second vantage point.

`PCIE_PCIE_LOCAL_REG_WCSS_STATUS_FOR_DEBUG_HIGH/LOW` (0x01e0313c / 0x01e03140) sit in the PCIe local
block — the same always-accessible region as the LTSSM and hot-reset registers we already drive — and are
the host's window into the WCSS state machine without reading WCSS itself, which is what hung the phone
in k13n. This patch swaps the flat save/restore pair for those two and samples every 1 ms for the first
120 ms instead of every 5, so the 60 ms step and whatever precedes it are resolved properly.

### k17: one step, and then nothing

At 1 ms resolution the whole window holds exactly one transition:

```
+0 ms   wl_pwr_status 0x9  wcss_dbg_low 0x4402002
+55 ms  wl_pwr_status 0xf  wcss_dbg_low 0x3402001
+76 ms  SYSERR
```

Fifty-five milliseconds of nothing at all, one state change, and twenty-one milliseconds later the
assert. Both fields in the debug register step down by one — 2 to 1 in the low nibble, 4 to 3 in bits
26:24 — a state machine advancing a single step and then stopping where it should have carried on.

That also fixes the firmware's budget, which we had only bounded before. The poll does not start at INIT;
it starts when the collapse is requested, at +55 ms, and gives up ~21 ms later. The two constants at the
poll wrapper, 100 and 1000, are a hundred iterations of roughly two hundred microseconds.

So the question is now exactly this: after a correct collapse request, WLAN1's GDSC keeps PWR_ON asserted
for more than twenty milliseconds. A GDSC power-down is microseconds of work.

## 1193-apollo-wlaon-counter.patch

What times a GDSC power-down handshake is WLAON, and WLAON runs off the chip's always-on clock. If that
clock is slow or stopped, every delay counted in it stretches, and a handshake that should take
microseconds overruns the firmware's twenty-millisecond budget — which is the exact shape of k17.

Two things make this measurable rather than another guess:

- The capability response carries **TLV 0x17, `time_freq_hz`**: the firmware's own statement of the rate
  it believes that counter runs at. cnss2 keeps it as `plat_priv->device_freq_hz` and divides by it to
  convert device ticks to microseconds. We have been receiving this TLV since the first run and ignoring
  it.
- `WLAON_GLOBAL_COUNTER_CTRL5` (0x1f80120) enables the counter, `CTRL3`/`CTRL4` (0x1f80118 / 0x1f8011c)
  are its low and high halves — exactly what `cnss_pci_get_device_timestamp` reads.

So: clear the counter, start it, sample it across 100 ms of our own time, and print the measured rate
beside the rate the firmware expects. The nine `RTC_CLK_CAL_CTRL` registers go in the same dump, since
they sit right beside the GDSC delay settings and are where the chip calibrates that clock.

If the two numbers agree, the always-on clock is fine and this whole line of reasoning is dead. If they
disagree, we have the cause — and it is a board-level clock, which is exactly the class of thing a port
gets wrong and a stock driver never has to think about.

### k18: the counter is frozen — but the measurement landed in the wrong place

```
[  41.310] SWEET WLFW: device counter frequency 19200000 Hz
[  41.841] SWEET PWR: WLAON counter 127653232 -> 127653232 in 100 ms = 0 Hz, firmware expects 19200000 Hz
[  41.841] SWEET PWR: RTC cal 0 0xfa0 0x17700 0x5d2 0x59688c 0 0 0x1 0x1
[  41.841] SWEET MHI: SYSERR in mhistatus 0xff05 at +0 ms after INIT
```

Not one tick in a hundred milliseconds, against the 19.2 MHz the firmware expects — WLAON counts off the
XO, not off a 32 kHz sleep clock. But the measurement sat inside the quiet window, which runs *after*
INIT, so its own 100 ms delay let the firmware crash first: `wl_pwr_status` already reads 0xf and
`soc_power_ctrl` 0x317 instead of the 0x117 of k16 and k17. A dead chip's counter standing still proves
nothing.

## 1194-apollo-counter-before-init.patch

Move the measurement to before the INIT is sent, where the chip is demonstrably healthy, and take the
counter once more at the end of the window so the run says whether it kept running while the power
sequence failed. Nothing else changes.

### k19: the always-on clock is fine, and the measurement was mine to get wrong

With the chip healthy before INIT (`soc_power_ctrl 0x117`, `wl_pwr_status 0x9`):

```
[  41.380] SWEET WLFW: device counter frequency 19200000 Hz
[  41.911] SWEET PWR: WLAON counter 127548504 -> 127548504 in 100 ms = 0 Hz
```

The counter looked dead, and it is not. 127548504 ticks at 19.2 MHz is 6.643 s, and the chip was reset
at 35.3 s with INIT at 41.911 s — 6.6 s. The always-on counter tracks wall time exactly.

The zero delta was the method. cnss2's sequence is clear, enable, read **immediately**, clear:

```c
cnss_pci_clear_time_sync_counter(pci_priv);
cnss_pci_enable_time_sync_counter(pci_priv);
host_time_us = cnss_get_host_timestamp(plat_priv);
ret = cnss_pci_get_device_timestamp(pci_priv, &device_time_us);
cnss_pci_clear_time_sync_counter(pci_priv);
```

CTRL5 is not a free-run enable, it is a capture: it latches the global counter into CTRL3/CTRL4. Reading
the same pair 100 ms later returns the same latched sample. So the clock hypothesis is dead, and we have
gained something instead — a calibrated 19.2 MHz timestamp of the chip's own always-on domain, readable
from the host.

### The stock driver's own log, read today

Running the recovery reference again and grepping it properly settled two things and killed a third.

```
cnss: BT_EN_GPIO State: Off. Delay WLAN_GPIO enable
cnss: Assert WLAN_EN GPIO successfully          (105 ms later)
cnss: Read register offset 0x1f8031c, val = 0x6
cnss: Write val 0x2 to register offset 0x1f8031c
cnss: MHI status cb is called with reason MISSION_MODE(6)
```

- The QFPROM write is confirmed from the other side: the stock driver reads the same 0x6 and writes the
  same 0x2 we now write in 1190. Identical.
- The BT_EN rule is real but we already satisfy it. cnss2 waits 100 ms before WLAN_EN only when BT_EN is
  off; when BT_EN is on it asserts WLAN_EN straight away, which is our default path.
- **No BDF line at all.** This path never downloads a board file — it goes
  `COLD_BOOT_CAL_START` → MHI `POWER_ON` → `MISSION_MODE` with no QMI, because recovery has no QRTR. So
  the reference cannot give us ground truth on which board file the stock driver picks. That question
  stays open, and `bd_j3sgl.elf` stays an inference.

Cold boot calibration is also confirmed dead rather than untried: `QMI_WLFW_CALIBRATION_V01` is 7, which
is exactly what k14m sent, and the firmware refused it with `result 1 error 90`.

## 1195-apollo-init-chain-override.patch

Twenty-some eliminations in and every one of them has been host-side plumbing — wakes, votes, clocks,
board files, QMI message shapes. The INIT payload itself has never changed. The three `sweetwmivar`
variants only ever altered the frame's *length*; the resource config inside it has been byte-identical
since the first run.

The chain count is the sharpest knob on it. At two chains and mask 0x3 the firmware configures both MACs
and the DBS path, and the power sequence it then runs covers WLAN1 and WLAN2 — the same function polls
both GDSCRs, at line 495 and line 598. A single-chain INIT is a materially different target
configuration, and if the collapse that hangs belongs to the dual-MAC bring-up it should not be
attempted at all.

`sweetchains=1` forces it. Unset keeps whatever the service-ready event reported, which is 2.

### k20: one chain changes nothing

```
[  43.443] SWEET WMI: INIT (variant 0, 332 bytes, 1 chains, mask 0x1): ...
+0 ms   wl_pwr_status 0x9  wcss_dbg_low 0x4402002
+55 ms  wl_pwr_status 0xd  wcss_dbg_low 0x3402001
+56 ms  wl_pwr_status 0xf  wcss_dbg_low 0x3402001
[  43.532] SWEET MHI: SYSERR in mhistatus 0xff05 at +76 ms after INIT
```

The override took — mask 0x1, a single chain, no DBS — and the failure is identical to the millisecond.
At 1 ms sampling we now see the move is two steps rather than one (bit 2 at +55, bit 1 at +56), which is
the only new detail. The target configuration is not what decides this.

### The firmware's whole register vocabulary

The image contains exactly twenty `BLOCK_REG/FIELD` strings, and they are all polling targets. Laid out
in address order they map the power code cleanly:

```
1378c2  WCSS_WCMN_R0_APPS_AGGRE_INTR_STATUS/PMM_WCMN_WLAN1_LS_DONE_INTR
137924  WFSS_PMM_R0_PMM_WLAN1_CFG_REG1/MAC1_IDLE_STATUS
137a08  _whal_pmm_wlan_pwr_seq_hwdtim_sleep___RAM
137a32    WCSS_CC_WCSS_WLAN1_GDSCR/PWR_ON
137a52    WCSS_CC_WCSS_WLAN2_GDSCR/PWR_ON
137a72    WCSS_CC_WCSS_MAC0_MAC_CBCR/CLK_OFF
137a95    WCSS_CC_WCSS_PHYA_320_CBCR/CLK_OFF
137ab8    WFSS_PMM_R0_WLAN1_STATUS_REG2/WLAN1_SM
137b4c  _whal_pmm_wlan_pwr_seq_partial_wake___RAM
137b76  _whal_pmm_wlan_pwr_seq_full_wake___RAM
137b9d  whal_stop_wlan_ss_seq___RAM
137c04  whal_power_exit_lightsleep___RAM
137c25  WHAL_PMAC_PRE_SLEEP_EVENT … POST_AWAKE_EVENT, SLEEP_ABORT_EVENT, PRE/POST_DTIM_CHAN_EVENT
137d08  LPUTILS_WMAC_RECIPES_ID
137e0a  whal_wmac_h2s_grant_check___RAM
```

This corrects something we had backwards. The strings sit in declaration order inside each function, and
`WLAN1_GDSCR/PWR_ON` is the **first** one in `hwdtim_sleep` — so the GDSC poll is not the third check
after MAC-idle and LS_DONE, it is the opening one. `MAC1_IDLE_STATUS` and `LS_DONE_INTR` belong to the
function before it.

Which makes the 55 ms the real question. If the preceding function's own waits were healthy they would
take microseconds, not 55 ms. A 55 ms pause followed by the power status moving and then a 21 ms timeout
reads like the *preceding* handshake also timing out and the firmware carrying on regardless — so the
first thing to go wrong may be the LS_DONE interrupt never arriving, with the GDSC assert as the
consequence rather than the cause.

`whal_wmac_h2s_grant_check` and the `H2S_GRANT_ISSUED` / `O_WLAN1_H2S_GRANT_INT` pair are new: there is a
grant handshake in this chip's sleep arbitration. They sit after `full_wake` in address order, so they
are not in the failing path, but they confirm the sleep sequence is arbitrated rather than unilateral.

### Android is gone, and recovery cannot host the real driver

The plan was to boot LineageOS, where this phone's Wi-Fi worked for years, and capture the exact INIT the
stock driver sends. Android does not boot:

```
Can't load Android system. Your data may be corrupt.
Reason: init_user0_failed
```

`/data` never initialises, so the system never reaches the point of loading a Wi-Fi driver. Restoring it
means a factory reset, which erases the phone — not something to do for a diagnostic.

The fallback was to host the stock driver inside recovery by mounting `vendor` and loading QRTR. That is
closed too, and now definitively:

```
Linux 4.19.325-cip136-st20-perf    (recovery)
/dev/block/by-name:  super, vbmeta_product, vbmeta_system, vbmeta_vendor
/dev/block/mapper:   No such file or directory
lsmod:               empty
find / -name '*.ko': nothing
/proc/net/protocols: no QIPCRTR
```

`vendor` lives inside `super` with no device-mapper and no `dmctl`/`lptools` to map it; the recovery
kernel is monolithic, so there is nothing to load even if we extracted a module; and QRTR is simply not
compiled in. `losetup` and `erofs` exist, so super could in principle be mounted by computing the LP
metadata offsets — but with no module loading that buys nothing.

So there is no working reference on this hardware to diff against. Whatever we learn, we learn from the
chip.

## 1196-apollo-read-the-gdscr.patch

Then read the register the firmware dies on, from the other side.

By cnss2's map and the nibble swap, the WLAN1 GDSCR the firmware polls at `0xe0c300c4` is `0x00c300c4`
from the host. k13n hung the phone reading `0xc30004`, but that was a blind sweep of a block whose clocks
were off; here the read happens before INIT, with the chip idle and healthy and `wl_pwr_status` at 0x9.

One number settles what twenty-six eliminations could not. The GDSCR carries PWR_ON at bit 31,
SW_COLLAPSE at bit 0 and **HW_CONTROL at bit 1** — and HW_CONTROL is the question. The firmware never
writes the GDSCR itself; it programs the PMM and waits for the hardware sequencer to collapse the domain.
If HW_CONTROL is clear, the PMM does not own that GDSC, and no amount of correct sequencing will ever
bring PWR_ON down. That would explain a sequence whose earlier steps all pass and whose last step never
completes, and it would explain why nothing we send changes the outcome by a millisecond.

The PMM's own `WLAN1_STATUS_REG2` is read first, being in the always-on part of WCSS, and each read is
announced on its own line before it is taken. If the log stops after one of those lines, that read hung
the bus — which is an answer too.

### k21: HW_CONTROL is clear

The read went through — no hang, nothing upset, and the number is unambiguous:

```
[  42.761] SWEET GDSC: WLAN1_STATUS_REG2 0x1 (WLAN1_SM)
[  42.761] SWEET GDSC: WLAN1_GDSCR 0xa0223800: pwr_on 1 sw_collapse 0 hw_ctrl 0
[  42.761] SWEET GDSC: WLAN2_GDSCR 0xa0223800: pwr_on 1 sw_collapse 0 hw_ctrl 0
```

Both domains: powered, not collapsed, and **HW_CONTROL clear**.

That last bit is the whole story. A Qualcomm GDSC with HW_CONTROL clear is in software control: it comes
down only when SW_COLLAPSE is written, and it ignores the hardware sequencer entirely. And the firmware
never writes SW_COLLAPSE — every write in the sequence we disassembled goes to the PMM at `0xe0b6xxxx`
and `0xe0b7xxxx`, and nothing anywhere in it touches WCSS_CC at `0xe0c3xxxx`. The firmware programs a
sequencer and waits for the domain to come down, while the domain is not listening to that sequencer.

It accounts for every observation we have collected, including the ones that made the fault look
impossible:

- The earlier steps pass because they are real handshakes with blocks that do respond — MAC idle,
  LS_DONE, the clock branches gating off.
- The last step can never complete, no matter how correct the sequence driving it.
- The timing is identical to the millisecond in every run, because it is a fixed firmware timeout with
  nothing racing against it.
- Nothing we sent from the host ever changed it, because none of it was ever about the host.

## 1197-apollo-gdsc-hw-control.patch

`sweethwctrl` (default on) sets bit 1 on both GDSCRs before INIT, handing the domains to the hardware
sequencer the firmware is talking to. If the stock bring-up does this somewhere we never reproduced, this
is the missing write.

`sweetcollapse` (default off) answers the other question if the first does not: can WLAN1's domain
collapse at all? Asserting SW_COLLAPSE and watching PWR_ON costs one write, and distinguishes "the PMM
has no authority" from "something is holding this rail up regardless of who asks". It stays off by
default because it takes the MAC and PHY down underneath a running firmware; the old value goes straight
back.

### k22 and k23: the domain is fine, and nobody is asking it

k22 set HW_CONTROL before INIT. The write took — `WLAN1 0xa0223802 WLAN2 0xa0223802` — and the failure
did not move: `SYSERR at +76 ms`, with the same +55/+56 power-status step. Handing the domain to the
hardware sequencer is not enough, so the PMM is not driving this register either way.

k23 answered the question that actually mattered:

```
[  41.758] SWEET GDSC: sw_collapse test: 0xa0223800 -> 0x223801 (pwr_on 0), restored to 0xa0223800
```

**Writing SW_COLLAPSE takes PWR_ON to zero in under five milliseconds**, and restoring the register
brings the domain straight back. The GDSC is in perfect health. Nothing is holding the rail up, no clock
branch, no retention override, no second master. The domain collapses the instant anyone with authority
asks — and the firmware is not that anyone. It programs the PMM at `0xe0b6xxxx`/`0xe0b7xxxx`, waits, and
the PMM's sequencer never reaches `0xe0c300c4`, with HW_CONTROL set or clear.

Six weeks of host-side theories, and the answer was a single bit in a register the host can write.

## 1198-apollo-collapse-for-the-firmware.patch

Then ask on its behalf.

The firmware begins polling at +55 ms and gives up around +76. `sweetpoke=<ms>` asserts SW_COLLAPSE on
both WLAN1 and WLAN2 at +50 ms, holds it through that window, and releases.

This is a crutch and not a fix — it does not teach the PMM to own the domain, and the firmware will want
the domain back on the way up, which is why the hold is bounded and the release is logged. But if the
assert stops firing, the diagnosis is confirmed to the last detail and we finally see what the firmware
does next. That would be the first new ground past this wall.

### k24: the crutch was defeated by the other crutch

```
[  41.752] SWEET GDSC: hw_control set, WLAN1 0xa0223802 WLAN2 0xa0223802
[  41.912] SWEET GDSC: collapsed for the firmware at +50 ms, WLAN1 0xa0223803 WLAN2 0xa0223803
[  41.942] SWEET MHI: SYSERR in mhistatus 0xff05 at +76 ms after INIT
```

`sweethwctrl` was still defaulting on, and the two are mutually exclusive by design: with HW_CONTROL set
the GDSC ignores SW_COLLAPSE entirely. The write landed — 0xa0223803, both bits — and bit 31 stayed up,
so the domain never came down and the firmware saw exactly what it saw in every other run. The test
proved nothing except that I defeated it myself.

## 1199-apollo-hwctrl-off-by-default.patch

`sweethwctrl` now defaults off. k22 already showed setting it changes nothing on its own, and k24 showed
it blocks the one thing that does work.

### k25: the domain went down, and the firmware asserted anyway

This time the collapse took:

```
[  41.875] SWEET WMI: INIT (variant 0, 332 bytes, 2 chains, mask 0x3): ...
[  41.933] SWEET GDSC: collapsed for the firmware at +50 ms, WLAN1 0x223801 WLAN2 0x223801
[  41.964] SWEET MHI: SYSERR in mhistatus 0xff05 at +76 ms after INIT
[  42.049] SWEET GDSC: released at +150 ms, WLAN1 0xa0222000 WLAN2 0xa0222000
```

`0x223801` — bit 31 clear. PWR_ON was genuinely zero from +50 ms to +150 ms, straddling the entire poll
window, and the firmware asserted at +76 all the same.

That is a hard negative, and it points at our own assumption rather than at the chip. The firmware polls
`0xe0c300c4` for bit 31 clear; we drove bit 31 clear at `0x00c300c4`; the firmware did not see it. Either
the Q6 and the host are not looking at the same register, or the nibble swap we inferred from cnss2's
naming is wrong for WCSS_CC even though it holds for WFSS_PMM.

`0x00c300c4` is certainly *a* GDSCR — it collapses on SW_COLLAPSE and comes back on release, which
nothing else behaves like. It just may not be WLAN1's as the Q6 addresses it. Worth noting too that the
register came back as `0xa0222000` rather than `0xa0223800`: CLK_DIS_WAIT changed under us between +50
and +150 ms, so something other than our two writes is touching it.

So the k21/k23 finding stands as fact — a GDSC the host can collapse in five milliseconds — but its
identification as the one the firmware is waiting on does not. That is exactly the question a working
chip can answer, and cnss2 hands us the instrument: `/sys/kernel/debug/cnss/reg_read` and `reg_write`
perform the same windowed access from userspace. On a booted Android with Wi-Fi up we can read
`0xc300c4` on a chip that works and see what it holds.

Android cannot boot because its `/data` is the iOS root: `iosroot.img` was written to userdata (sda34) on
2026-11-05. Restoring LineageOS therefore costs the iOS install, not user data — that was already gone
nine days ago — and the ROM itself is intact in `super`, so formatting data should be enough. Giuseppe
has asked to go that way after k25.

## The stock bring-up, read line by line from a working Android

LineageOS is back on the phone (its `/data` was the iOS root, so restoring it cost the iOS install and
no user data). Wi-Fi works, connects, and `settings put global adb_root 1` gives root over adb. debugfs
is not compiled into that kernel, so cnss2's `reg_read` does not exist and the register comparison we
went there for is impossible — but the boot log turned out to be worth far more.

### What it confirms

```
Target capability: chip_id: 0x0, chip_family: 0xb, board_id: 0xff, soc_id: 0xffffffff,
                   fw_version: 0x101f046e, fw_build_timestamp: 2022-06-30 10:27
Downloading BDF: qca6390/bd_j3sgl.elf, size: 57968
Device frequency is 19200000 HZ
Read register offset 0x1f8031c, val = 0x6 / Write val 0x2
Config PCIe remap window register to 0x4000003f
```

The board file is `bd_j3sgl.elf` at exactly 57968 bytes — the file and the size we have been sending
since 1189. That inference is now fact. The counter frequency, the QFPROM handling and the window
register all match what we do.

### What it changes

**1. The stock driver downloads a regulatory database first.**

```
Sending BDF download message, state: 0xb, type: 4
Downloading BDF: qca6390/regdb.bin, size: 19348
Sending BDF download message, state: 0xb, type: 1
Downloading BDF: qca6390/bd_j3sgl.elf, size: 57968
```

Type 4 is `ATH11K_QMI_BDF_TYPE_REGDB`, and ath11k never sends it on this chip —
`.supports_regdb = false` for QCA6390 in `core.c`. We followed ath11k. The driver that works on this
board does not.

**2. Cold boot calibration is not optional here, and the firmware accepts it.**

```
Processing driver event: FW_READY(4), state: 0xb
Sending antenna switch sync request, state: 0xf
Antenna switch request failed, result: 1, err: 94        <- the stock driver fails here too and carries on
Sending mode message, mode: CALIBRATION(7), state: 0xf
Received QMI WLFW calibration done indication
Calibration completed successfully
Sending mode message, mode: OFF(4), state: 0x200f
```

k14m sent mode 7 and got `result 1 error 90`, and we wrote cold boot calibration off as unsupported.
It is supported. We sent it in the wrong place: cnss2 sends it straight after FW_READY, with **no
wlan_cfg at all**, and after the regdb download.

**3. The whole thing happens twice, and the second pass says the calibration is done.**

Pass one ends with a complete power-down — `mode OFF(4)`, QFPROM written 0x3 (SHUTDOWN_EN set), MHI
POWER_OFF then DEINIT, WLAN_EN de-asserted, all five regulators disabled. Pass two powers everything
back up and its host capability message carries:

```
Calibration done is 1
```

against `Calibration done is 0` in pass one. Only then come `ini sync request`, wlan_cfg and mission
mode.

### What we have actually been doing

Pass two only, with `cal_done` 0 — telling the firmware the radio has never been calibrated, while never
calibrating it, and without the regulatory database. Then sending WMI_INIT and asking the PHY to run a
power sequence.

That is a coherent account of a chip whose digital side is flawless and whose first radio power sequence
never completes, and it is the first explanation that does not require the hardware or our register
mapping to be strange. It also explains why nothing host-side ever moved the failure by a millisecond:
the missing piece is not in the INIT, it is everything the firmware expected to have happened before it.

### The sequence to implement

1. `regdb.bin` as BDF type 4, before the ELF board file, in both passes.
2. After FW_READY: mode CALIBRATION(7), no wlan_cfg, wait for the calibration-done indication.
3. mode OFF(4), then a full power-down: QFPROM 0x3, MHI POWER_OFF, DEINIT, WLAN_EN low, rails off.
4. Power up again, `cal_done` 1 in host capability, regdb + bdf + m3, then the mission path we already
   have.

## 1200-apollo-regdb-and-calibration.patch

The first half of the stock sequence, implemented.

**regdb.** `regdb.bin` is pulled back into the payload — 19348 bytes, byte-for-byte the size the stock
log reports — and sent as BDF type 4 before the ELF board file. The download message, the segmentation
and the TLVs are identical to the board-file path; only the type byte and the file change, so the same
loop runs twice.

**Calibration.** The mode-7 path no longer sends `wlan_ini` or `wlan_cfg` first. That is the whole of
k14m's `result 1 error 90`: cnss2 sends `mode CALIBRATION(7)` straight after FW_READY, and the ini sync
and wlan_cfg belong to the *mission* pass, which on this board is the second bring-up. We were
configuring the chip for mission and then asking it to calibrate.

`sweetmode=7` now runs the calibration pass as the stock driver does it. What it cannot yet do is the
rest: mode OFF(4), the full hardware power-down (QFPROM 0x3, MHI POWER_OFF, DEINIT, WLAN_EN low, all
five rails off) and a second bring-up with `cal_done` 1. That comes next, and only makes sense once the
calibration itself is seen to complete.

### k27: cold boot calibration completes

```
[  41.304] SWEET WLFW: board file bd_j3sgl.elf, 57968 bytes (7f454c46)
[  41.304] SWEET WLFW: regdb.bin 19348 bytes, type 4
[  41.348] SWEET WLFW: regdb sent, 4 segments
[  41.459] SWEET WLFW: board data sent, 10 segments, type 1
[  41.619] SWEET WLFW: cold boot calibration started
[  45.252] SWEET WLFW: *** cold boot calibration done after 3600 ms ***
```

No SYSERR. No assert. Three and a half seconds of the firmware calibrating the radio by itself, and a
clean `QMI_WLFW_COLD_BOOT_CAL_DONE_IND`.

To calibrate, the firmware runs the PHY through its power sequences — the same `hwdtim_sleep` path, the
same WLAN1 GDSC, the same collapse that has killed every run since the first. It did all of it and came
back. The radio works under our driver.

So the wall was never the GDSC, never the register mapping, never anything we spent twenty-seven
eliminations on. It was that the chip had never been calibrated and had never been given its regulatory
database, and we were asking an uninitialised radio to do radio things. Every host-side theory failed to
move the failure by a millisecond because none of them was about the host.

What remains is the rest of the stock sequence: `mode OFF(4)`, the full hardware power-down, and a
second bring-up with `cal_done` 1 — and then WMI_INIT on a chip that is finally in the state the
firmware expects.

## 1201-apollo-mission-after-calibration.patch

The pass the chip has been waiting for.

cnss2 closes the calibration pass with `mode OFF(4)` and then tears the chip all the way down — MHI
POWER_OFF and DEINIT, WLAN_EN low, all five rails off — before bringing it back up for mission with
`cal_done` 1. Replaying that from here means re-running the whole PCIe and MHI bring-up, so this patch
tries the cheap version first: after the calibration-done indication, `mode OFF(4)`, then the ini sync
and wlan_cfg that belong to mission, then `mode MISSION(0)`, all in the one session.

If the firmware takes the transition, the WMI path below runs for the first time on a calibrated radio
— which is the first time it will ever have been given a fair chance. If it refuses, the power cycle is
load-bearing and we go and build it properly. `sweetcalthen=0` stops after the calibration, as k27 did.

### k28: calibration again, and mode OFF ends the conversation

```
[  41.293] SWEET WLFW: regdb.bin 19348 bytes, type 4
[  41.611] SWEET WLFW: cold boot calibration started
[  45.340] SWEET WLFW: *** cold boot calibration done after 3700 ms ***
[  45.351] SWEET WLFW: response 0x22: result 0 error 0 (7 bytes)
[  45.351] SWEET WLFW: calibration pass closed, arming mission mode
[  50.726] SWEET WLFW: wlan_ini: nothing in 5000 ms
[  56.079] SWEET WLFW: wlan_cfg: nothing in 5000 ms
```

The calibration reproduces exactly — 3700 ms this time against 3600 — so it is solid, not a fluke.

`mode OFF(4)` was accepted, `result 0 error 0`, and then the firmware stopped answering QMI entirely.
Both follow-ups timed out at the full five seconds. OFF tears the WLFW service down. That is harmless
for cnss2, which is about to cut the power anyway, and fatal for us, who are trying to stay in the same
session.

## 1202-apollo-no-mode-off.patch

So do not send it. Go from the calibration-done indication straight to the ini sync, wlan_cfg and
`mode MISSION(0)`. `sweetcaloff=1` restores the OFF for anyone who wants to watch the service die.

If the firmware will not take MISSION after a calibration in the same session either, then the power
cycle really is load-bearing and the next step is to build it: MHI POWER_OFF and DEINIT, QFPROM 0x3,
WLAN_EN low, rails off, and a second run through mhi_probe, ipcr_start and wlfw_handshake with
`cal_done` 1.

### k29: ini and cfg are accepted, MISSION crashes the firmware

```
[  45.532] SWEET WLFW: *** cold boot calibration done after 3600 ms ***
[  45.532] SWEET WLFW: calibration pass closed, arming mission mode
[  45.543] SWEET WLFW: response 0x2f: result 0 error 0        <- wlan_ini
[  45.554] SWEET WLFW: response 0x23: result 0 error 0        <- wlan_cfg
[  45.739] SWEET MHI: *** SYS_ERR: the QCA6390 firmware crashed ***
[  51.015] SWEET WLFW: wlan_mode mission: nothing in 5000 ms
```

Better than k28 and still a no. Without the OFF the service stays up: the ini sync and the full
wlan_cfg both come back clean. Then `mode MISSION(0)` goes out and 185 ms later the firmware is gone.

So the firmware will not walk from CALIBRATION to MISSION inside one session, with or without the OFF
in between. The power cycle cnss2 does between the two passes is load-bearing, and that is now
established by evidence rather than assumed from the log.

### Where this leaves the port

Three things are settled that were not settled yesterday:

- The radio calibrates. 3600 ms, reproduced three times, with the firmware running every PHY power
  sequence including the one that had killed every run since the first.
- The board file, the regulatory database and the counter frequency all match the stock driver exactly.
- `hwdtim_sleep` and the WLAN1 GDSC were never the bug. They were the first thing an uncalibrated radio
  happened to trip over.

What remains for mission mode is a faithful power cycle between the passes: `mode OFF(4)`, MHI
POWER_OFF and DEINIT, QFPROM 0x3, WLAN_EN low, all five rails off, a pause, and then a second run
through the bring-up — `mhi_probe`, `ipcr_start`, `wlfw_handshake` — with `cal_done` 1 in the host
capability and the regdb and board file sent again. Every one of those steps already exists as code
that runs once; the work is making them run twice.

## 1203-apollo-second-pass-for-mission.patch

Run the chip twice, the way cnss2 does.

`g_pass` is 1 for the calibration bring-up and 2 for the mission one, and it decides two things: the
`cal_done` bit in the host capability, and the mode we ask for. Everything else about the two passes is
the same code.

When the calibration-done indication arrives, the first pass resets the state the second one rebuilds —
the QMI indication flags, the service address, the MHI ring pointers — calls `ath11k_sw_reset()` to put
MHI back to its pre-boot state, and calls `mhi_probe()` again. That re-downloads the firmware over BHI,
re-arms the channels and walks QRTR and QMI from the start, with `cal_done` 1 this time and
`mode MISSION(0)` at the end.

The rails stay up. cnss2 cuts them, but doing that here would drop the PCIe link and mean re-running
the root complex bring-up as well; resetting the firmware over MHI is what cnss2's POWER_OFF/DEINIT
then INIT/POWER_ON actually does to the chip, and it is the part that matters for the firmware's own
state machine. If the second pass still will not take MISSION, the rails are the next thing to cut.

### k30: the second pass runs, and dies on a stale window

```
[  41.441] SWEET WLFW: host_cap (cnss2 shape): cal_done 0, ddr_range 0xc0000000 + 0x40000000
[  45.535] SWEET WLFW: *** cold boot calibration done after 3600 ms ***
[  45.535] SWEET WLFW: calibration pass done, restarting the firmware for mission
[  52.016] SWEET WLFW: host_cap (cnss2 shape): cal_done 1, ddr_range 0xd4800000 + 0x9d8000
[  52.251] SWEET MHI: *** SYS_ERR: the QCA6390 firmware crashed ***
```

The architecture works. `ath11k_sw_reset()` plus a second `mhi_probe()` re-downloads the firmware over
BHI, re-arms the channels, walks QRTR and QMI from the start and gets all the way to a host capability
with **cal_done 1** — a second, independent bring-up of the chip inside one boot.

Then it crashes, and the reason is in the line above it. `ddr_range` is derived from `g_seg`, with a
fallback to the whole pool window when no segments exist yet, which is the case on a first bring-up
because host_cap goes out before respond_mem. On the second pass the segments were still there from the
first, so we declared `0xd4800000 + 0x9d8000` — the old allocation, ten megabytes — instead of
`0xc0000000 + 0x40000000`. The firmware was about to ask for memory that would not fit in the window we
had just promised it.

## 1204-apollo-reset-fw-segments.patch

Clear `g_nseg` with the rest of the state before the restart, so the second bring-up declares the same
window as the first and allocates fresh when respond_mem arrives.

### k31: mission mode

```
[  41.480] SWEET WLFW: host_cap (cnss2 shape): cal_done 0, ddr_range 0xc0000000 + 0x40000000
[  45.558] SWEET WLFW: *** cold boot calibration done after 3600 ms ***
[  45.558] SWEET WLFW: calibration pass done, restarting the firmware for mission
[  52.038] SWEET WLFW: host_cap (cnss2 shape): cal_done 1, ddr_range 0xc0000000 + 0x40000000
[  52.384] SWEET WLFW: mission mode on
```

**The firmware accepted MISSION.** Two complete bring-ups of the chip in one boot — calibrate, restart
the firmware over MHI, come back with `cal_done` 1 and the right DDR window, and walk the whole QMI
sequence again to mission mode. That is the sequence the stock driver runs, reproduced.

It does not survive what comes next:

```
[  52.384] SWEET PCIE: L1 substates 0xf enabled
[  52.390] SWEET CE: rings at 0xd1f68000: CE0 base 0xd1f68400 misc 0xc2, CE1 dst base 0xd1f69000 ...
[  52.477] SWEET MHI: *** SYS_ERR: the QCA6390 firmware crashed ***
[  52.678] SWEET MHI: crash state: ee 3 mhistatus 0xff05 bhi status 0xba58db5b err 0x9
```

Ninety-three milliseconds after mission mode, during the copy-engine setup that follows it. A different
failure in a different place from anything before — the WMI_INIT wall is behind us and this is the first
time the driver has ever reached the data-path plumbing.

The CE block is one of the allocations that survives the restart, so the obvious suspect is the same
class of bug as k30: something in the copy-engine or HTC state that pass 1 left behind and pass 2 reads.
That is the next thing to look at.

### k32: a wasted run, and what it was meant to test

k32 passed `sweetcaloff=1` to send `mode OFF(4)` at the end of the calibration pass. Nothing happened,
because 1203 had replaced the block that read it: the flag survived in the boot arguments and nowhere
else. The run is identical to k31 — mission mode at 52.400, crash at 52.494.

## 1205-apollo-close-the-calibration-pass.patch

So put it back, in the right place: `mode OFF(4)` immediately before the reset, not after it.

In k28 the OFF was fatal because the WLFW service dies with it and we were trying to continue in the
same session. Now the firmware is reset a few lines later, so losing the service costs nothing — and
OFF is plausibly how the firmware is told to finalise the calibration rather than leaving it
half-closed. cnss2 sends it; we have never managed to.

### k33: the OFF goes out cleanly and changes nothing

```
[  45.492] SWEET WLFW: *** cold boot calibration done after 3600 ms ***
[  45.503] SWEET WLFW: response 0x22: result 0 error 0        <- mode OFF, accepted
[  51.986] SWEET WLFW: host_cap (cnss2 shape): cal_done 1, ddr_range 0xc0000000 + 0x40000000
[  52.332] SWEET WLFW: mission mode on
[  52.425] SWEET MHI: *** SYS_ERR: the QCA6390 firmware crashed ***
```

The calibration pass is now closed exactly as cnss2 closes it, and the second pass still dies 93 ms
after mission mode, in the same place as k31 and k32. Three runs, same millisecond. Whatever the second
instance is missing, it is not the OFF.

### What is left of the difference

cnss2's cycle between the two passes is: mode OFF, MHI POWER_OFF, MHI DEINIT, QFPROM 0x3, WLAN_EN low,
all five regulators disabled, a pause, and then the whole thing up again. We now do the first and the
last of those. What we still do not do is **cut the power**: `ath11k_sw_reset()` resets PCIe, MHI and
the Q6, and the second firmware instance comes up far enough to reach mission mode, but WCSS keeps
whatever the calibration left in it, because nothing has taken its rails away.

That is the remaining candidate, and it is also the expensive one: dropping the rails drops the PCIe
link, so the second pass would have to re-run stages 1 to 6 of `pcie_main` — rails, GDSC and clocks,
PARF, PHY, LTSSM, iATU — before `mhi_probe` could run again. About 220 lines that currently only ever
execute once, to be factored into something callable twice.

Worth noting what that would buy and what it would not: it is the last structural difference from the
stock sequence we know of, but the crash is 93 ms into the copy-engine and HTC bring-up, which is code
that has never run successfully on this chip in any configuration. It may equally be a plain bug in a
path we have only now reached.

## 1206 — la memoria della calibrazione va restituita, non ricreata

The 93 ms crash was ours, and it was in the reset. The firmware does not keep its calibration inside the
chip: it writes it into the DDR blocks the host hands it at `respond_mem`, and `cal_done = 1` on the second
pass is the host telling it "the result is in there, go and read it". Patch 1204 cleared `g_nseg` so that the
second `host_cap` would declare the same `ddr_range` as the first — which it had to — but clearing it also
sent the second `respond_mem` down the allocation path: fresh pool blocks, at new addresses, zeroed, handed
over with `cal_done = 1`. So the second firmware instance was told it was calibrated and then given zeroes
where the calibration should have been. It got as far as mission mode on that lie and died 93 ms later, in
the copy-engine and radio bring-up — the first code that actually reads the thing.

Linux never had this problem because ath11k's `target_mem` chunks outlive the reset: the same addresses go
back in the second `respond_mem`, contents untouched.

So: copy the blocks aside before clearing `g_nseg` (`g_saved`, `g_nsaved`), and in `respond_mem` walk them
with a cursor and hand each one straight back when the type and size match what is being asked for — same
address, not zeroed, not re-allocated. `host_cap` still declares the first pass's window, because `g_nseg`
is still cleared, so k31's 235 ms failure mode does not come back. It also stops the second pass leaking a
second copy of every block out of the GPU pool.

Also `g_er0_rp`, which 1203 reset to 0 while every other ring pointer went to its ring base. Harmless as it
turns out — `mhi_bringup` sets it to `ER0_RING` on the way through — but wrong, and it was the first thing
that looked like the bug.

## 1207 — which of the two differences kills the second pass

k34 handed the second instance its own calibration memory back, same addresses, untouched — the log shows
both blocks kept and the caldb full of firmware data where k31's was zeroes. It died anyway, 88 ms into
mission mode, without sending HTC READY at all. Necessary, then, but not the cause.

Lined up against k25, a single cold pass, the shape of the failure is sharp: there, `SWEET HTC: READY` came
back in the same millisecond as the copy-engine rings. Here nothing comes back and the firmware asserts.
Two things still differ between those runs: the chip is warm (`ath11k_sw_reset`, rails never cut) and we
claim `cal_done`. `sweetcal2` flips the second one on its own — with 0 the second instance runs its own
cold boot calibration at INIT and never reads the caldb — so one boot says which of the two it is, and
whether the 220-line power-cycle refactor is worth building.

(Also noted while reading k34: `015dae40 050000c8 008a4fb4 008a5050` at the start of segment 0, which we
have been reading as a crash record since k31, is in every log from 41 s onwards, healthy runs included.
It is a firmware header, not a dump. The real crash record is in RDDM, which `sweetrddm=1` collects.)

## 1208 — il secondo passaggio riparte dalle alimentazioni

k36 answered the question 1207 asked. With `sweetcal2=0` the second instance does not claim the
calibration, never reads the caldb, and dies at exactly the same place: 88 ms into mission mode, no HTC
READY, same as k34 and k35 with cal_done 1. So it is neither the calibration nor the memory we hand it.
What is left is the chip: `ath11k_sw_reset` resets PCIe, MHI and the Q6, and WCSS keeps whatever the
calibration left in it, because nothing takes its rails away. k25 — a single cold pass — had HTC READY
back in the same millisecond as the copy-engine rings.

So the body of `pcie_main` becomes `pcie_bringup(step)`, callable twice, and the calibration pass stops
restarting the firmware from inside the QMI handler: it sets `g_restart` and returns. `pcie_main` unwinds,
runs `wlan_power_down` — QFPROM SHUTDOWN_EN and VDD4BLOW back on, MHICTRL RESET while the link can still
carry it, PERST# and both enables low, 300 ms — and calls `pcie_bringup` again. Stage 1 of that is already
a power cycle, so the second pass gets rails, GDSC, clocks, PARF, PHY, LTSSM, iATU and BHI from scratch,
the way cnss2 does it. The host DDR with the calibration in it is ours and survives, which is the whole
point of keeping it across the cycle.

`sweetsoftpass=1` keeps the old behaviour for comparison. The RDDM collector, incidentally, hangs: k35
prepared all 9 pieces of the dump area and the thread never printed again, so the crash dump is still not
readable and the reasoning above is from the logs alone.

## 1209 — un secondo firmware dopo un primo che non ha fatto niente

k37 built the power cycle and the second instance still died 87 ms into mission mode. k38 then ran a
single pass with everything the two-pass build sends, regdb included, and it went all the way: HTC READY,
service 0x100 and 0x300, WMI service ready with 2 RF chains, WMI INIT, and then the old WMI_INIT death of
an uncalibrated radio 440 ms later. So the mission path is sound and regdb is innocent — the only broken
thing is being the *second* instance, and the chip being warm was not it either.

`sweetdryrun=1` stops the first instance at `firmware init done` — no ini, no cfg, no mode, no calibration
at all — and asks for the cycle anyway. `sweetkeepmem=0` makes the second one allocate fresh segments
instead of getting the first one's back. Together they make the second instance as close to k38's single
pass as this code can get: if it still crashes, the fault is in our own re-initialisation and nowhere near
the firmware; if it does not, it is something the calibration leaves behind.

## 1210 — i copy engine prima del mode, come fa il driver stock

Reading the Android log again, line by line, the stock mission pass is:

```
cnss: Sending ini sync request
wlan: hif_pci_enable_bus: con_mode = 0x0        <- the copy engines, here
cnss: Mode: 0, config: ..., host_version: 5.2.022.12B   <- wlan_cfg
cnss: Sending mode message, mode: MISSION(0)
wlan: htc_wait_target: Target Ready!            <- 33 ms later
```

The copy engines are up before the ini sync, before the cfg and before the mode message. Ours go up
*after* the mode message, and the firmware's HTC READY comes back 7 ms later — so in k38 we were
programming the rings at about the moment the firmware started writing into them, and won the race.
`sweetceearly=1` puts the setup where the stock driver has it.

Also in that log: on the way down cnss reads 0x1f8031c as 0x2 and writes 0x3, not the 0x7 we were
writing (SHUTDOWN_EN yes, VDD4BLOW no), so 1208's power-down now writes what cnss writes. And the stock
host capability declares `iova starting 0xa0000000 with size 0x10010000`, which is the SMMU range the
chip is actually given — we declare 0xc0000000 + 0x40000000 and hand it physical addresses at 0xd0000000,
outside what we declared. That has been true of every run including the ones that work, so it is not the
crash, but it is on the list.

## 1211 — togliere davvero le alimentazioni

Reading the Android log through the gap between the two passes, cnss2 does five things we were not doing:

```
cnss: Read register offset 0x1f8031c, val = 0x2 / Write val 0x3
cnss: Setting MHI state: POWER_OFF(4)
cnss: Suspending PCI link / msm_pcie_disable: Assert the reset of endpoint
cnss: Setting MHI state: DEINIT(1) / De-assert WLAN_EN GPIO successfully
cnss: Regulator vdd-wlan-rfa2 / rfa1 / dig / aon / io is being disabled
```

1208 did the first four. The fifth is the one that matters most and it is the one WLAN_EN cannot stand in
for: WLAON is by definition the domain that survives the chip's own collapse — it is where the QFPROM
power-control bits live, the ones we have spent weeks on — so while vdd-wlan-aon is up, part of the chip
still remembers the calibration pass. `unvote()` clears our enable bit on the four chip rails; the vote is
ours alone, so a shared supply stays up for whoever else is asking. `sweetrailsoff=0` keeps them on.

Also from that log: the copy-engine rings in the stock driver go up *after* the mode message
(`ce_srng_dest_ring_setup` at 14.569, mode at 14.547), so 1210's `sweetceearly` is not the stock order
after all — only `hif_pci_enable_bus` comes earlier, and that is the bus, not the rings. Ours was right.

## 1212 — leggere la capability per intero, e tutto il segmento dopo il crash

k39 and k42 are the pair that matters. Both power-cycle the chip between the passes, both drop the rails,
both hand the second instance fresh zeroed memory and `cal_done = 0`. The only difference is what the
*first* instance did: in k39 it stopped at `firmware init done` and did nothing; in k42 it ran the cold
boot calibration. k39's second instance reaches HTC READY, WMI service ready and WMI INIT. k42's dies 94
ms into mission mode.

And the second instance can tell the difference: its capability response is 164 bytes after the dry first
pass and 157 after the calibrating one. Seven bytes — one TLV — in a message that arrives before anything
else we send could matter. The WLAON power-control register reads its power-on default 0x6 in both second
passes, so the chip really did lose its rails; something is crossing that gap anyway, and the capability
response is where it shows. So: dump it whole, in hex, and diff the two.

The crash scan also only ever looked at the first 256 KiB of the 6 MB segment, which has returned
"no text" on every mission crash. Now it reads the whole segment (`sweetwidescan=0` to go back) and prints
up to 24 runs.

## 1213 — leggere il chip prima di ogni download, nei due passaggi

k43 got the firmware to say what it is dying of. The wide scan found, at +0x2ffe80 of the first segment:

```
Asserted in0x171fe48s:367
```

which is the format string at 0x1391db of amss20.bin, `Asserted in0x%xs:%d`, with the address 0x171fe48
and the line 367. Disassembling there:

```
0171fad4  { call 0xffddb288 allocframe(#184) }            <- function entry
0171fadc  { r19:18 = combine(r1,r4) r17:16 = combine(r2,r3) r21 = r0 }
0171faec  { p0 = cmp.gt(r19,#11); if (p0.new) jump ... r0 = #367 }
0171faf4  { r2 = add(r21,mpyi(r19,##584)) }
```

an index into a twelve-entry table of 584-byte structures, asserted when the index is past the end — and
0x171fe48 sits in the same region as the lines 487 and 495 we have been staring at since the GDSC days,
which is the PMM power sequencing.

The capability response says the same thing from the other side: the first instance reports TLV 0x18,
otp_version = 0x0048001d; the second instance, after a calibration pass, does not report it at all. A
firmware that cannot read the chip's fuses is exactly a firmware that would then index a power-sequence
table with something it should not have.

So before each BHI download, in both passes, read the same fourteen WLAON, WFSS_PMM, WCSS_CC and
WCSS_STATUS_FOR_DEBUG registers and print them with the pass number. If the chip really comes up identical
both times, these fourteen lines will match and the difference is somewhere we have not looked; if they do
not, the difference is right there.

## 1214 — l'unico registro che non combacia

k44 read fourteen chip registers before each BHI download, in both passes. Thirteen match to the bit:

```
chip (pass 1) 0x1f8031c = 0x00000006   0x1f8002c = 0x0000000f
chip (pass 1) 0x0c300c4 = 0x00222001   0x0c30138 = 0x00222001
chip (pass 1) 0x1e03140 = 0x03402001   0x1e0313c = 0x03707000
chip (pass 2) ... identical ...        0x1e0313c = 0x05707000
```

WCSS_STATUS_FOR_DEBUG high: `0x03707000` on the first pass, `0x05707000` on the second. Bits 25 and 26,
one state swapped for another, with everything else — WLAON, the QFPROM power control, both GDSCRs, the
PMM control — reading the same reset values. That rules out a chip that merely kept its state: the chip
did reset, and one state field came up elsewhere.

Two readings of that: either the field settles over time and the second pass simply reads it younger
(300 ms after the rails came back, against seconds on the first pass), or the chip really is in another
state. So sample it six times at 25 ms and watch, and make the power-down wait a boot argument
(`sweetdowntime`, default 300) to try the long version.

## 1215 — l'alimentazione dei fusibili, e i blocchi interi

Two things, from reading amss20.bin while the phone was away.

The firmware's own component list is in its RTTI names, and among the twenty-four calibration state
machines — `HcaHwComponentTrxHastings_calSmLna`, `_calSmRxIq`, `_calSmTxLo`, `_calSmDpdMemory` and the
rest — sits `HcaHwComponentTrxHastings_efuse`. The second instance is the one that reports no
otp_version, and it is the one that asserts on an index into a twelve-entry table. A fuse read that
quietly fails is one way to end up with an index nobody meant, and bit 2 of WLAON_QFPROM_PWR_CTRL — the
one named VDD4BLOW, the supply the fuse array needs — is a bit *we clear* on the way up, in both passes,
because cnss2 clears it. `sweetblow=1` leaves it standing and clears only SHUTDOWN_EN.

And since k44 compared fourteen registers by hand and found exactly one that differs, `sweetregblocks`
(default on) now prints four blocks whole before each BHI download — WLAON 0x1f80000, WFSS_PMM 0x00b60000,
WCSS_CC 0x00c30000 and the debug status at 0x01e03100, around six hundred words — with the pass number in
front of each line, so the two passes can be diffed outright instead of guessed at.

## 1216 — bisezionare il primo passaggio

k46 closed the hardware question. Six hundred registers read before each BHI download — WLAON 0x1f80000,
WFSS_PMM 0x00b60000, WCSS_CC 0x00c30000, the debug block at 0x01e03100 — and the two passes differ in
exactly two words:

```
0x1e0313c  0x0e207000  ->  0x10287000
0x1f80108  0x0020b0b9  ->  0x0020af49
```

Both are free-running counters: k44 saw the same register at 0x03707000/0x05707000, different values on a
different run. Everything else is identical to the bit. The chip the second firmware wakes up on is the
same chip the first one woke up on. And leaving VDD4BLOW standing (`sweetblow=1`, k46) changed nothing
either — same assert, same line 367.

So the carrier is not the chip, and the list of things it could be has been cut by k41 (rails), k42 and
k43 (fresh memory, cal_done 0) and k46 (fuse supply). What is left is to stop guessing and bisect the
first pass itself: k39's first instance did nothing and the second was healthy, k43's calibrated and the
second was not. `sweetcalwait` is how long the first pass is allowed to calibrate before we turn round —
0 sends the mode request and restarts immediately, 30000 is the whole thing. Somewhere between those two
the second instance stops working, and wherever that is, it names the mechanism.

## 1217 — anche i clock, e il contatore che non si azzera

The bisection of the first pass finished early and in the most useful way. k47 sent the calibration mode
request and turned round immediately — `cut the calibration short at 0 ms` — and the second instance
still died at line 367. k48 did the same without even the closing `mode OFF`, and died the same way. So
the calibration does not have to run, and does not have to be closed: *asking for it once* is enough.

Which should be impossible if the chip is power-cycled in between, so look again at whether it is. Two
registers change across the power-down, and neither is the free-running counter I took them for:

```
k44   0x1e0313c   0x03707000 -> 0x05707000
k46   0x1e0313c   0x0e207000 -> 0x10287000
```

Different values on the two runs, and exactly +0x02000000 between the passes on both. That is a counter
that survives the power-down and ticks twice for a bring-up. The chip is not losing its power, and the
reason is in plain sight: we withdraw the four rail votes and never touch the clocks. rfclka1-3,
rfclkd3-4 and lnbclka1-3 are RPMh resources exactly like the rails, and we had been leaving all eight
voted across the cycle. So withdraw them too (`sweetclksoff`), and hold the chip down for a second rather
than 300 ms. The counter at 0x1e0313c is the instrument: if it comes back changed by something other than
+2, the chip finally went away.

## 1218 — un marcatore in WLAON

The bisection is finished and the result is sharper than expected. k50 ran a first instance that stops at
`firmware init done` with every default left alone — memory reused, cal_done 1 — and its second instance
is healthy: HTC READY, both services, WMI service ready with 2 RF chains, WMI INIT, and then the ordinary
death of an uncalibrated radio (`Asserted in0x1503340s:502`, a different address and a different line
from the one we have been chasing). k48 and k49 send `wlan_mode(CALIBRATION)` in the first pass and
nothing else — no calibration time, no closing OFF — and their second instance dies at line 367.

So one QMI message in the first pass decides it. And the diff of the two second passes says where it
first shows: the capability response. The healthy one carries

```
cap +090: 04 00 b4 03 00 00 17 04 00 00 f8 24 01 18 04 00 1d 00 48 00
```

— TLV 0x18, otp_version 0x48001d, 164 bytes. The poisoned one is 157 bytes and has no 0x18 at all. The
second firmware cannot read the chip's fuses, and that is already true long before mission mode.

Which leaves one assumption worth re-testing rather than trusting: that the chip loses power between the
passes. k49 withdrew the clock votes too and the WCSS debug counter did restart — but a counter stopping
is also what happens when you take its clock away, so it proves less than it looks. `sweetmark` writes
0x5a5a5a5a into WLAON's GDSC delay register before the rails come down. WLAON is the domain that survives
the chip's own collapse by design: if it still holds the marker on the second pass, vdd-wlan-aon never
went away, somebody else is voting for it, and the fuse array is simply never being re-sensed.

## 1219 — il marcatore, stavolta mentre il chip è ancora vivo

k51 wrote the WLAON marker after the rails, the clocks and the GPIOs had already gone down, so the write
went into a dead bus and read back 0xffffffff; the second pass then found the register at its ordinary
0x25112222 and the test said nothing. Moved to the top of `wlan_power_down`, before MHICTRL RESET and
before PERST#, where the chip is still answering.

k51 did confirm the symptom once more, in the two capability dumps of the same boot:

```
pass 1   cap +090: 04 00 b4 03 00 00 17 04 00 00 f8 24 01 18 04 00 1d 00 48 00
pass 2   cap +090: 04 00 b4 03 00 00 17 04 00 00 f8 24 01
```

Same chip, same boot, twenty seconds apart: the first firmware reports otp_version 0x48001d, the second
stops at time_freq_hz and has no 0x18 at all.

## 1220 — l'immagine del firmware era quella di prima

k52 settled the last open question the right way round: the marker went into WLAON while the chip was
still answering (`0x1f80024 reads 0x5a5a5a5a`) and the second pass found it gone (`0x25112222`). WLAON
loses its supply, the chip really does power-cycle, and together with k46's 576 identical registers that
closes the hardware off completely. Which left one thing never checked — what we actually download the
second time:

```c
mhi_mem_prepare(void)
{
	if (g_mva) {
		return 0;
	}
```

The MHI control block and our only copy of the firmware image are allocated and filled once per boot.
The second bring-up calls this, gets 0 back, and BHI-downloads whatever is in that block now. And the
block comes out of the pool at 0xd0000000-odd — inside the DDR window host_cap declares to the firmware,
0xc0000000 plus a gigabyte, which is everything we own. A firmware told to calibrate allocates and writes
in that window; a firmware that stops at `firmware init done` does not.

So the second instance was never a second instance of our firmware. It was a second instance of whatever
the first one left of it — which is why it reports no otp_version (the fuse code is not the code we
shipped), why it then indexes a twelve-entry power-sequence table with a number nobody meant, and why
`wlan_mode(CALIBRATION)` alone, cut to zero milliseconds and without even its closing OFF, was enough to
cause it.

Now the block is re-allocated and re-filled once per pass (`filled` remembers which pass owns it, since
mhi_mem_prepare is called twice per bring-up). `sweetkeepmhi=1` restores the old behaviour. The declared
ddr_range is still wrong and still overlaps everything we own — the stock driver declares an SMMU window,
`iova starting 0xa0000000 with size 0x10010000` — and that is the next thing to fix, but this is the one
that has been killing the mission pass.

## 1221 — i contesti degli anelli dopo l'HELLO

1220 works, and the failure moved. k53 ran the full calibration, re-allocated the control block for the
second pass (`pool block 4864 KiB at 0xd0e68000`, a new address, `readback 0 bad pages`), downloaded the
firmware again — and the second instance **does not crash**. No SYS_ERR, no assert, no line 367. It
reaches AMSS mission mode, both IPCR channels start with completion code 1, and we send our QRTR HELLO.

Then nothing. On the first pass the firmware answers 20 ms later with the control packets and
`service at 7:0x1`; on the second it never answers, and er1 fills with empty slots. Everything the device
was told about those rings lives in the block that just moved, so print it — ER0 and ER1 contexts, both
channel contexts, the first ch21 TRE, our own read pointer and the channel doorbell — in both passes,
and diff them.

## 1222 — i puntatori degli anelli vanno azzerati dove gli anelli nascono

k54 printed the ring contexts after HELLO in both passes, and the two lines say it outright:

```
pass 1   block at 0xcf8cc000, first ch21 TRE 0xcf8dc000 len 0x2000, our rp 0x3000
pass 2   block at 0xd0e48000, first ch21 TRE 0          len 0,      our rp 0x3380
```

The second pass queued its sixteen receive buffers 44 TREs into a freshly zeroed ring and left TRE 0
empty, so the firmware had nowhere to put its answer to our HELLO. Channels started, HELLO went out,
silence — exactly what k53 looked like.

The cause is where 1203 put the resets: in the restart block, which runs in the calibration pass, before
the power cycle and before the whole second bring-up. Everything between there and `ipcr_start` polls —
er0_poll and er1_poll run in every wait loop — and walks those pointers on again over a device that is
being reset underneath. So g_er0_rp, g_er1_rp and g_cmd_wp now go back to their bases where the ring
contexts are programmed, and g_ch20_wp/g_ch21_wp at the top of ipcr_start, next to the chan_ctx calls
that create those rings. The copies in the restart blocks are harmless and stay as they are.

## k55 — il doppio passaggio funziona

With 1220 and 1222 in, the whole sequence runs end to end for the first time:

```
48.4  service at 7:0x1                        (first instance)
52.5  *** cold boot calibration done after 3600 ms ***
      power cycle: rails, clocks, WLAN_EN, 1 s
70.3  block at 0xd45d4000, first ch21 TRE 0xd45e4000, our rp 0x3000   (re-allocated, re-filled)
70.4  service at 7:0x1                        (second instance)
70.7  mission mode on
70.7  HTC READY: 2 credits of 2176 bytes, 5 endpoints
70.7  service 0x100 endpoint 1, service 0x300 endpoint 2
70.7  WMI service ready: 2 RF chains
71.0  WMI INIT (332 bytes, 2 chains, mask 0x3)
71.5  SYS_ERR, Asserted in0x1503340s:502
```

A calibrated radio, a clean second firmware, and the mission path reached in full. The death that
remains is 440 ms after WMI INIT — and it is the *same* assert, at the same address and the same line,
that k50 got with a first pass that never calibrated at all. So the WMI_INIT failure we have been
calling "the uncalibrated radio" for six weeks is nothing of the kind: it survives a real calibration
untouched, which means it is in what we send at INIT, or in what we leave out before it. That is the
next thing, and it is a different problem from everything above.

## 1223 — guardare il GDSC del WCSS nelle due fasi

k55 changed what the WMI_INIT death means. The assert is the same one as ever — `cmnos_thread.c`,
`Asserted in0x1503340s:502`, the single site in the image that loads 502, the poll of 0xe0c30004 with
mask 0x80000000 inside `_whal_pmm_wlan_pwr_seq_hwdtim_sleep___RAM` — but it now arrives on a radio that
has just been calibrated for 3600 ms and power-cycled, reached through a clean second firmware. k50 got
the identical assert with a first pass that never calibrated. So the calibration was never what this was
waiting for.

What k55 does give us is a phase that works. The same firmware, told to calibrate, powers the radio and
runs its sequences for 3600 ms without complaint; told to run mission, it dies 440 ms after INIT polling
a GDSC. And k46's block dump says that before any firmware runs, the first four words of WCSS_CC —
0x00c30000 to 0x00c3000c, which is where 0xe0c30004 lands under the nibble rule — all read zero, while
the GDSCRs at +0xc4 (0x00222001), +0xc8 and +0xcc (both 0x80000000) read sanely.

So sample those seven registers through both phases: at the start of the calibration, every 500 ms
while it runs, when it finishes, and every 40 ms through the window after INIT. If they come alive
during the calibration and stay dead at INIT, whatever the firmware does to them in calibration mode is
the thing mission mode is missing. If they are dead in both, then 0x00c30004 is not where the firmware
is looking and the nibble rule does not hold for this block — which is a different hunt, but a shorter
one than the four weeks we have spent assuming it does.

## 1224 — i registri che il firmware si nomina da solo

k56 sampled the wrong registers, and in doing so paid for itself: during the calibration the WLAN1 GDSCR
reads 0xa0223800 — powered on — and 80 ms after WMI INIT it goes to 0x00222001, PWR_ON clear and
SW_COLLAPSE set, while its two neighbours go the other way. The collapse the firmware asks for happens.
It then waits another 360 ms and asserts anyway.

So read the firmware's own code instead of guessing. `_whal_pmm_wlan_pwr_seq_hwdtim_sleep___RAM` begins
at 0x156be40, and the relevant packets are:

```
0156bf20  r2 = ##0xE0C300C4   memw(0xE0B60108) = clrbit(#31)
0156bf34  r1 = ##0x80000000   r4 = #495
0156bf40  r5 = ##0x15A4A32 ("WCSS_CC_WCSS_WLAN1_GDSCR/PWR_ON")  memw(r2) = #15
0156bf50  r2 = memw(r16=##0xE0B60148) ... setbit 0, setbit 1
0156bf74  r3:2 = combine(##0x15A4A08 ("_whal_pmm_wlan_pwr_seq_hwdtim_sleep___RAM"), #0)
0156bf80  r6 = memw(r17=##0xE0B60178) & 0xEFFFFFFB, setbit #2
0156bf88  call <poll>        r0 = ##0xE0C30104, r1 = 0x80000000
0156bf94  p0 = cmp.eq(r0,#-1) ...
0156bfb0  call <assert>      r0 = #502
```

So it writes 0xf to the WLAN1 GDSCR, pokes two WFSS_PMM registers, and polls **0xE0C30104** with mask
0x80000000 — not 0xE0C300C4, which is what we have been watching for weeks, and not 0xe0c30004 either.
The poll helper itself tail-calls into ROM at 0x880f24, so the polarity is not readable statically.

Under the nibble rule that is host 0x00c30104, and every block dump we have says it reads 0 — already
what a "wait for PWR_ON to clear" would want. Its neighbour 0x00c30108 is the one standing at
0x80000220, bit 31 and all. So sample the registers the firmware actually names, every 40 ms through the
INIT window, and offer `sweetpoke108=<ms>` to set SW_COLLAPSE on 0x00c30108 while it waits: if the
firmware then walks past the poll, the mapping is off by one register and we have the answer.

## k57-k59 — cosa fa davvero la sequenza di sleep

With the registers the firmware names, sampled through both phases, the timeline after WMI INIT is no
longer inference:

```
            0xc30104   0xc30108    WLAN1 c4    WLAN2 138   pmm 178
cal + INIT+40   0      0x00000f11  0xa0223800  0xa0223800  0x40000001
INIT +80 ms     0      0x80000220  0x00222001  0x00222001  0x7c000000
... unchanged until the assert at +440 ms
```

Both WLAN GDSCs are powered through the whole calibration and collapse 80 ms after INIT, exactly as a
sleep sequence wants. The register that moves the other way is 0x00c30108: bit 31 comes **up** at the
same moment and never goes down again. 0x00c30104 — the address the poll names, under the nibble rule —
reads zero from here throughout.

k58 set SW_COLLAPSE on 0x00c30108 from the host while the firmware waited: it took the write
(0x80000220 -> 0x80000221) and PWR_ON stayed up regardless. That domain will not collapse even when
asked directly.

k59 gave the firmware a silent 1500 ms after INIT — no MMIO at all, only MHISTATUS — in case our 10 ms
polling was keeping the chip out of the state its sleep sequence needs. Same assert, same place. (The
WLAON debug word does run freely through that window, so the chip is alive and clocked while it waits.)

What is left to settle is the poll's polarity, and that is in ROM: the helper at 0x156c17c passes
(addr, mask, expected, 100 µs, 1000 tries, name) to a thunk at 0x14fc904 that tail-jumps to 0x880f24,
outside the image. The way to read it without the ROM is to find another caller of the same helper whose
register we can watch succeed — there are many in the power sequences — and infer the convention from a
case that works. That is the next piece of work.

## 1225 — la convenzione del poll, e il buco nei campioni

Two call sites, the same register, and between them the helper's convention in full:

```
0156c420 (power-up, line 24)   r0 = 0xE0C300C4  r1 = 0x80000000  r2 = 0x80000000
0156bf88 (sleep,  line 495)    r0 = 0xE0C300C4  r1 = 0x80000000  r2 = 0
```

So it waits for `(value & mask) == expected`: the power-up poll for PWR_ON set, the sleep poll for
PWR_ON clear. No ROM needed after all.

Which makes the sleep poll's timeout a contradiction, because our samples show PWR_ON clearing at
INIT +80 ms and staying clear — exactly what it is waiting for. Except that those samples stop at
+360 ms and the assert lands at +440. Nobody has ever looked at the eighty milliseconds where it
actually happens. `sweetgwatch=<ms>` samples the WLAN1 GDSCR, its neighbour at 0x00c30108, the WLAN2
GDSCR and WFSS_PMM 0x00b60178 every 10 ms, printing only on change, for as long as asked.

k60, for the record, held the MHI device wake asserted across INIT (`sweetwake=1`, the opposite of what
1179 settled on) and changed nothing: same +80 ms collapse, same assert.

## 1226 — il record di crash per intero

k61 watched the GDSCR every 10 ms for 900 ms after INIT, printing on change, and the result is as flat
as it could be:

```
+0 ms   WLAN1 0xa0223800  0x108 0x00000f11  WLAN2 0xa0223800  pmm178 0x40000001
+60 ms  WLAN1 0x00222001  0x108 0x80000220  WLAN2 0x00222001  pmm178 0x7c000000
        window over, firmware alive
```

Two changes in nine hundred milliseconds. Both GDSCs collapse at +60 ms and stay collapsed — PWR_ON
clear, which is exactly `(value & 0x80000000) == 0`, exactly what the sleep poll is documented by its
own sibling call site to be waiting for — and the firmware sits there for another 400 ms and asserts.
(It also shows the crash is not on a 440 ms timer: with the longer window it came at +1430 ms.)

The host's writes clearly land where we think: 0x00c300c4 shows SW_COLLAPSE set at +60 ms, which is the
firmware's own `memw(0xE0C300C4) = #15`. Its reads apparently do not come back from the same place.

Both addresses in the crash record are stripped file and function pointers, so the line number is all
the identification there is. Before spending more boots on inference: dump the 384 bytes around the
record as hex and ASCII. The assert structure carries more than the text we have been printing, and
whatever it was polling may be sitting in the words next to it.

## k62-k63 — il record intero, e l'ASPM

k62 dumped the crash record as hex instead of one text run, and the structure is:

```
+2ffe80  "Asserted in0x1503340s:502"
+2ffe9c  01499608  008a8594  01503340  01530258
+2ffeac  0152fb14  000001f6 (=502)  0000001c  0000001c
```

0x1503340 and 0x1530258 are the stripped file and function pointers (0x1503340 lands in an assert
dispatch table whose slots are lines 242, 265, 434, 401, 462, 538, 553 — not 502, so it is a pointer and
not the site). The new one is **0x0152fb14**, which disassembles inside a callback dispatcher — a loop of
`callr` over a list — so the assert comes from a function invoked through a table, which is how the power
sequences are run.

k63 turned the ASPM L1 substates off, on the theory that a link dropping into L1.2 could be why the Q6's
reads of WCSS_CC come back stale while ours do not. It did not get far enough to tell: the first pass
calibrates (3800 ms), the second bring-up starts, and the thread stops at `BHI next` — iOS carries on
logging, so it is our wifi thread hanging in the second BHI download, not a crash. So the L1 substate
configuration matters to the second bring-up as well; `sweetaspm=0` is not usable as it stands.

Where that leaves the blocker: the poll's convention is known, the register's value is known and correct
for 900 ms, the firmware's own writes land where we read, and its reads do not agree. Patching the
firmware to skip the assert is not available — amss20.bin is signed and the PBL verifies it. The next
angles are (a) what the stock host does differently to the WCSS access path around INIT, from the Android
log, and (b) sampling the registers of a poll that *succeeds* in the same sequence, to see whether the
Q6's view of WCSS_CC is ever in agreement with ours.

## 1227 — il percorso dati, e perché k64 non è tornato

Reading the Android log for every register the stock driver touches turns up exactly three lines, all of
them the QFPROM power control we already write. So nothing is missing from our register writes, and the
difference at INIT has to be in what the host has *built* by then.

And there it was, switched off: `sweetdp` defaults to 0. The HAL data path — REO, TCL, WBM, the idle link
list — is written and has never been part of a run since the two-pass bring-up started working. ath11k
builds all of it before it sends WMI_INIT, and the comment above our own implementation says why: at INIT
the firmware brings up its data path and expects those rings to exist. It was tried once, months ago, on
an uncalibrated single pass where the crash came 80 ms after INIT; today's crash comes at 440 ms on a
calibrated radio, so it is a different experiment.

k64 ran it and never came back: the log stops at `settling 200 ms before INIT`, with none of wifi_dp's
own prints and not even its "no memory" line. By the second bring-up the pool has served two passes of
firmware segments, two MHI control blocks and two copies of m3, and this asks for another 4 MiB of link
descriptors mapped in one piece.

So: print the pool's free space and each step as it happens — allocation, mapping, zeroing — and make
the descriptor count a boot argument. ath11k asks for 32768; a first association needs far fewer, and
`sweetdplinks=2048` is 256 KiB instead of four megabytes.

## 1228 — il testimone per la mappa degli indirizzi

Tutto quello che abbiamo detto sull'assert alla riga 502 poggia su un'ipotesi mai verificata: che
l'`0xE0C300C4` del firmware e il nostro `0x00C300C4` passato dalla finestra siano lo stesso registro.
È vero per le *nostre* due scritture — la finestra prende i bit 24:19 dell'indirizzo e tutt'e due danno
finestra 0x18, offset 0x300c4 — ma non dice niente su cosa veda il Q6, che esce su un bus suo con una
mappa sua. Il ragionamento «le sue scritture arrivano dove leggiamo noi, le sue letture evidentemente
no» è circolare se quella mappa è diversa.

Rilettura del disassemblato, e due correzioni alla prima lettura:

- la funzione non comincia a 0x156be40, che è in mezzo: l'ingresso è a **0x156bdc4**
  (`allocframe(#40)`), e la sequenza di collasso si esegue solo quando il byte 1 della struttura
  restituita da 0x156c150 vale 0;
- lo 0xf non va al GDSCR ma a **0xE0B700C4**, in WFSS_PMM. L'indirizzo del poll, 0xE0C300C4, è confermato
  (`r0 = ##-524091196`), e l'unico caricamento della costante 502 in tutta l'immagine è a 0x156bfb4,
  quattro pacchetti dopo quel poll: su *quale* poll fallisca non c'è dubbio.

I dodici pacchetti prima dell'assert:

	0156bf20  memw(0xE0B5FF88) = clrbit(#31)
	0156bf40  r3 = memw(0xE0B700C4);  memw(0xE0B700C4) = #15
	0156bf50  0xE0B60088 = (v & 30) | 1,  poi (v & 29) | 2
	0156bf74  0xE0B600F8 = (v & ~0x10000004) | 4
	0156bf88  call dell'helper di poll (r0 = 0xE0C300C4, r1 = 0x80000000, r2 = 0)
	0156bfb0  r0 = #502 -> assert

L'helper a 0x156c17c aggiunge 100 µs e 1000 tentativi e salta alla ROM a 0x880F24, che nell'immagine non
c'è: più in là di così, staticamente, non si va.

Ma quella scrittura di 15 è un testimone. È l'unica cosa della sequenza che da fuori si riconosce senza
ambiguità. `sweetpmm=<ms>` legge una volta ciascuno i nove registri che la sequenza tocca — stampando
l'indirizzo *prima* di leggerlo, così un blocco dice da solo chi è stato, come in k13n con 0xc30004 — e
poi li campiona ogni 2 ms stampando solo i cambiamenti.

Se `0x00b700c4` diventa 15 mentre guardiamo, la regola del nibble vale anche per il Q6, stiamo leggendo
il registro che lui interroga, e la contraddizione è reale. Se non diventa mai 15, abbiamo guardato la
metà sbagliata del chip per tutto il tempo e l'analisi della riga 502 ricomincia da capo.

## 1229 — silenzio durante il collasso

La domanda che non ci siamo mai fatti: il colpevole siamo noi?

La sequenza di sleep chiede al GDSC della WLAN di collassare e gli dà 100 ms. In *ogni* run che abbiamo
mai fatto, mentre questo succedeva l'host stava leggendo WCSS attraverso la finestra: il ciclo dopo
l'INIT chiama `wcss_cc_dump` ogni 40 ms, e lo fa senza condizioni dal giorno in cui è stato scritto —
in k50, in k55, in k61. Ognuna di quelle letture seleziona una finestra a BAR+0x310C e legge *dentro* il
sottosistema che il firmware sta cercando di spegnere. Un dominio non collassa mentre il bus che ci entra
viene pilotato: il timeout a 100 ms e l'assert alla riga 502 sono esattamente l'aspetto che avrebbe un
collasso impedito.

Le celle vicine, riguardate:

- **k59** (`sweetquiet=1500`) sembrava la prova del silenzio, ma `sweetpwr` vale 1 di default: ha
  interrogato WLAON ogni millisecondo per i primi 120 ms e ogni 5 ms dopo, e ha lasciato intatto il ciclo
  dei 40 ms. Nessun traffico è un'altra cosa da poco traffico: con una lettura ogni millisecondo il link
  non entra mai in L1 e il dispositivo non entra mai in M2, che sono la precondizione del collasso.
- **k60** (`sweetwake=1`) ha tolto il voto di wake dell'MHI ma ha continuato a leggere WCSS ogni 40 ms.

La casella mai provata è quindi «niente wake **e** zero MMIO». `sweetsilence=<ms>` sta fuori dal bus
completamente per quel tempo dopo l'INIT: niente WCSS, niente MHI, niente copy engine, niente. Il
WMI READY resta nel ring e lo leggiamo quando torniamo. `sweetwcss=1` rimette il dump dei 40 ms per
quando vogliamo davvero guardare.

## 1230 — il testimone letto dopo il silenzio

Le prove sul telefono sono la risorsa scarsa: ognuna vuole dieci minuti e un tap sul telefono. 1228 e
1229 chiedevano due run perché la lettura del testimone, se fatta *durante* la finestra, è esattamente
la cosa che 1229 sospetta sia la causa del guasto.

Ma dopo il silenzio quel conflitto non c'è più: la finestra del collasso è passata, e leggere i nove
registri lì non può aver bloccato niente. Quindi `sweetsilence` ora, quando ha finito, li legge una volta
sola. Un solo run dice tutt'e due le cose: se il silenzio fa passare l'INIT, e se `0x00b700c4` tiene il
15 che il firmware ci mette due pacchetti prima di cominciare a interrogare il GDSCR — cioè se la regola
del nibble vale anche per il Q6 o se abbiamo guardato la metà sbagliata del chip.

La lista dei nove registri diventa `pmm_regs`, condivisa fra le due strade.

## 1231 — «l'assert a +440 ms» non è mai stata una misura

Rileggendo il log di k61 riga per riga:

	70.952  INIT
	70.957  GDSC +0 ms   WLAN1 0xa0223800  (acceso)
	71.022  GDSC +60 ms  WLAN1 0x00222001  (collassato) — e non cambia più
	71.943  finestra gwatch finita, "firmware alive"
	72.380  "WMI ready flag 0", evento di stato MHI, "SYS_ERR: il firmware è crashato"
	73.128  record di crash: Asserted in0x1503340s:502

Il SYS_ERR compare a 72.380 nello stesso millisecondo in cui finisce il ciclo dei 400 ms. Non è
l'istante in cui il firmware è morto: è l'istante in cui l'abbiamo guardato. Il SYS_ERR arriva su **ER0**,
e fino a ora ER0 veniva interrogato solo dentro `wifi_wait`, che parte dopo tutt'e due le finestre. Il
ciclo di gwatch e quello dei 400 ms interrogano ER1 e le copy engine e basta, quindi l'evento è rimasto
nel ring non letto fino a 1,4 secondi.

Quindi «il firmware asserisce ~440 ms dopo l'INIT» non è mai stato un dato: era il momento in cui
cambiava il nostro modo di guardare. Il crash può stare ovunque da +60 ms in poi — e +60 ms è esattamente
quando il dominio collassa. Un `er0_poll` in ciascuno dei tre cicli trasforma il timestamp del log nella
risposta vera.

## k65 — il data path si costruisce, e non c'entra

Con il tracciamento di 1227 e `sweetdplinks=2048` il data path si tira su tutto:

	SWEET DP: 2048 link descriptors, 256 KiB for them, 3072 KiB of rings, pool has 728928 KiB
	SWEET DP: ring block at 0xd1430000, mapping it
	SWEET DP: link block at 0xd1730000, mapping it
	SWEET DP: idle list: 2048 link descriptors, head 4096
	SWEET DP: 15 rings up, 2072 KiB used; REO gen 0xc0000dc, TCL ctrl 0x9e000, idle misc 0xc2

Il pool aveva 712 MiB liberi, quindi k64 non si era fermato per mancanza di memoria: a non riuscire era
la **mappatura** del blocco da 4 MiB in un pezzo solo, non l'allocazione. Con 256 KiB passa.

E il firmware muore lo stesso, con la stessa identica sequenza di k61: GDSC collassati a +80 ms, SYS_ERR
letto alla fine del ciclo dei 400 ms, `Asserted in0x1503340s:502`. Quindi il data path mancante non era
la causa — ma adesso c'è, e servirà comunque appena il blocco cade.

## k69 e 1232 — la regola del nibble non regge

k69 ha tenuto l'host fuori dal bus per 600 ms interi, non un solo accesso MMIO mentre il firmware faceva
la sua sequenza. Ha asserito lo stesso alla riga 502, e il SYS_ERR era già lì quando siamo tornati a
guardare: **il crash avviene nel silenzio totale**, quindi non siamo noi a impedire il collasso. Quella
strada è chiusa, e con essa l'ipotesi dell'interferenza.

Ma i nove registri letti all'uscita dicono una cosa peggiore:

	0x00b700c4 = 0x00000fff      il firmware ci scrive 15
	0x00b60088 = 0               ci mette i bit 0 e 1
	0x00b600f8 = 0x00000003      ci mette il bit 2, quindi dovrebbe valere almeno 4
	0x00b5ff88 = 0               ci azzera il bit 31
	0x00b6203c = 0xdeadc0de      non mappato: è il valore che il chip dà dove non c'è niente
	0x00c300c4 = 0x00222001      collassato, PWR_ON a zero — esattamente ciò che aspetta, e va in timeout

Nessuno di questi torna con quello che la sequenza fa, e uno non è mappato per niente. La regola del
nibble — 0xE0Bxxxxx del firmware = 0x00Bxxxxx nostro — è un'affermazione sull'aritmetica della *nostra*
finestra, e il Q6 arriva a quei blocchi su un bus suo. Su questa evidenza non regge, il che vuol dire
che ogni lettura dell'assert alla riga 502 fatta finora era sui registri sbagliati.

E c'è il secondo filo: `WLAON counter 129695644 -> 129695644 in 100 ms = 0 Hz`, dove il firmware si
aspetta 19.2 MHz. O quel contatore non è dove crediamo, o l'orologio di sleep non gira — e una macchina
a stati del PMM che aspetta quell'orologio non finirebbe mai la sua stretta di mano, che è esattamente
un timeout di 100 ms.

Quindi basta indovinare indirizzi: che risponda il chip. 1232 fotografa un'intera finestra da 512 KiB
(la 0x16, 0x00b00000–0x00b7ffff, dove stanno tutti gli indirizzi WFSS_PMM che la sequenza nomina) prima
dell'INIT, lascia correre il firmware, la rilegge dopo il crash e stampa cosa si è mosso. Prima due
passate di fila, per riconoscere le parole che ticchettano da sole: quelle sono contatori liberi, e
sapere se ne esiste anche uno solo risponde al secondo filo.

## k71 e 1233 — forse è la regola del nibble più uno scostamento di 64 KiB

Il diff della finestra 0x16 è tornato con un avvertimento attaccato. Su 131072 parole, **65595 cambiano
fra due letture prese una dopo l'altra** e 20205 danno deadc0de: metà di quella finestra, sotto le nostre
letture, non è stabile per niente. Il che da solo spiega i nove valori senza senso di k69 — erano letti
*dopo* il collasso, con il dominio spento. Erano spazzatura, non una prova contro la regola del nibble.

Fra le parole stabili, mentre il firmware girava se ne sono mosse esattamente cinque:

	0x00b500cc  0 -> 0x00010000
	0x00b50218  0 -> 0x00000080
	0x00b520cc  0 -> 0x00010000
	0x00b52218  0 -> 0x00000080
	0x00b60000  0 -> 0x0000fffc

Due coppie a 0x2000 di distanza — la stessa forma a due istanze dei GDSCR WLAN1 e WLAN2 — e l'ultima
scrittura che la sequenza fa è un read-modify-write di **0xE0B600CC**. Il nostro 0x00b500cc è
0xE0B600CC meno 0x10000. Con lo stesso scostamento 0xE0B70000 diventa 0x00b60000, che è l'altra parola
che si è mossa.

Quindi la mappa potrebbe essere la regola del nibble **più uno scostamento di 64 KiB**. Se è così, il
registro che chiamiamo GDSCR WLAN1, 0x00c300c4, è in realtà lo 0xE0C400C4 del firmware, e il GDSCR che
lui interroga è il nostro 0x00c200c4 — che non abbiamo mai letto.

È una domanda da due registri. Il campionatore ora guarda tutt'e due le grafie del 15 e tutt'e due
quelle del GDSCR, ogni 2 ms, cominciando *prima* del collasso invece che dopo. 0x00c200c4 è l'indirizzo
mai provato, quindi sta per ultimo: se blocca il telefono, il log su UFS conserva comunque le briciole.

## k72 — il crash è datato, e lo scostamento di 64 KiB è morto

	70.999  INIT
	+56 ms  0x00b600f8  0x13 -> 0x03        (perde il bit 4)
	+56 ms  0x00c300c4  0xa0223800 -> 0x00222001   PWR_ON a zero
	+93 ms  SYS_ERR
	        Asserted in0x1503340s:502

Due soli registri su dodici si muovono, e uno è **esattamente** quello che il firmware interroga, che
va **esattamente** nello stato che aspetta. Il poll è 1000 tentativi da 100 µs, cioè 100 ms, e il
firmware ha asserito a 93: stava ancora guardando **37 millisecondi dopo** che il bit che voleva si era
azzerato sotto il suo naso.

E la teoria dello scostamento è morta: `0x00c200c4` leggeva 0 prima dell'INIT e non si è mai mosso,
mentre `0x00c300c4` ha fatto esattamente quello che la sequenza chiede. La regola del nibble regge per
il GDSCR, il registro che leggiamo è quello giusto, e **le letture del Q6 sono vecchie**.

Resta in piedi una sola spiegazione, ed è il filo che scavalchiamo da giorni:

	WLAON counter 129769002 -> 129769002 in 100 ms = 0 Hz, firmware expects 19200000 Hz

Un bit di stato sincronizzato in un dominio il cui clock non gira non arriva mai a chi lo legge, per
quante volte guardi. Il dominio collassa, il GDSCR visto da fuori lo dice, e la vista che ne ha il Q6
resta congelata finché il poll non finisce.

Prima di costruirci sopra, 1234 stabilisce se è il clock o solo il nostro indirizzo: legge 64 KiB di
WLAON due volte a `sweettick` millisecondi di distanza e stampa ogni parola che si è mossa con la
frequenza che implica. Se una conta, il contatore vero è quello e il clock vive. Se nel dominio
always-on non si muove niente, il bug è il clock.

## k73 e 1235 — la scansione va fatta a pagine

k73 ha letto 64 KiB di WLAON in un colpo solo e il telefono si è fermato di netto: il log finisce sulla
riga *precedente* alla scansione, `WLAON_QFPROM_PWR_CTRL before INIT`, e non c'è una sola riga
`SWEET TICK`. Da qualche parte in quei 64 KiB c'è un indirizzo che in lettura va in abort, come
0xc30004 in k13n.

Errore mio: una scansione cieca senza briciole. 1235 la cammina una pagina da 256 parole alla volta e
stampa la pagina *prima* di leggerla — il log va su UFS ogni due secondi, quindi la briciola sopravvive
al blocco. Il campo di default scende a 4 KiB, cioè la zona da cui leggiamo già registri singoli senza
problemi; `sweettickn` lo allarga a pagine, una volta saputo dov'è il muro.

## k74 — il clock c'è: leggevamo l'indirizzo sbagliato

Prime 4 KiB di WLAON, lette due volte a 200 ms di distanza, una pagina alla volta. Si sono mosse
esattamente due parole:

	0x01f80108  0x07c36f57 -> 0x08023d99   delta 4116034   ~20.58 MHz
	0x01f80908  0x07c561b4 -> 0x0804304e   delta 4116122   ~20.58 MHz

Il contatore always-on sta a **0x1f80108**, non a 0x1f80118, e il suo specchio a +0x800. Gira, e gira a
19.2 MHz entro l'errore del nostro `pc_msleep(200)`. Quindi il `0 Hz` che ci portavamo dietro da giorni
era solo il nostro indirizzo sbagliato di 0x10: **il clock del dominio always-on non è mai stato fermo**,
e anche la teoria dell'orologio morto cade.

Il quadro che resta, tutto misurato:

- il GDSC collassa a +56 ms, sul registro che il firmware interroga, nello stato che aspetta;
- il firmware asserisce a +93 ms, cioè alla scadenza dei suoi 100 ms di poll;
- la grafia spostata di 64 KiB è morta (0x00c200c4 non si muove mai);
- il clock always-on gira.

Non resta che la lettura del Q6 che vede altro. Quindi stessa strategia che ha funzionato per il PMM:
che risponda il chip. 1236 rende paginato anche il diff della finestra, con le briciole e con
`sweetdiffskip`/`sweetdiffpages`, così si può spazzare la finestra 0x18 — quella di WCSS_CC, dove sta
lo 0xc30004 che bloccò k13n — senza perdere il run quando si incontra il muro. Quello che cerchiamo è
una seconda parola con la forma di un GDSCR che, mentre 0x00c300c4 collassa, resta con PWR_ON a uno:
quella sarebbe la vista del Q6.

## k75 — sotto 0xc30000 non c'è niente, e la convenzione del poll è confermata

Finestra 0x18, pagine 0..191, cioè 0xc00000..0xc2fffc: **0 parole che ticchettano, 0 deadc0de, 0 parole
cambiate** mentre il firmware girava. Quella regione è morta del tutto, e con essa l'ultima versione
dell'idea della mappa spostata.

Nel frattempo ho verificato la convenzione del poll sul disassemblato invece che per inferenza. I due
siti di chiamata usano *helper diversi* (0x156c17c per lo sleep, 0x156cad0 per l'accensione) ma tutt'e
due saltano allo stesso thunk 0x14FC904 e da lì alla stessa routine ROM a 0x880F24:

	sleep        r0 = 0xE0C300C4  r1 = 0x80000000  r2 = 0           (aspetta PWR_ON a zero)
	accensione   r0 = 0xE0C300C4  r1 = 0x80000000  r2 = 0x80000000  (aspetta PWR_ON a uno)

Quindi `aspetta finché (v & mask) == atteso` è giusto, ed è lo sleep a fallire — il 502 si carica solo a
0x156bfb4, quattro pacchetti dopo quel poll.

Resta il fatto nudo: il bit si azzera a +56 ms all'indirizzo che il firmware ha passato, e lui continua
a guardare fino a +93. 1238 sposta la scansione sopra il muro, da 0xc30100 alla fine della finestra:
se là dentro c'è un secondo registro a forma di GDSCR che resta con PWR_ON a uno mentre 0xc300c4
collassa, quella è la vista del Q6.

## k76 e 1239 — resta una pagina sola, e la leggiamo intera

k76 ha spazzato 0xc30400 fino in fondo alla finestra: due parole ticchettano, nessuna dà deadc0de, e
**nessuna cambia** mentre il firmware gira. Fra questo e k75 l'intera finestra 0x18 è coperta tranne una
pagina da 1 KiB — 0xc30000..0xc303fc — e dentro ci sta tutto quello che abbiamo mai guardato in
WCSS_CC: 0xc300c4 (il GDSCR che interroga), 0xc30100..0xc3010c, e il GDSCR WLAN2 a 0xc30138.

(Nota sulle unità: una «pagina» qui è 256 parole, cioè 1 KiB, non 256 byte. Con `skip=193` k76 partiva
da 0xc30400 e non da 0xc30100: la pagina che conta era proprio quella saltata.)

Il muro di k13n non c'è più: `gdsc_peek` legge 0xc30004 in ogni run da settimane e torna 0. Quindi
`sweetdiff=25` prende quella pagina e basta, con una briciola ogni 32 parole, e siccome 256 parole sono
poche le stampa **tutte**, prima e dopo, invece dei soli cambiamenti. Il blocco intero, davanti e dietro
il collasso.

## k77 — otto rami di clock che non partono mai, e la riga 502 si rilegge al contrario

Tutte e 256 le parole di 0xc30000..0xc303fc, prima dell'INIT e dopo il crash. La pagina si legge come un
clock controller: decine di parole passano fra `0x80000001` e `0x00000001`, cioè un branch register
Qualcomm fra «abilitato ma fermo» (bit 31 CLK_OFF) e «gira». Ne partono venti durante il run. **Otto non
partono mai**, né prima né dopo:

	0xc300d0 0xc300d4 0xc300d8 0xc300dc   accanto al GDSCR WLAN1 a 0xc300c4
	0xc30144 0xc30148 0xc3014c 0xc30150   accanto al GDSCR WLAN2 a 0xc30138

Due gruppi di quattro, a 0xc8 di distanza, nella stessa forma WLAN1/WLAN2 dei GDSCR: sono i branch clock
dei domini radio, abilitati e fermi. E un GDSC **non può finire di spegnersi mentre i suoi rami sono
abilitati e fermi** — la stretta di mano li aspetta.

Il che rilegge la cronologia di k72 al contrario. Non è che il firmware non si accorge del collasso: il
collasso a +56 ms è ciò che **finalmente** accade quando il firmware si arrende e i suoi enable cadono,
e il SYS_ERR ci arriva 37 ms dopo. Il poll non fallisce perché legge vecchio: fallisce perché per tutta
la sua durata il dominio davvero non è sceso.

Android risolverebbe la cosa in una lettura sola, ma questa build non ha root (`adb root` disabilitato
da impostazione di sistema) e non ha il debugfs di cnss. Però una radio funzionante ce l'abbiamo noi: la
calibrazione gira 3600 ms e il firmware non si lamenta. 1240 stampa quei registri alla partenza e alla
fine della calibrazione, e di nuovo prima e dopo l'INIT di missione. Se per la calibrazione girano e per
la missione no, la differenza fra i due passaggi è il bug.

## k78 — quattro rami girano in calibrazione e sono fermi alla missione

Gli otto rami «fermi» di k77 sono fermi anche durante una calibrazione che funziona, in tutti e quattro
i momenti. Non sono loro: saranno rami senza sorgente, e tanti saluti.

Ma i loro vicini sì:

	                     WLAN1 e0        e4         WLAN2 154       158
	calibration start    0x00000001  0x00000001     0x00000001  0x00000001     girano
	calibration done     0x00000001  0x00000001     0x00000001  0x00000001     girano
	before INIT          0x80000001  0x80000001     0x80000001  0x80000001     ABILITATI E FERMI
	after INIT           0x80000000  0x80000000     0x80000000  0x80000000     disabilitati

**Quattro branch clock girano per tutta la calibrazione e sono fermi quando arriva l'INIT di missione.**
La calibrazione è l'unica radio funzionante che abbiamo, e questa è la prima differenza misurata fra il
passaggio che riesce e quello che fallisce. Un GDSC con rami abilitati e fermi non finisce la stretta di
mano, e il poll da 100 ms scade: è esattamente il guasto.

La loro sorgente muore fra i due passaggi, cioè attraverso il nostro ciclo di alimentazione — che è
roba nostra, non del firmware. 1241 stampa gli stessi registri in altri quattro punti (prima e dopo il
power-down, appena WLAN_EN torna su, e a `firmware init done`) per inchiodare il momento esatto in cui
si fermano.

## k79 — due letture messe dove il bus non c'è

k79 si è fermato a 36.8 secondi, molto prima della bring-up. Colpa di 1241: aveva una `cbcr_dump`
subito dopo il ciclo di WLAN_EN e una dopo `wlan_power_down`, e in tutt'e due i punti il link PCIe è
giù — non c'è BAR attraverso cui leggere una finestra. Stesso errore della marcatura WLAON di 1218,
rifatto un mese dopo.

Tolte. Restano i punti dove la finestra funziona davvero, e bastano a inquadrare la domanda:
calibration start e done nel passaggio 1, `firmware init done` in tutt'e due i passaggi, poi prima e
dopo l'INIT di missione. Se al `firmware init done` del secondo passaggio i quattro rami sono già
fermi, la perdita è nel ciclo di alimentazione; se girano ancora lì e sono fermi prima dell'INIT, è in
mezzo.

## k80 — la sequenza completa, e i quattro rami sono un sintomo

	48.721  firmware init done (passaggio 1)   e0 0x80000001  e4 0x80000001   fermi
	48.865  calibration start                  e0 0x00000001  e4 0x00000001   GIRANO
	52.500  calibration done                   e0 0x00000001  e4 0x00000001   girano
	57.750  before the power-down              e0 0x00000001  e4 0x00000001   girano
	58.802  *** secondo bring-up ***
	70.579  firmware init done (passaggio 2)   e0 0x80000001  e4 0x80000001   fermi
	70.885  before INIT                        e0 0x80000001  e4 0x80000001   fermi
	71.417  after INIT                         e0 0x80000000  e4 0x80000000   spenti

Sono fermi al `firmware init done` di **tutt'e due** i passaggi, e partono quando parte la calibrazione.
Cioè: i branch clock della radio girano quando il firmware sta calibrando e non quando sta fermo prima
della missione — che è esattamente l'aspetto che deve avere una radio inattiva. Sono un sintomo, non la
causa. Terza ipotesi caduta in due run.

Il che rimette al centro l'unico fatto che continua a non entrarci: il GDSCR a 0x00c300c4 va a
0x00222001 a +56 ms, PWR_ON a zero, e ci resta per i 900 ms successivi, mentre il firmware interroga
quello stesso indirizzo per quello stesso bit e va in timeout.

Allora azzeriamolo noi, prima dell'INIT, e che il firmware trovi la condizione già soddisfatta.
Scrivere SW_COLLAPSE è esattamente quello che fa la sua sequenza cinquanta millisecondi dopo, quindi
non si chiede all'hardware niente che non stesse per essergli chiesto comunque.

- Se l'assert sparisce, il registro era quello giusto e il problema era tutto nei tempi.
- Se il 502 torna identico con PWR_ON già a zero alla prima lettura, allora l'indirizzo che il Q6
  interroga **non è** quello che guardiamo da settimane, e continuare a leggerlo non lo dirà mai.

## k81 — il 502 non è il PMM: è cmnos_thread.c

Ho azzerato io il GDSCR prima dell'INIT:

	SWEET COLLAPSE: WLAN1 0xa0223800 -> 0x00223801, WLAN2 0xa0223800 -> 0x00223801, PWR_ON clear after 0 ms
	SYS_ERR 210 ms dopo
	Asserted in0x1503340s:502

Il firmware trovava la condizione già vera alla prima lettura e ha asserito identico. Quel registro non
c'entra.

Allora sono risalito al record di crash invece che all'indirizzo ipotizzato. Il token stampato come
«file», 0x1503340, è il ritorno della chiamata a 0x1503338, cioè la coda di assert condivisa in cui
saltano sette siti (242, 265, 434, 401, 462, 538, 553). E nella tabella di stringhe, attaccate al
formato dell'assert:

	139184  'Asserted in %s:%s:%d'
	1391ac  'cmnos_thread.c'
	1391bc  'Asserted in:0x%x:0x%x, line#%d'
	1391db  'Asserted in0x%xs:%d'                          <- il nostro
	139204  'RAM allocation (%d bytes) failed! arena :: %d'

**La riga 502 è cmnos_thread.c.** Il `r0 = #502` che avevo trovato a 0x156bfb4, nella sequenza di sleep
del PMM, è l'assert di un'altra funzione che usa lo stesso numero; l'ho preso per buono perché era
l'unico caricamento della costante 502 nell'immagine, e ci ho costruito sopra quattro giorni di indagine
su GDSC, clock e mappa degli indirizzi.

Il firmware non aspetta un collasso: **sta esaurendo thread o memoria** mentre costruisce quello che il
nostro WMI INIT gli chiede. E torna tutto — succede subito dopo l'INIT, ed è identico con e senza
calibrazione (k50), con e senza data path (k65), nel silenzio totale (k69), con i clock in qualunque
stato (k78, k80) e col GDSCR già azzerato (k81). Nessuna di quelle cose poteva cambiarlo.

C'era anche un appunto di k13b che leggeva il 502 proprio così, scritto prima che il bring-up a due
passaggi funzionasse e mai riprovato da quando arriviamo davvero in missione. `sweetwmimin=1` chiede la
configurazione minima — 1 vdev, 4 peer, 8 TID invece di 3 vdev e 16 peer — ed è k82.

## k85, k86 e 1244 — la riga 502 è una ricerca in tabella che fallisce

**k85**: INIT con il solo TLV del comando, 36 byte, nessuna resource config. Stesso 502, stessi 100 ms.
I valori non c'entrano: il firmware muore perché *riceve* un WMI_INIT.

Allora ho cercato davvero la riga 502, disassemblando tutto il file invece di scandire la costante — lo
scanner l'aveva mancata perché sta in un'istruzione composta, `if (!p0.new) r16 = #502`:

	01503208  r0 = memw(r29+#36);  memw(##0x15ce4dc) = r0;  memw(##0x15ce4e0) = r24
	01503224  call 0x100007c
	01503228  if (r0 == 0) jump  ok
	0150322c  if (r0 != 1) { r16 = #502; jump assert }

`0x100007c` chiama `0x1000000`, che percorre una tabella di 1207 parole a `0x15a9490`: record a
lunghezza variabile, byte alto la lunghezza, 24 bit bassi la chiave. Le chiavi sono `0x000001`,
`0x006001`, `0x009001`, `0x00b001`, `0x01c001`, `0x005010`… cioè la forma `(gruppo << 12) | 1` dei
comandi WMI, e il record 0 è proprio WMI_INIT. Ricerca fallita → torna 1 → `0x100007c` torna −1 → −1
non è né 0 né 1 → **assert**.

**k86**: un id che in quella tabella davvero non c'è (0x3ffe) viene ignorato e il firmware resta vivo
cinque secondi buoni, con er0 interrogato (quindi stavolta lo sapremmo, se fosse morto). Quindi la
ricerca che fallisce **non è quella del comando che mandiamo noi**.

Ma i due pacchetti prima della chiamata salvano la chiave in un indirizzo fisso. 1244 rilegge
`0x015ce4c8..0x015ce4e4` dalla finestra dopo il crash, con le briciole: è il firmware che ci dice il
nome della cosa che non trova.

## k87 e 1245 — la forma del messaggio, letta dentro il firmware

k87 ha riletto dalla finestra i due indirizzi fissi che la funzione scrive prima di morire:

	0x015ce4dc = 0x0149960c      il puntatore al corpo del messaggio
	0x015ce4e0 = 0x00000148      328, cioè i nostri 332 byte meno l'id del comando

Quindi la chiamata a `0x100007c` riceve (corpo, lunghezza) e torna qualcosa che non è né 0 né 1.

Nel frattempo ho scoperto che `dis.py` sbagliava gli indirizzi in due modi: univa i pacchetti su una
riga sola e non contava gli 8 byte degli immediate extender (`##`). Metà dell'aritmetica dei salti fatta
in questi giorni era quindi falsa. `dis2.py` li conta bene e stampa gli indirizzi dei salti come
`inizio_disassemblato + immediato`.

Con gli indirizzi giusti, `0x100007c` chiama `0x1000000`, che percorre la tabella a `0x15a9490`: 1207
parole, record a lunghezza variabile, byte alto la lunghezza, 24 bit bassi un **id di comando WMI**. Il
record 0 è il comando 1, WMI_INIT, e le sue cinque parole di corpo si spacchettano (tag nei bit 11:0,
dimensione nei bit 20:12) così:

	tag 0x04a    32 byte     la struct del comando init
	tag 0x04b   308 byte     la resource config
	tag 0x012    20          un array di elementi da 20
	tag 0x203    16
	tag 0x012    16          un array di elementi da 16: i memory chunk dell'host

Noi mandavamo **0x4e e 0x4f**, con una resource config da 292 byte e un array solo. Tag sbagliati tutti
e due, config corta di quattro parole, due TLV mancanti. L'unica cosa giusta era 0x012 per
ARRAY_STRUCT — e i tag degli eventi che già interpretiamo, 0x20 per SERVICE_READY e 0x23 per READY,
collocano questo firmware nello stesso spazio di tag, quindi i numeri sono confrontabili davvero.

Spiega anche k86: un id sconosciuto non arriva mai a questo parser, viene scartato prima e il firmware
sopravvive; WMI_INIT invece ci arriva, e fallisce.

1245 costruisce il messaggio come lo chiede il firmware: 368 byte, tag 0x4a e 0x4b, resource config da
304 byte di payload, e i tre TLV di coda. `sweetoldtlv=1` rimanda la forma vecchia per il confronto.

## k88 — IL FIRMWARE RISPONDE

	49.111  INIT (368 byte, tag 0x4a/0x4b)
	49.122  evento 0x16005 tag 0x18d
	49.262  evento 0x3a001 tag 0x261  (due volte)
	49.262  evento 0x2 tag 0x23   ->  WMI READY
	49.545  FIRMWARE UP (WMI ready)

**Il muro che stava in piedi da k50 è caduto.** Erano i tag TLV. Gli mandavamo 0x4e e 0x4f dove lui
aspetta 0x4a e 0x4b, con la resource config corta di quattro parole e due TLV mancanti.

Subito dopo asserisce di nuovo, su `vdev 0 create` — che è costruito con i tag vecchi esattamente come
lo era l'INIT. Stesso errore, comando successivo.

Ma adesso non si indovina più. La tabella a 0x15a9490 contiene **462 comandi**, ognuno con il suo
layout TLV completo. Per quelli che mandiamo:

	id 0x0001 WMI_INIT         0x04a/32   0x04b/308  0x012/20  0x203/16  0x012/16
	id 0x5001 VDEV_CREATE      0x056/40   0x012/16   0x012/12
	id 0x3001 START_SCAN       0x04d/160  0x010/4  0x013/36  0x013/8  0x011/1  0x012/8  0x011/1  0x013/8  0x013/12

Noi usavamo 0x5a per VDEV_CREATE (giusto 0x56) e 0x51 per START_SCAN (giusto 0x4d), con quattro TLV di
coda invece di otto. Le dimensioni delle struct erano già giuste: era solo la numerazione dei tag, presa
da una versione di ath11k che non è quella di questo firmware. 1246 corregge tutt'e due.

Da tenere d'occhio: il READY riporta MAC 00:00:00:00:00:00.

## k89 — nessun crash: INIT, vdev e scan passano tutti

	49.090  INIT 368 byte
	49.244  WMI READY
	49.527  FIRMWARE UP
	49.527  vdev 0 create        (nessun assert)
	49.854  scan start
	49.865  evento 0x3001 tag 0x24   <- il firmware risponde alla scansione
	51.5 .. 77  decine di eventi 0x1d011, tag 0x11, 1500 byte l'uno
	77.149  "scan: nothing in 25000 ms"

Il firmware **non crasha più**. Con i tag giusti accetta INIT, creazione del vdev e avvio della
scansione, e da lì in poi parla da solo per quasi trenta secondi.

Due cose da raccogliere, e sono tutt'e due nostre:

- l'evento di scansione di questo firmware è **0x3001**, non 4. Lo abbiamo buttato e siamo rimasti ad
  aspettare i 25 secondi di timeout per niente. Stessa lezione dei tag: gli id vanno presi da questo
  firmware, non dalla build di ath11k da cui erano stati copiati.
- gli eventi **0x1d011**, tag 0x11 (ARRAY_BYTE) da 1,5 KiB, sono il **log del firmware**. Avevamo speso
  un run (k84) ad aprire i canali DIAG per avere le sue parole, e intanto arrivavano su WMI.

1247 prende l'evento di scansione in tutt'e due le numerazioni, stampa il log del firmware come testo, e
fa il dump dell'evento READY: il MAC lì dentro legge sei byte a zero, e un vdev senza indirizzo non si
associa a niente. O l'offset viene dall'ath11k sbagliato, come i tag, o il firmware non ha davvero un
indirizzo da dare — il dump lo dice a occhio.

## k90 — lo scan parte e viene rifiutato, e il firmware non ha un indirizzo

	49.287  READY: MAC 00:00:00:00:00:00
	49.910  scan event 0x40
	58..77  decine di eventi 0x1d011, log del firmware (binario, non testo)

**L'evento di scansione adesso lo prendiamo** — ed è `0x40`, cioè `WMI_SCAN_EVENT_START_FAILED`. La
scansione è stata rifiutata undici millisecondi dopo l'invio, non persa: tutt'altra cosa dal silenzio
di prima.

Il dump dell'evento READY, con l'offset di ath11k che torna (num_total_peers a +44 legge 16, che è
esattamente quello che abbiamo chiesto nella resource config):

	+00: 00000001 f5030000 5143415f 4d4c0000     <- "QCA_ML", la firma della abi version
	+16: 00000000 00000000 00000000 00000000     <- il MAC, a +24: sei zeri
	+32: 00000000 00000000 01000000 10000000     <- status 0, num_total_peers 16
	+48: 11000000 8f000000 00000000 00000000

Quindi **il MAC a zero non è un offset sbagliato: il firmware non ne ha uno**. Sta nei board data, e
nessuno gliel'ha dato. 1248 usa un indirizzo localmente amministrato (il 0x02 nel primo byte dice che
ce lo siamo inventati) finché non andiamo a prendere quello vero dalla partizione persist.

E il rifiuto della scansione: ath11k mette **0xa000 in tutt'e due** i campi — lo scan id è 0xa000 più
un contatore, il requestor id è 0xa000 secco — e noi nel secondo avevamo messo 1. Un firmware che
controlla il requestor contro gli id che conosce la rifiuta e basta.

Nota sul log del firmware: gli eventi 0x1d011 sono binari, non testo. Si decodificano, ma serve il
database dei messaggi; per ora restano una traccia di vita.

## k92 — la scansione parte: era il dominio regolatorio

	49.904  scan start (tre canali nominati)
	49.915  scan event 0x1 STARTED   reason 7 requestor 0xa000 id 0xa000 vdev 0
	49.915  scan event 0x2 COMPLETED reason 7
	49.915  SCAN COMPLETE, 0 frames from access points

Con i canali nominati esplicitamente la scansione **parte**, invece di essere rifiutata. Quindi il
`num_chan = 0` era la causa del START_FAILED: il firmware costruisce la propria lista dal dominio
regolatorio, e nessuno gliene ha mai dato uno.

Ma parte e finisce nello stesso millisecondo, senza sentire niente: una radio che non si è fermata su
nessun canale. Il che punta di nuovo allo stesso buco — senza dominio regolatorio il firmware non
trasmette su quei canali, li accetta soltanto nella richiesta.

Prima di tirare a indovinare quale comando pdev mandare, 1250 stampa il contenuto degli eventi che
finora buttavamo via con la sola intestazione: `0x16005` e i due `0x3a001` arrivati subito dopo l'INIT.
Uno dei due è molto probabilmente la lista dei canali che il firmware si è costruito, e leggerla vale
più di qualunque supposizione sull'ordinamento dei gruppi WMI.
