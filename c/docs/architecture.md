# Architecture

The toolchain is split into small libraries so each stage can be tested
without spawning another process. The command-line programs are thin
drivers around `roco::assemble_file`, `roco::elf::encode_object`, and the
linker once it exists.

```text
source.c
├── Preprocessor   includes, macros, conditionals
├── Lexer          tokens, comments, strings
├── Parser         declarations, expressions, control flow
└── Codegen        RV32IM assembly

source.S
├── Lexer          tokens, comments, strings, numeric local labels
├── Parser         sections, symbols, directives, instructions
├── Encoder        RV32 + roco vector subset words
├── Relocations    resolved local labels or deferred symbols
└── Object         sections, symbols, relocation records
    └── ELF writer -> .o

.o files
└── ELF reader -> linker -> .elf / .bin / .hex
```

## Compiler

The C frontend builds a small typed AST. The parser resolves local and
global names while parsing, records array and pointer types, and rejects
constructs outside the supported subset. The backend is a stack machine:
expressions leave a result in `a0`, `s0` addresses the frame, and `s1`
points at a compiler-managed temporary stack for nested expressions and
call arguments.

The generated assembly is ordinary text consumed by the same assembler
and linker as hand-written programs. There is no compiler-specific object
format or runtime. See the [compiler reference](compiler.md).

## Object model

`roco::Object` is deliberately independent of the on-disk ELF layout.

- **Section** owns a name, type, flags, alignment, bytes, and relocation
  records. `.bss` uses a size instead of bytes.
- **Symbol** stores a name, binding, type, value, and an in-memory section
  index. The first symbol is always the ELF null symbol.
- **Relocation** names a byte offset, relocation kind, symbol index, and
  addend. The assembler emits RELA records; there is no implicit addend
  path.

The ELF writer converts in-memory section indices into ELF section-header
indices and emits `.rela.*` sections only when needed. The reader reverses
that mapping, skipping metadata sections while preserving relocatable
sections and their relocation records.

## Assembler

`roco-as` performs one pass over the token stream. Forward references are
legal because instruction immediates are emitted as zero and patched by a
relocation, not because the assembler performs a second layout pass.

Labels become local symbols unless `.globl` or `.global` marks them.
Undefined names that do not start with `.L` are promoted to global
symbols at finalization so that cross-object calls and data references
resolve without an explicit `.extern` directive. Undefined `.L` labels
are an error.

Numeric local labels (`1:`, `1b`, `1f`) use generated `.Lnum.*` symbols.
Backward references bind to the most recent definition. Forward
references share a placeholder until the next definition of that number,
which lets repeated forward references target the same label.

The assembler rejects relative branches that are not representable, odd
branch or jump offsets, unaligned data, unsupported system registers, and
vector forms outside the roco subset. It never emits compressed
instructions.

## Relocations

The assembler currently emits these relocation kinds:

| Relocation | Producer |
| --- | --- |
| `R_RISCV_32` | `.word symbol` |
| `R_RISCV_BRANCH` | conditional branches to symbols |
| `R_RISCV_JAL` | `j`, `jal`, `call`, `tail` |
| `R_RISCV_HI20` / `LO12_I` / `LO12_S` | `%hi`, `%lo` |
| `R_RISCV_PCREL_HI20` | `la`, `auipc` with a symbol |
| `R_RISCV_PCREL_LO12_I/S` | `%pcrel_lo` markers |

The linker applies the standard two's-complement split for HI20/LO12
pairs and range-checks branches and jumps. Linker relaxation is
intentionally disabled: fixed instruction sizes keep the implementation
and the debug story simple, and roco has no instruction-fetch throughput
problem that requires relaxation. See the [linker reference](linker.md).

## Target coupling

The tools target the roco RTL, not a generic RV32 profile. The
instruction tables include M, A, Zicsr, Zifencei, and only the vector
operations implemented by `rtl/core/rv32_vec*.sv`. The linker default
load address is the SDRAM base at `0x1000_0000`, matching the boot
protocol and the existing `cpu/sw/link.ld` layout.

The toolchain does not assume Linux, virtual memory, an F/D unit,
compressed instructions, or linker relaxation. Programs are freestanding
and use the standard RV32 ILP32 calling convention.
