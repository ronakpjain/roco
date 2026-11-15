# Target profile

The tools target the roco five-stage RV32 CPU. This is the supported
assembly boundary; instructions outside it are rejected rather than
encoded and left to trap.

## Scalar ISA

| Feature | Support |
| --- | --- |
| Base | RV32I |
| Multiply/divide | RV32M |
| Atomics | RV32A, `.w` only |
| CSRs | Zicsr |
| Instruction fence | Zifencei |
| Privilege | M, S, U; `MRET`, `SRET`, `ECALL`, `EBREAK` |
| Memory management | Sv32 (runtime feature) |
| Interrupts | machine timer/external wiring is present in the RTL |
| Compressed instructions | not supported |
| Floating point | not supported |

The assembler implements the integer, CSR, atomic, fence, and system
mnemonics in the [assembler reference](assembler.md). It emits
little-endian ELF32 RISC-V objects and uses 4-byte instruction alignment.

## Vector ISA

roco implements a Zve32x subset with fixed VLEN = 128 and LMUL = m1.
The assembler accepts SEW = 8, 16, or 32 and rejects other widths and
LMUL values.

Supported vector instructions:

| Form | Mnemonics |
| --- | --- |
| Configuration | `vsetvli`, `vsetivli`, `vsetvl` |
| Element arithmetic | `vadd`, `vsub`, `vand`, `vor`, `vxor` in `.vv`, `.vx`, `.vi` |
| Vector move | `vmv.v.v`, `vmv.v.x`, `vmv.v.i` |
| Scalar/vector move | `vmv.x.s`, `vmv.s.x` |
| Reduction | `vredsum.vs` |
| Unit-stride memory | `vle8.v`, `vle16.v`, `vle32.v`, `vse8.v`, `vse16.v`, `vse32.v` |

Not implemented by roco, and therefore rejected by the assembler:

- LMUL other than m1;
- SEW other than 8, 16, or 32;
- masked operations (`.v0.t`);
- strided, indexed, segment, and whole-register memory operations;
- vector integer multiply, divide, shift, compare, min/max, slide, gather,
  and other Zve32x operations not listed above.

Tail policy `ta` is implemented by the RTL. Mask policy `ma` is accepted
in the syntax but has no effect because masking is absent. See
[hardware notes](hardware-notes.md) for the exact consequences.

## Memory and boot

| Region | Address |
| --- | --- |
| SDRAM image base | `0x1000_0000` |
| SDRAM window | `0x1000_0000` - `0x11ff_ffff` |
| UART | `0x8000_0000` |
| Timer/cache/debug registers | `0x8000_0010` - `0x8000_004c` |
| Boot status and `tohost` | `0x8000_0100` - `0x8000_1000` |

The bootloader loads a flat image at the image base and starts the core
there. The existing freestanding startup code places the stack at
`0x100f_0000`. The linker uses the SDRAM base and a section order of
`.text`, `.rodata`, `.data`, `.bss`, with `.text.init` first for startup
code.

## ABI and code-generation policy

- ILP32: `int`, `long`, and pointers are 32 bits.
- Standard RISC-V integer calling convention; stacks are 16-byte aligned
  at calls.
- No compressed instructions, no floating point, no PIC/PIE.
- No linker relaxation.
- `la` uses absolute `LUI` + `ADDI` relocations, matching a fixed-address
  freestanding image.
- Branches and jumps use the standard ±4 KiB and ±1 MiB ranges.

## Compiler guidance

The current C compiler emits scalar RV32IMA only. It does not auto-vectorize,
so the vector caveats below apply to hand-written assembly and future
backend work:

- Use `vsetvli` with SEW 8/16/32 and LMUL=m1.
- Prefer scalar code for operations not in the vector table.
- Do not emit `vmv.v.v` until the RTL source-field issue in the
  [hardware notes](hardware-notes.md) is fixed. Use `vmv.v.i`, `vmv.v.x`,
  or scalar moves instead.
- Do not rely on `vma` or masked vector operations.
- Use the standard A extension only for 32-bit atomics.
