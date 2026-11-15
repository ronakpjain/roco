# Assembler reference

`roco-as` turns one RISC-V assembly source file into an ELF32
little-endian relocatable object.

```bash
roco-as -o program.o program.S
```

The output defaults to the input name with a `.o` extension. Diagnostics
include the source path, line, and column.

## Syntax

- Labels: `name:` and numeric local labels `1:`.
- Local references: `1b` for the previous `1:`, `1f` for the next.
- Comments: `#`, `//`, and `/* ... */`.
- Statements are line-oriented; one instruction or directive per line.
- Registers may use ABI names (`sp`, `a0`, `t6`) or `xN`/`vN` names.

## Directives

| Directive | Meaning |
| --- | --- |
| `.text`, `.data`, `.rodata`, `.bss` | select a standard section |
| `.section name[, "flags"][, @type]` | select or create a section |
| `.globl` / `.global` | export one or more symbols |
| `.local` | keep a symbol local |
| `.type symbol, @function` | record a symbol type |
| `.equ` / `.set` | define an absolute symbol |
| `.align n` | align to `n` bytes |
| `.p2align n` | align to `2^n` bytes |
| `.balign n` | align to `n` bytes |
| `.macro name[, args]` / `.endm` | define a macro; `\arg` and `\@` substitute |
| `.rept n` / `.endr` | repeat the enclosed block `n` times |
| `.byte`, `.half`, `.word` | emit 8-, 16-, or 32-bit values |
| `.ascii`, `.asciz`, `.string` | emit string bytes; `.asciz` appends NUL |
| `.zero`, `.space`, `.skip` | reserve zero-filled bytes |
| `.size`, `.file`, `.ident`, `.option`, `.attribute` | accepted metadata |

Section flags use the usual characters: `a` alloc, `w` write, `x`
execute. `.rodata`, `.data`, and `.bss` variants infer sensible defaults.
Unknown directives are errors.

## Pseudoinstructions

The assembler expands:

`nop`, `mv`, `not`, `neg`, `li`, `la`, `j`, `jr`, `ret`, `call`, `tail`,
`beqz`, `bnez`, `bltz`, `bgez`, `blez`, `bgtz`, `bgt`, `ble`, `bgtu`,
`bleu`, `csrr`, `csrw`, `csrs`, `csrc`, `csrwi`, `csrsi`, `csrci`.

The raw CSR forms `csrrw`, `csrrs`, `csrrc`, `csrrwi`, `csrrsi`, and
`csrrci` are also accepted.

`call` and `tail` use `JAL` with `ra`/`zero`; the linker resolves the
target. `la` uses absolute `HI20` + `LO12_I` relocations for a
fixed-address image.

## Relocations

Use `%hi(symbol)` and `%lo(symbol)` with `lui`/`auipc` and
load/store/immediate instructions. `%pcrel_hi` and `%pcrel_lo` are
recognized for standard PC-relative sequences. A symbol in a `.word`
emits `R_RISCV_32`.

Branch targets must be symbols or PC-relative numeric offsets. Numeric
offsets must be even and within the architectural range.

## roco restrictions

The assembler accepts only the instructions the roco RTL implements.
Notably:

- no compressed (`c.*`) instructions or `.option rvc`;
- no floating-point instructions;
- atomics are `.w` only (`lr.w`, `sc.w`, `amo*.w`);
- vector configuration is limited to `e8`/`e16`/`e32` and `m1`;
- vector memory operations are unit-stride and unmasked;
- unsupported vector arithmetic is rejected.

See the [target profile](target.md).

## Example

```asm
.section .text.init
.globl _start

_start:
  li sp, 0x100f0000
  la a0, message
  call puts
  li t0, 0x80001000
  li t1, 1
  sw t1, 0(t0)
1:
  j 1b

.section .rodata
message:
  .asciz "hello, roco\n"
```
