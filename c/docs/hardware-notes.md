# Hardware notes

This page records two things about `../cpu/rtl`: defects where behavior
differs from the ISA, and deliberate implementation limits. The supported
assembly boundary is summarized in the [target profile](target.md).

## `vmv.v.v` reads the wrong source field

The standard encoding of `vmv.v.v vd, vs1` places the source in the
`rs1` field (`instr[19:15]`). `rtl/core/rv32_ex_stage.sv` selects
`vec_vs2_data` (`instr[24:20]`) for the `.vv` move when
`vec_funct6 == RV32_VOP_MOVE` and `funct3 == 0`.

The assembler emits the standard encoding, so the current RTL copies
`v0` rather than the requested source. The compiler must not emit
`vmv.v.v` until this is fixed; use `vmv.v.i`, `vmv.v.x`, or scalar moves
instead. The existing directed vector tests do not cover this form.

## Atomics ignore ordering bits

`rtl/core/rv32_decoder.sv` accepts `lr.w`, `sc.w`, and `amo*.w` but does
not propagate the `aq`/`rl` bits into any control state. With one hart
and no other bus masters this is not observable in current programs, but
it is not a correct RV32A implementation. The assembler still encodes the
standard bits.

## `vstart` does not restart vector instructions

`vstart` is readable and writable through the CSR file, but
`rv32_ex_stage.sv` connects it to `unused_vstart` and vector execution
always starts at element zero. Software that writes `vstart` and reissues
an instruction will repeat already completed elements instead of
resuming.

## `vredsum.vs` does not follow the reduction result layout

`rv32_ex_stage.sv` writes the reduction result across the active lanes:
element 0 receives the sum, elements 1 through `vl-1` are zeroed, and
lanes at and beyond `vl` follow the tail policy. The ISA defines only
element 0 as the reduction result; the remaining elements must follow the
tail policy. The reduction itself is SEW-wide modulo addition.

## Implementation limits

These are not defects. They are deliberate subsets or simplified behavior
that toolchain code must respect.

### Instruction set

- RV32I, M, A (`lr`/`sc`/`amo` `.w` only), Zicsr, and Zifencei. There are
  no compressed, floating-point, or vector instructions beyond the subset
  below.
- `WFI` is not decoded. It traps as an illegal instruction.
- Misaligned loads and stores trap; hardware does not split them. The C
  backend keeps declared objects naturally aligned. Hand-written code must
  not form misaligned `int`, `short`, or pointer accesses.
- `FENCE` is a no-op. `FENCE.I` writes back the D-cache and invalidates the
  I-cache.

### Vector subset

- VLEN is 128 bits.
- LMUL is m1 only.
- SEW is 8, 16, or 32 only.
- Only element-wise add/sub/and/or/xor, moves, `vredsum.vs`, and
  unit-stride 8/16/32-bit loads/stores are implemented.
- Masked operations are illegal. `vma` is stored in `vtype` but has no
  effect because no masked operation exists.
- Strided, indexed, segment, and whole-register memory operations are
  illegal.
- The only reductions are `vredsum.vs`.

### Privilege and memory

- `mtvec` supports direct mode only.
- Interrupts are delivered by the core; there is no software interrupt
  injection beyond the existing CSR state.
- Sv32 supports 4 KiB pages and 4 MiB superpages. A/D bits are
  software-managed; a PTE with A=0, or D=0 for a store, faults.
- TLBs are tagged by virtual page and are flushed completely by `satp`
  writes or `SFENCE.VMA`. ASID selection and address-specific flushes are
  not implemented; operands are decoded but ignored.
- Page tables must live in the SDRAM window. Physical PPN bits 21:20 are
  zero.
- `FENCE.I` and `SFENCE.VMA` flush the whole D-cache before invalidating
  caches/TLBs. There is no cache coherence and no DMA master.
- PMP, the debug module, and hardware A/D updates are not implemented.

## Toolchain response

`roco-as` emits standard encodings for accepted instructions and rejects
forms the RTL cannot execute. The current C backend does not auto-vectorize
and does not use atomics, so normal compiled C is unaffected by these
defects. Hand-written vector or atomic code must account for them.
