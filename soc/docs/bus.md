# SoC bus architecture

`roco_soc` instantiates a nine-master, two-slave AXI4 crossbar. Each hart
contributes an instruction cache (line reads), a data cache (line fills and
writebacks), a native MMU walker (PTE reads) and an uncached data port
(single-beat peripheral accesses); the UART bootloader writes single words.
The cache and bootloader datapaths use `axi4_mem_master` to present their
transactions on AXI4.

| Master | Owner |
|---|---|
| m0/m1 | Hart0 I-cache / D-cache |
| m2 | Bootloader |
| m3/m4 | Hart0 page-table walker / uncached data |
| m5/m6 | Hart1 I-cache / D-cache |
| m7/m8 | Hart1 page-table walker / uncached data |

| Physical address | AXI4 destination | Supported transfers |
|---|---|---|
| `0x1000_0000`–`0x11ff_ffff` | CDC bridge → `axi4_sdram_adapter` → SDRAM | Aligned 32-bit INCR bursts, 1–16 beats within a 256-word SDRAM row |
| All other addresses | `axi4_apb_bridge` → `roco_apb_peripherals` | Single-beat APB4 register accesses, with byte strobes |

The core fabric runs at `CLK_HZ` (48 MHz) while the SDRAM controller runs at
`MEM_CLK_HZ` (96 MHz). `axi_cdc_bridge` carries the single-outstanding SDRAM
slave port across the two clocks with a per-channel toggle handshake; the
crossbar guarantee of at most one read and one write owner per slave makes one
slot per channel sufficient. The SDRAM adapter buffers the returning burst
because the SDRAM controller cannot pause its read stream. Each MMU walker
keeps an outstanding request stable through a TLB flush or warm reset, then
discards its response rather than installing a stale translation.

Arbitration is round-robin per slave and direction. A master can have one read
and one write outstanding; an address grant stays with its owner through stalls
and response completion.

An atomic to an uncached address uses that port twice. The MEM stage publishes
`dmem_amo_read` for its operand-capture phase, which the SoC turns into a
single-beat read (with the write strobe masked); the following phase sends the
one write with the computed data. A cached atomic never touches this port,
because the EX cache lookup already answered it.

## SMP coherence

The two D-caches run an MSI bus-snooping protocol through a hub in `roco_soc`,
without an Exclusive-clean state: every fill is shared and every store or
atomic upgrade invalidates the peer (after writing back a dirty peer copy
through a full-cache flush). Fills and victim writebacks pass straight to the
AXI masters; only fill/upgrade acceptance stalls while a probe or flush is in
flight. A hart whose peer is parked in reset skips probing, so single-hart
timing is unchanged.

`FENCE.I`/`SFENCE.VMA` from either hart flushes both D-caches, invalidates both
I-caches and both TLBs (remote shootdown), then releases only the requesting
hart. Load-reserved/store-conditional reservations are per-hart and cleared by
a committed store from either hart, so cross-hart `LR`/`SC` pairs order
correctly. The programming model: share writable data with AMO/LR/SC (which
drive invalidation through the hub) or uncached MMIO; plain stores become
visible through the writeback but do not invalidate the peer's clean copy.

`make test_bus` runs standalone bus regressions. `make test_soc`, `make test_vm`,
and `make test_boot` exercise the wired fabric, MMU walker, and UART boot path.
`make test_smp` runs the dual-hart bring-up (release mailbox, shared-memory
rendezvous, cross-hart AMOs) through the cached SoC.
