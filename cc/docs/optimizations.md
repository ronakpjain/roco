# Compiler optimizations

`roco_cc` keeps `-O0` as the direct, predictable lowering and adds two
opt-in levels. The levels deliberately separate "make the scalar code less
wasteful" from "change the instruction selected using this SoC's timing".

| Level | Purpose |
| --- | --- |
| `-O0` | Default. Stack-machine lowering with no new optimization pass. Hardware-directed tests use this level so the exact instruction under test is emitted. |
| `-O1` | Local scalar cleanups: constant folding, direct branches, better addresses, dead results, constant call arguments, local register allocation, and cache-aware global layout. |
| `-O2` | Everything in `-O1`, plus cost-model-driven instruction selection for constant multiply, divide, remainder, address scaling, and pointer differences. |

The pass order is frontend constant folding, then the existing single-pass
backend with the level's code-generation policy. Hot scalar locals are kept
in callee-saved registers; there is no global dataflow, loop transform, or
auto-vectorization yet.

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

### Local register allocation

At `-O1` and `-O2`, hot scalar locals are assigned to callee-saved `s2`-`s11`
registers. The frontend already has a stack slot for every local, so this is a
backend decision: arrays, address-taken locals, and `volatile` locals stay in
memory, and the rest are ranked by estimated cycle savings. Reads inside loops
are weighted more heavily than straight-line reads because they repeat. The
profitability estimate uses the target cost model: a register read avoids the
difference between load and ALU latency, while the function pays one store and
one load to save and restore the register.

Only the registers actually used are saved. The prologue and epilogue keep the
stack 16-byte aligned and save each `s2`-`s11` slot at `s0+16`, `s0+20`, and so
on. Locals in registers survive calls because every compiled callee preserves
the same registers.

The backend also uses register locals directly instead of copying them through
`a0`:

- `total += i` becomes one `add s3, s3, s2`.
- `i++` with an unused result becomes one `addi s2, s2, 1`.
- Comparisons branch on the registers directly, so `i < n` becomes `bge s2, s4, ...`.
- Commutative and non-commutative ALU operations use two register operands
  when both sides are locals.

```asm
# int sum(int n) { int total = 0; for (int i = 0; i < n; i++) total += i; return total; }
# -O2
.L1:
  bge s2, s4, .L3
  add s3, s3, s2
.L2:
  addi s2, s2, 1
  j .L1
```

### Cache-aware global layout and coherence

The roco D-cache is 4 KiB, 128 lines of 32 bytes, direct-mapped, blocking,
write-back, and write-allocate. Every fill is exclusive and probes the peer
cache, so two objects on one line can cause avoidable coherence traffic between
harts. At `-O1` and `-O2`, global arrays and `volatile` objects are aligned to
the target's `data_cache_line` (32 bytes by default). This keeps likely shared
or row-structured objects from sharing a line with an unrelated object.
`volatile` locals are never register-allocated, so every source-level access
remains a memory access.

The compiler does not cache ordinary globals in registers and does not reorder
memory, so a shared object remains visible through the same cache/coherence
rules as hand-written assembly. Function and loop `.p2align` padding was also
measured against the 16-byte I-cache and rejected: the extra fetch lines cost
more cycles than the alignment saved.

## `-O2` cost-model instruction selection

`-O2` compares the hardware multiply/divide sequence with a generated
shift/add or bias sequence. Every candidate, including its fallback, is
scored instruction by instruction:

```text
cost = sum(issue for result instructions, occupancy for store/branch/jump)
     + sum(max(0, result_latency - issue) for result instructions)
```

Pseudo-instructions are weighted by their expansion: `li` costs one slot
when its value is a 12-bit immediate or a 20-bit `lui` constant, and two
otherwise; `la` costs two. Instructions without a register result use their
occupancy cost: `store`, `branch`, or `jump`. An empty sequence costs zero.

