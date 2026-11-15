# roco C toolchain

A self-hosted-in-design C toolchain for the roco RV32 CPU. The host
programs are C++20; everything they consume and produce is for RV32.

Target instruction set: RV32IMA plus Zicsr and Zifencei. Objects use the
standard ELF32 little-endian RISC-V ABI so the tools can be validated
against standard RISC-V assemblers and disassemblers.

```text
hello.c   -> roco-cc -> hello.s
hello.s   -> roco-as -> hello.o
hello.o   -> roco-ld -> hello.elf + hello.bin + hello.hex
```

Current status:

- RV32 instruction encoder and CSR/register tables.
- Assembler and linker are under construction.

## Build

GoogleTest is the only test dependency.

```sh
cmake -S . -B build
cmake --build build
ctest --test-dir build --output-on-failure
```

On macOS: `brew install googletest`.
