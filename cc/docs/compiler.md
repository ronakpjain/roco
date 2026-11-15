# C compiler

`roco-cc` compiles a freestanding C subset to RV32 assembly or directly
to an ELF object. The backend emits instructions accepted by `roco-as`
and uses the standard RV32 ILP32 integer calling convention.

```bash
roco-cc -E -o program.i program.c   # preprocessed C
roco-cc -S -o program.s program.c   # assembly
roco-cc -c -o program.o program.c   # ELF relocatable object
```

`roco-cc` does not link. Use `roco-ld` with the startup object and any
runtime objects, or use the `cpu_smoke_c` test as an end-to-end example.

## Supported language

| Area | Support |
| --- | --- |
| Preprocessor | `#include`, object/function `#define`, `#undef`, `#if`/`#ifdef`/`#ifndef`/`#elif`/`#else`/`#endif`, `#pragma`, `#error` |
| Types | `void`, `char`, `short`, `int`, `long`; signed and unsigned variants; file-scope `typedef` aliases; pointers; arrays |
| Qualifiers | `const`, `volatile`, `restrict` parsed and ignored; `__attribute__((...))` ignored |
| Declarations | globals, locals, functions, prototypes, multiple declarators |
| Headers | quoted includes search the source directory; angled includes search the freestanding `include/freestanding` directory |
| Initializers | scalar globals, array brace lists, string arrays, pointer-to-symbol/string globals |
| Statements | compound, expression, `return`, `if`/`else`, `while`, `do`/`while`, `for`, `break`, `continue` |
| Expressions | assignment and compound assignment, casts, `?:`, `||`, `&&`, bitwise, equality, relational, shifts, `+ - * / %`, unary `+ - ! ~ & *`, pre/post `++`/`--`, `sizeof`, calls, subscripts |
| Functions | direct calls, up to eight arguments, recursion |
| Literals | integer, character, adjacent string literal concatenation |

Local scalar initializers are supported. Local arrays may be declared
and indexed but brace-initialized local arrays are not implemented.

## Not supported yet

- `struct`, `union`, `enum`, `_Bool`;
- inline assembly (`__asm__`); use a small assembly helper instead;
- function pointers;
- `switch`, `goto`, labels;
- floating point and 64-bit integer types;
- local `static` storage and `extern` declarations inside functions;
- variadic function definitions (`...` is accepted in prototypes only);
- more than eight call arguments or parameters;
- global scalar initializers that are not link-time constants.

Unsupported syntax fails with a source location; it is not silently
lowered to something else.

## Code generation

Expressions use a simple accumulator plus a temporary stack:

- `a0` is the expression result and first argument;
- `a1`-`a7` carry additional call arguments;
- `s0` is the frame pointer;
- `s1` is a compiler-managed temporary stack pointer.

Each function reserves a 16-byte save area, a frame for locals, and a
1 KiB fallback temporary area. `sp` stays 16-byte aligned at calls.
Expressions use `t0`-`t6` as a small temporary stack; values spill to the
memory temporary only beyond seven live operands or around calls.
Arguments are evaluated left to right and popped into `a0`-`a7` in reverse
order before the call. A single argument already in `a0` is passed
directly.

Codegen also performs these local optimizations:

- only static functions reachable from a non-static entry point are emitted;
- constant right operands use `addi`/`andi`/`ori`/`xori`, shifts, and
  `slti`/`sltiu` instead of a temporary;
- scalar local loads and stores use `s0`-relative offsets directly;
- local increments and compound assignments update their slots without
  first materializing an address;
- pointer and array index scaling uses immediate shifts where possible.

The backend does not use compressed instructions, floating point, or
vector instructions yet. The assembler and linker support roco's vector
subset independently, so a later backend can target it without changing
objects or relocation handling.

## Frontend structure

| File | Purpose |
| --- | --- |
| `src/compiler/token.hpp`, `token.cpp` | tokens and keyword classification |
| `src/compiler/preprocessor.hpp` | includes, macros, and conditional compilation |
| `src/compiler/lexer.hpp` | C lexer |
| `src/compiler/types.hpp` | type objects and conversions |
| `src/compiler/ast.hpp` | declarations, statements, expressions |
| `src/compiler/parser.hpp` | recursive-descent parser and semantic checks |
| `src/compiler/codegen.hpp` | RV32 assembly backend |
| `src/compiler.cpp` | public compile entry points |

## Verification

GoogleTest checks assembly shape, generated code that must assemble,
preprocessing, typedefs, casts, control flow, globals, arrays, strings,
and diagnostics. The
`cpu_smoke_c` CTest compiles a C program, assembles and links it, and
runs it on the real core testbench. It passes only when the program
writes `1` to the `tohost` register.
