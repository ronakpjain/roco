# Compiler optimizations

`roco_cc` keeps `-O0` as the direct, predictable lowering and adds two
opt-in levels. The levels deliberately separate "make the scalar code less
wasteful" from "change the instruction selected using this SoC's timing".

| Level | Purpose |
| --- | --- |
| `-O0` | Default. Stack-machine lowering with no new optimization pass. Hardware-directed tests use this level so the exact instruction under test is emitted. |
| `-O1` | Local scalar cleanups: constant folding, direct branches, better addresses, dead results, and constant call arguments. |
| `-O2` | Everything in `-O1`, plus cost-model-driven instruction selection for constant multiply, divide, and remainder. |

The pass order is frontend constant folding, then the existing single-pass
backend with the level's code-generation policy. There is no register
allocator, global dataflow, loop transform, or auto-vectorization yet.

## `-O1` optimizations

### Constant folding with 32-bit C semantics

All expression trees are folded when they are compile-time constants, not
only global initializers. Evaluation uses 32-bit wrapping, signed/unsigned
comparison rules, truncated `char`/`short` casts, signed division truncation,
and hardware shift-count masking. Constant `?:` arms and constant comma
left operands are removed so dead side effects disappear before codegen.

```asm
# int h(void) { return (2 + 3) * 4; }   -O0
  li a0, 2
  addi a0, a0, 3
  mv t0, a0
  li a0, 4
  mv a1, t0
  mul a0, a1, a0

# -O1
  li a0, 20
```

### Canonical operand order

Commutative operators are rewritten so a constant operand sits on the
right. Relational comparisons are flipped instead (`5 > x` becomes
`x < 5`), and pointer addition is left alone because its scaling depends on
which side is the pointer. This exposes immediate forms, constant call
arguments, and the `-O2` constant-multiply path.

```asm
# return 3 * x;   -O1/-O2 rewrite

# if (5 > x) ...  -O1
  li a1, 5
  bge a0, a1, .L4       # branch when x >= 5
```

### Direct condition branches

`if`, `while`, `do`/`while`, `for`, `?:`, `&&`, and `||` branch on
comparisons directly instead of materializing a 0/1 result and branching on
it. Signed and unsigned compare forms are chosen from the operand types.
Constant conditions remove the branch and the dead arm.

```asm
# if (x < y) ...   -O0
  slt a0, a1, a0
  beqz a0, .L2

# -O1
  bge a1, a0, .L2       # branch when x >= y
```

### Address and index lowering

- Index scaling by 1, 2, 4, or another power of two becomes a shift instead
  of `li` + `mul`.
- A constant index is multiplied at compile time and folded into the base
  address or load/store displacement.
- `a[2]` on a local array becomes one `lw`/`sw` with an `s0` displacement.
- A constant global-array index becomes `la` plus a displaced load/store.
- Pointer subtraction by a power-of-two element size uses an arithmetic
  shift because the byte difference is an exact multiple.

```asm
# s += p[i];   -O0
  li a1, 4
  mul a0, a0, a1

# -O1
  slli a0, a0, 2
```

### Dead expression results

Expression results that are discarded no longer materialize post-increment
old values, convert `char`/`short` results that are never read, or perform a
dead arithmetic operation after evaluating both operands. Side effects,
loads, stores, calls, and short-circuit control flow are preserved.

```asm
# for (...; i++)   -O0
  lw a0, -16(s0)
  mv a2, a0
  addi a0, a0, 1
  sw a0, -16(s0)
  mv a0, a2
  j .L4

# -O1
  lw a0, -16(s0)
  addi a0, a0, 1
  sw a0, -16(s0)
  j .L4
```

### Immediate compound assignments

Compound assignments with a constant right operand load the destination
once and use the same immediate/strength-reduced selection as a plain
binary expression. This covers `+=`, `-=`, shifts, bitwise operations,
`*=`, `/=`, and `%=`; pointer `+=`/`-=` scale the constant at compile time.
If the operation has no cheap immediate form, the backend still falls back
from the loaded value without reloading it.

```asm
# x += 1;   -O0
  li a0, 1
  mv a2, a0
  lw a1, -4(s0)
  mv a0, a2
  add a0, a1, a0
  sw a0, -4(s0)

# -O1
  lw a0, -4(s0)
  addi a0, a0, 1
  sw a0, -4(s0)
```

### Constant call arguments

Constant arguments are materialized directly in their ABI argument
registers after the non-constant arguments have been evaluated. They no
longer take a temporary-stack round trip.

```asm
# add(4, 5)   -O0
  li a0, 4
  mv t1, a0
  li a0, 5
  mv t2, a0
  mv a1, t2
  mv a0, t1

# -O1
  li a1, 5
  li a0, 4
```

## `-O2` cost-model instruction selection

