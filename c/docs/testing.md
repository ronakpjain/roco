# Testing

Tests use GoogleTest and require no simulator. They cover the encoder,
the ELF object layer, and assembler behavior; the linker and compiler will
add their own suites.

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

Assembler tests check exact machine words against LLVM `llvm-mc` encodings
for the supported forms, including the roco vector subset. Rejection tests
cover unsupported vector configurations, masked operations, 64-bit
atomics, bad immediates, duplicate labels, and unresolved local symbols.

## CPU integration

The toolchain is not yet wired into the CPU simulation. The planned
end-to-end check is:

1. assemble startup code and a small program with `roco-as`;
2. link with `roco-ld`;
3. emit a word image;
4. run `cpu/build/tb_core.vvp +hex=...` and require `PASS`.

That test will live outside the GoogleTest binary because it needs the
CPU simulator, but it will use the same object and linker APIs.

## Documentation

```bash
cmake --build build --target docs
```

The generated HTML lands in `docs/html/index.html`. Doxygen warnings are
written to `docs/doxygen-warnings.log`; the build intentionally does not
fail on warnings so local documentation work stays fast.