The fallback is context-specific. A general constant binary operation
includes the two temporary-stack moves around the right operand, while
address scaling already has the value in `a0` and only needs `li` + `mul`.
That difference matters: scaling by 12 ties at the default multiply cost and
keeps `mul`, but a general `x * 12` has enough stack-move overhead that the
shift/add form wins. A candidate is emitted only when its score is strictly
lower than its actual fallback.

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

### Address scaling

Array indexing reuses the constant-multiply selector, but scores it against
the two-instruction `li` + `mul` fallback rather than the temporary-stack
fallback of a general binary expression. Power-of-two scales still lower to
one shift at `-O1`; at `-O2` the model can keep the hardware multiply when
its score is not worse.

```asm
# int row(int a[][12], int i) { return a[i][0]; }   -O2, multiply=2
  li a1, 48
  mul a0, a0, a1

# -O2, multiply=3
  slli a1, a0, 5
  slli a0, a0, 4
  add a0, a0, a1            # 48 * i
```

### Pointer differences

The element-size division after `p - q` is selected from the same model.
For power-of-two element sizes the candidate is one arithmetic shift; the
fallback is `li` + `div`. If the model prices a shift above the divider,
the compiler keeps `div` instead.

```asm
# int distance(int *a, int *b) { return a - b; }   -O2, default costs
  sub a0, a1, a0
  srai a0, a0, 2

# -O2, shift=100 divide=1
  sub a0, a1, a0
  li a1, 4
  div a0, a0, a1
```

## Target cost model

The defaults live in
[`targets/roco_soc.costs`](../targets/roco_soc.costs):

| Key | Default | Meaning |
| --- | --- | --- |
| `issue` | 1 | Cycles between independent instructions |
| `arithmetic` | 1 | Single-cycle ALU result latency |
| `shift` | 1 | Shift/bitwise result latency |
| `compare` | 1 | Comparison result latency (`slt`, `snez`, ...) |
| `multiply` | 2 | `mul` dependent-result latency (one EX/MEM bubble) |
| `divide` | 20 | Iterative radix-four divider dependent-result latency |
| `load` | 2 | Cache-hit load latency, including the load-use bubble |
| `store` | 1 | Store pipeline occupancy |
| `branch` | 1 | Conditional-branch occupancy/redirect |
| `jump` | 1 | Unconditional jump/call occupancy/redirect |
| `data_cache_line` | 32 | D-cache line size used for cache-aware global layout |

All instruction values participate in sequence scoring. `compare` distinguishes
comparison results from plain ALU results. `load` also charges the load-use
bubble when a spilled temporary is reloaded immediately before the hardware
operation, and `store` charges the spill itself. `branch` and `jump` are
used for control-flow instructions, which have no register result.

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

Cycle count is the primary compiler benchmark; retired instructions are only
diagnostic. Register allocation can add a few prologue instructions while
removing dependent load latency, so code size and retired count do not track
runtime.

| Workload | `-O0` cycles | `-O1` cycles | `-O2` cycles | `-O2` retired |
| --- | ---: | ---: | ---: | ---: |
| `tests/e2e/main.c` | 599 | 374 | 374 | 228 |
| `tests/e2e/features.c` | 4974 | 2854 | 2672 | 2049 |
| `tests/e2e/optimized.c` | 6515 | 5453 | 5150 | 3050 |

OS images built with the kernel and filesystem at `-O2`:

| Image | Before this work | Current | Change |
| --- | ---: | ---: | ---: |
| default UART boot | 9,998,813 cycles | 8,183,091 cycles | -18.2% |
| console/rootfs workload | 60,462,477 cycles | 49,623,767 cycles | -17.9% |

`-O1` now provides the bulk of the runtime improvement through local register
allocation and direct register operands. `-O2` adds the arithmetic
instruction-selection changes and is verified separately by
`tests/e2e/optimized.c`, which also executes pointer differences and a
non-power-of-two `char[][3]` row scale.

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
  constant-folding rules, cost-model parsing, local register allocation,
  volatile and address-taken memory storage, cache-line global alignment, and
  that cost overrides can switch instruction selection between shift/add and
  `mul`/`div`, including address scaling and pointer differences.
