# SoC bus architecture

`roco_soc` instantiates a five-master, two-slave AXI4 crossbar. The instruction
cache issues line reads; the data cache issues line fills and writebacks; the
UART bootloader writes single words; the native MMU walker reads PTEs; and the
CPU uncached data port issues single-beat peripheral accesses. The cache and
bootloader datapaths use `axi4_mem_master` to present their transactions on AXI4.

| Physical address | AXI4 destination | Supported transfers |
|---|---|---|
| `0x1000_0000`–`0x11ff_ffff` | `axi4_sdram_adapter` → SDRAM | Aligned 32-bit INCR bursts, 1–16 beats within a 256-word SDRAM row |
| All other addresses | `axi4_apb_bridge` → `roco_apb_peripherals` | Single-beat APB4 register accesses, with byte strobes |

Arbitration is round-robin per slave and direction. A master can have one read
and one write outstanding; an address grant stays with its owner through stalls
and response completion. The SDRAM adapter buffers the returning burst because
the SDRAM controller cannot pause its read stream. The MMU walker keeps an
outstanding request stable through a TLB flush or warm reset, then discards its
response rather than installing a stale translation.

An atomic to an uncached address uses that port twice. The MEM stage publishes
`dmem_amo_read` for its operand-capture phase, which the SoC turns into a
single-beat read (with the write strobe masked); the following phase sends the
one write with the computed data. A cached atomic never touches this port,
because the EX cache lookup already answered it.

The APB block decodes the low 16 address bits, preserving the existing register
aliases. Unmapped offsets read zero and ignore writes. Devices see side effects
only on APB completion; the CPU waits for the AXI response before committing the
access. A UART TX write waits for space in the FIFO. System halt and warm restart
take effect after the CPU commits their write, so they do not leave a pending
write response. No AHB segment is used.

`make test_bus` runs standalone bus regressions. `make test_soc`, `make test_vm`,
and `make test_boot` exercise the wired fabric, MMU walker, and UART boot path.