`-O2` compares the hardware multiply/divide sequence with a generated
shift/add or bias sequence. Each candidate has a score:

```text
cost = instructions * issue + max(0, final_latency - issue)
```

The fallback cost includes the two temporary-stack moves around the
constant right operand, the cost of materializing the constant, and the
final `mul`/`div` latency. The shift sequence is emitted only when its score
is strictly lower.

### Constant multiply

The backend considers powers of two, `2^a ± 2^b` forms, three-bit sums, and
a generic binary shift/add chain. It keeps the shortest-cost form.

```asm
# x * 11   -O1
  li a0, 11
  mv a1, t0
  mul a0, a1, a0

# -O2
  slli a1, a0, 3
  slli a2, a0, 1
  add a1, a1, a2
  add a0, a1, a0          # 8x + 2x + x
```

### Constant divide and remainder

- Unsigned power-of-two division becomes `srli`; remainder becomes `andi`
  or `li` + `and` for masks wider than 12 bits.
- Signed power-of-two division uses the standard sign-bias sequence
  `srai`/`srli`/`add`/`srai`; a negative divisor adds a final `neg`.
- Signed power-of-two remainder uses the bias, an `and` mask, and a final
  `sub`.
- Division by `±1` becomes no-op/`neg`; remainder by `±1` becomes `li 0`.
- Non-power-of-two constant division stays on the hardware divider.

```asm
# x / 4   -O1
  li a0, 4
  mv a1, t0
  div a0, a1, a0

# -O2
  srai a1, a0, 31
  srli a1, a1, 30
  add a0, a0, a1
  srai a0, a0, 2
```

```asm
# x % 4   -O2
  srai a1, a0, 31
  srli a1, a1, 30
  add a0, a0, a1
  andi a0, a0, 3
  sub a0, a0, a1
```

## Target cost model

The defaults live in
[`targets/roco_soc.costs`](../targets/roco_soc.costs):

| Key | Default | Meaning |
| --- | --- | --- |
| `issue` | 1 | Cost of issuing one additional instruction |
| `arithmetic` | 1 | Single-cycle ALU result latency |
| `shift` | 1 | Shift/bitwise result latency |
| `multiply` | 2 | `mul` dependent-result latency (one EX/MEM bubble) |
| `divide` | 20 | Iterative radix-four divider dependent-result latency |
| `load` | 2 | Cache-hit load latency |
| `store` | 1 | Store latency |
| `branch` | 1 | Conditional-branch latency |

`multiply`, `divide`, `shift`, `arithmetic`, and `issue` currently score
instruction sequences. `load`, `store`, and `branch` record the rest of the
pipeline and are available for future memory and branch scheduling.

The file is intentionally external to the compiler so it can change with
the SoC:

```bash
roco_cc -O2 --cost-model targets/roco_soc.costs -S -o program.s program.c
roco_cc -O2 --cost multiply=3 --cost divide=24 -S -o program.s program.c
```

The file format is one `key=value` per line; blank lines and `#` comments
are ignored. For example, if the divider is shortened, lower `divide` and
more constant divisions will remain on the hardware divider because its
score wins.

## Measured effect

These are Icarus `soc/build/tb_core.vvp` runs with `+measure_execution` and
`+trace`. Retired counts are deterministic instructions; cycles include
startup and memory stalls, so they are not frequency claims.

| Workload | `-O0` retired | `-O2` retired | `-O0` cycles | `-O2` cycles |
| --- | ---: | ---: | ---: | ---: |
| `tests/e2e/main.c` | 321 | 279 | 599 | 551 |
| `tests/e2e/features.c` | 626 | 518 | 1279 | 1066 |
| `tests/e2e/optimized.c` | 3518 | 3162 | 6301 | 5623 |
| `soc/sw/vector/main.c` | 9045 | 7490 | 15431 | 13596 |

`-O1` produces most of the code-size benefit; `-O2` adds the arithmetic
instruction-selection changes and is verified separately by
`tests/e2e/optimized.c`.

## Test policy

- The SoC Makefile defines `ROCO_CCFLAGS ?= -O0`, so directed hardware
  tests keep the exact unoptimized instruction pattern. Override it for an
  optimized run:

  ```bash
  make test_vector_c ROCO_CCFLAGS=-O2
  ```

- `roco_cc` itself defaults to `-O0` even when invoked outside the SoC
  Makefile.
- `cpu_smoke_c` runs the C end-to-end test at `-O0`;
  `cpu_smoke_c_o2` runs the same sources plus `optimized.c` at `-O2`
  against the real core testbench.
- Unit tests check the exact assembly shapes for each level, the 32-bit
  constant-folding rules, cost-model parsing, and that cost overrides can
  switch instruction selection back to `mul`/`div`.
