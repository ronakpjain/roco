# Linker

`roco_ld` links ELF32 relocatable objects into a fixed-address roco
image. It has no linker-script language: placement is deliberately
predictable for this machine.

```bash
roco_ld -o program.elf --binary program.bin --hex program.hex \
  startup.o program.o
```

Options:

| Option | Meaning |
| --- | --- |
| `-o FILE` | ELF executable output (default `a.elf`) |
| `--binary FILE` | flat load image |
| `--hex FILE` | word-per-line image for the CPU testbench |
| `-e SYMBOL` | entry symbol (default `_start`) |
| `--base ADDRESS` | first load address (default `0x10000000`) |
| `-Map FILE` / `--map FILE` | section and symbol map |

## Layout

Allocatable input sections are grouped into four output sections:

| Output | Input classification |
| --- | --- |
| `.text` | `SHF_EXECINSTR` |
| `.rodata` | allocatable, not writable, not executable |
| `.data` | writable `SHT_PROGBITS` |
| `.bss` | writable `SHT_NOBITS` |

Within `.text`, `.text.init` contributions come first, then `.text`, then
other executable sections. Everything else follows command-line object
order and section order. Each contribution is aligned to at least four
bytes and to its own alignment.

The default base is the SDRAM image address `0x10000000`. `.bss` is
`SHT_NOBITS`: it consumes memory addresses but no file bytes, so startup
code must clear it.

## Symbols

Local symbols are emitted with their final section and offset. Global
definitions follow the strong-over-weak rule; two strong definitions are
an error. Undefined weak references resolve to zero, while undefined
strong references fail the link.

The linker defines freestanding convenience symbols:

`__text_start`, `__text_end`, `__rodata_start`, `__rodata_end`,
`__data_start`, `__data_end`, `__bss_start`, `__bss_end`, `_end`, and
`__global_pointer$`.

These are absolute symbols. A user definition with the same name takes
precedence.

## Relocations

Supported relocation records:

`R_RISCV_32`, `R_RISCV_BRANCH`, `R_RISCV_JAL`, `R_RISCV_CALL`,
`R_RISCV_CALL_PLT`, `R_RISCV_HI20`, `R_RISCV_LO12_I`,
`R_RISCV_LO12_S`, `R_RISCV_PCREL_HI20`, `R_RISCV_PCREL_LO12_I`, and
`R_RISCV_PCREL_LO12_S`.

`R_RISCV_ALIGN` and `R_RISCV_RELAX` are accepted as no-ops. Linker
relaxation is not performed, so every instruction keeps its original
size. Branches and jumps are range-checked; a target that does not fit is
a link error rather than a silently truncated displacement.

PC-relative low relocations locate the matching `AUIPC` high relocation
at the label address, which is the standard GCC/LLVM pairing.

## Outputs

- The ELF executable has one read/write/execute `PT_LOAD` segment and a
  conventional section table and symbol table for disassembly and debug.
- The flat image starts at the base address, includes alignment gaps as
  zeroes, and excludes `.bss`.
- The hex image is one 32-bit little-endian word per line, matching
  `cpu/scripts/elf2hex.py` and the CPU testbenches.

## Limits

There is no dynamic linking, position-independent code, TLS, common
symbol merging, section garbage collection, or custom linker script.
Those features are not needed by the freestanding roco runtime, and
failing or omitting them is preferable to silently producing an image the
CPU cannot boot.
