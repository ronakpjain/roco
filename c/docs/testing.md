# Testing

Tests use GoogleTest and require no simulator. They cover the encoder,
the ELF object layer, assembler behavior, and linker placement and
relocation handling. The compiler will add its own suite.

```bash
cmake -S . -B build
cmake --build build
ctest --test-dir build --output-on-failure
```

## Current coverage

| Suite | Focus |
| --- | --- |
| `isa_test` | register/CSR parsing, encodings, immediate patching, ranges |
| `elf_test` | object round trips, executable program headers, malformed input |
| `assembler_test` | instructions, pseudoinstructions, labels, data, atomics, vectors, errors |
| `linker_test` | cross-object symbols, absolute and PC-relative relocations, bss bounds, call pairs, errors |

Assembler tests check exact machine words against LLVM `llvm-mc` encodings
for the supported forms, including the roco vector subset. Rejection tests
cover unsupported vector configurations, masked operations, 64-bit
atomics, bad immediates, duplicate labels, and unresolved local symbols.

## CPU integration

The `tests/e2e` program exercises startup, `.bss` clearing, loads,
stores, branches, and the `tohost` halt path through the real core
testbench. The sequence is:

1. assemble `start.S` and `main.S` with `roco-as`;
2. link with `roco-ld` and emit a word image;
3. run `cpu/build/tb_core.vvp +hex=...` and require `PASS`.

The check is enabled in CTest when `vvp` and the core testbench are
available; otherwise it is skipped. This keeps GoogleTest simulator-free
while still validating the complete toolchain against the RTL.

## Documentation

```bash
cmake --build build --target docs
```

The generated HTML lands in `docs/html/index.html`. Doxygen warnings are
written to `docs/doxygen-warnings.log`; the build intentionally does not
fail on warnings so local documentation work stays fast.
