# roco c

A C toolchain for the roco RV32 CPU in `../cpu`, written from scratch
in C++20. The host programs build with a normal desktop compiler;
everything they emit targets the FPGA CPU. No binutils, GCC runtime, or
external assembler is required.

```text
hello.c   -> roco-cc -> hello.s
hello.s   -> roco-as -> hello.o
hello.o   -> roco-ld -> hello.elf + hello.bin + hello.hex
```

## Status

| Component | State |
| --- | --- |
| RV32 instruction encoder | complete |
| `roco-as` assembler | RV32IMA, Zicsr, Zifencei, and roco's vector subset |
| ELF32 objects | reader and writer complete |
| `roco-ld` linker | fixed-layout ELF executable, binary, and hex output |
| `roco-cc` C compiler | preprocessor, typedefs, types, pointers, arrays, functions, control flow |

The assembler accepts the standard RV32 encodings and rejects instructions
the roco RTL does not implement. See the [target profile](docs/target.md)
for the exact support boundary and RTL behavior.

## Build

Requires CMake 3.20+, a C++20 compiler, and system GoogleTest for tests.
Doxygen is optional and only needed for documentation.

```bash
cmake -S . -B build
cmake --build build
ctest --test-dir build --output-on-failure
cmake --build build --target docs   # docs/html/index.html
```

On macOS: `brew install googletest doxygen`.

## Usage

```bash
./build/roco-cc -E -o hello.i hello.c   # preprocessed source
./build/roco-cc -S -o hello.s hello.c
./build/roco-as -o hello.o hello.s
./build/roco-ld -o hello.elf --hex hello.hex hello.o
```

The assembler accepts labels, numeric local labels, data directives,
pseudoinstructions, ELF sections, and the relocation forms needed by the
compiler. See the [compiler reference](docs/compiler.md), the
[assembler reference](docs/assembler.md), and the
[linker reference](docs/linker.md).

## Layout

| Path | Contents |
| --- | --- |
| `include/roco/` | public object, ELF, ISA, and assembler interfaces |
| `src/compiler/` | C lexer, parser, types, AST, and code generator |
| `src/assembler/` | assembly lexer, instruction table, sections, and parser |
| `src/elf/` | ELF32 reader and writer |
| `src/linker/` | linker layout, symbols, and relocations |
| `src/` | public entry points and command-line drivers |
| `tests/` | GoogleTest unit tests |
| `docs/` | architecture, target, assembler, linker, hardware, and testing notes |
| `Doxyfile` | documentation build |

## Design

The pipeline keeps a narrow, inspectable object format between stages:

1. The assembler parses one source file into sections, symbols, and
   relocations.
2. The ELF writer emits a standard ELF32 little-endian RISC-V object.
3. The linker resolves symbols, applies relocations, places sections at the
   roco SDRAM load address, and emits ELF, flat, and hex images.

The assembler does not silently accept unsupported instructions or
relocations. Unimplemented vector forms and 64-bit atomics fail with a
diagnostic instead of producing code that traps on hardware.

See [architecture](docs/architecture.md) for the component view and
[testing](docs/testing.md) for the verification strategy.
