# Hardware notes

These are implementation behaviors in `../cpu/rtl` that the toolchain
must account for. They are observations from reading the RTL and its
directed tests, not changes to the ISA specification.

## `vmv.v.v` reads the wrong source field

The standard encoding of `vmv.v.v vd, vs1` places the source in the
`rs1` field (`instr[19:15]`). `rtl/core/rv32_ex_stage.sv` selects
`vec_vs2_data` (`instr[24:20]`) for the `.vv` move when
`vec_funct6 == RV32_VOP_MOVE` and `funct3 == 0`.

Consequences:

- The assembler emits the standard encoding, so standard tools and the
  toolchain agree on the instruction word.
- The current RTL will copy `v0` rather than the requested source for
  `vmv.v.v`.
- The compiler must not emit `vmv.v.v` until the RTL is fixed. Use
  `vmv.v.i`, `vmv.v.x`, or scalar moves instead.
- The existing directed vector tests do not cover this form.

## Atomics ignore ordering bits

`rtl/core/rv32_decoder.sv` accepts `lr.w`, `sc.w`, and `amo*.w` but does
not decode the `aq`/`rl` bits into control state. With one hart and no
other bus masters in the current SoC, that is unobservable in practice,
but it is not a full RV32A memory-model implementation. The assembler
still accepts `.aq`, `.rl`, and `.aqrl` suffixes and encodes the standard
bits.

## Vector configuration

- VLEN is fixed at 128 bits.
- LMUL is fixed at m1; other values are not implemented.
- SEW is limited to 8, 16, and 32.
- `vstart` is readable/writable as a CSR but is not used to resume vector
  execution (`unused_vstart` in `rv32_ex_stage.sv`).
- `vma` is stored but masking is absent, so `ma`/`mu` have no effect.
- `vta` is implemented for vector arithmetic tails.

## Vector memory

Only unmasked unit-stride 8/16/32-bit accesses are decoded. They move one
element per cycle through the normal D-cache path. Strided, indexed,
segment, and whole-register forms trap as illegal. The assembler rejects
them and rejects masks and offsets for these forms.

## Vector reductions

`vredsum.vs` is the only reduction. The RTL adds lanes in SEW-wide
arithmetic and zero-extends the low 32-bit result into element 0. It does
not sign-extend a signed SEW result into the scalar width and it does not
preserve a tail in the destination in the way a full vector
implementation would. The compiler should treat it as an unsigned
modulo-SEW sum unless the RTL is corrected.

## Other limits

- `fence` is a no-op; `fence.i` flushes the D-cache and invalidates the
  I-cache.
- `sfence.vma` always flushes both TLBs; ASID and address operands are
  decoded but ignored.
- `mtvec` supports direct mode only.
- A/D bits are software-managed.
- Branch mispredict recovery and cache behavior are microarchitectural;
  they do not change the instruction encoding contract.

## Toolchain policy

The assembler emits standard encodings for every accepted form. It
rejects unsupported forms with a diagnostic. The compiler should avoid
the affected `vmv.v.v` form and should not depend on `aq`/`rl` ordering,
`vma`, `vstart`, or signed vector reductions on the current RTL.
