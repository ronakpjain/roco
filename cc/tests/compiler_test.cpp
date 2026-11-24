#include "roco/compiler.hpp"

#include "roco/assembler.hpp"
#include "roco/diagnostic.hpp"

#include <gtest/gtest.h>
#include <string>

namespace {

std::string compile(const std::string& source,
                     roco::OptimizationLevel level = roco::OptimizationLevel::O0) {
  roco::CompilerOptions options;
  options.optimization = level;
  return roco::compile_to_assembly(source, "test.c", options);
}

TEST(CompilerTest, CompilesReturnConstant) {
  const std::string assembly = compile("int main(void) { return 42; }\n");
  EXPECT_NE(assembly.find("main:"), std::string::npos);
  EXPECT_NE(assembly.find("li a0, 42"), std::string::npos);
  EXPECT_NE(assembly.find("ret"), std::string::npos);
}

TEST(CompilerTest, CompilesControlFlowAndFunctions) {
  const std::string source = R"(
    int add(int a, int b) { return a + b; }
    int main(void) {
      int sum = 0;
      for (int i = 0; i < 4; i++) {
        sum += add(i, 1);
      }
      while (sum > 10) {
        sum--;
      }
      if (sum == 10) {
        return 1;
      }
      return 0;
    }
  )";
  const std::string assembly = compile(source);
  EXPECT_NE(assembly.find("add:"), std::string::npos);
  EXPECT_NE(assembly.find("main:"), std::string::npos);
  EXPECT_NE(assembly.find("call add"), std::string::npos);
}

TEST(CompilerTest, CompilesTypesGlobalsArraysAndStrings) {
  const std::string source = R"(
    int value = 0x12345678;
    int folded = 1 + 2 * 3;
    int zero;
    char message[] = "roco";
    short half = 0x1234;
    unsigned char byte = 255;
    int *pointer = &value;
    int table[3] = {1, 2, 3};
    int main(void) {
      int local[4];
      local[0] = (int)sizeof(int);
      if (local[0] != 4) return 3;
      if (table[2] != 3) return 4;
      if (message[0] != 'r') return 5;
      if (half != 0x1234) return 6;
      if (byte != 255) return 7;
      if (*pointer != value) return 8;
      if (sizeof(short) != 2) return 9;
      return 0;
    }
  )";
  const std::string assembly = compile(source);
  EXPECT_NE(assembly.find("message:"), std::string::npos);
  EXPECT_NE(assembly.find(".word 7"), std::string::npos);
  EXPECT_NE(assembly.find("table:"), std::string::npos);
  EXPECT_NE(assembly.find("pointer:"), std::string::npos);
  EXPECT_NE(assembly.find("lh"), std::string::npos);
  EXPECT_NE(assembly.find("lbu"), std::string::npos);
  // The generated assembly must be accepted by the assembler.
  EXPECT_NO_THROW(roco::assemble(assembly, "compiler-output.S"));
}

TEST(CompilerTest, CompilesCasts) {
  const std::string assembly = compile(R"(
    int value = (int)0x1234;
    int main(void) {
      char c = (char)300;
      unsigned char u = (unsigned char)-1;
      int *p = (int *)&value;
      return (int)c + (int)u + *p;
    }
  )");
  EXPECT_NE(assembly.find(".word 4660"), std::string::npos);
  EXPECT_NE(assembly.find("andi a0, a0, 255"), std::string::npos);
  EXPECT_NO_THROW(roco::assemble(assembly, "compiler-output.S"));
}

TEST(CompilerTest, CompilesUnaryOperatorsAndShortInt) {
  const std::string assembly = compile(R"(
    int main(void) {
      short int value = 3;
      int a = 1;
      int b = +a;
      int c = ++a;
      int d = a++;
      return b + c + d + value;
    }
  )");
  EXPECT_NE(assembly.find("lh a0"), std::string::npos);
  EXPECT_NE(assembly.find("addi a0, a0, 1"), std::string::npos);
}


TEST(CompilerTest, FoldsNestedConstantsAtO1) {
  const char* source = "int main(void) { return (2 + 3) * 4; }\n";
  const std::string baseline = compile(source);
  const std::string optimized = compile(source, roco::OptimizationLevel::O1);
  EXPECT_NE(optimized.find("li a0, 20"), std::string::npos);
  EXPECT_EQ(baseline.find("li a0, 20"), std::string::npos);
  EXPECT_NO_THROW(roco::assemble(optimized, "compiler-output.S"));
}

TEST(CompilerTest, FoldsUnsignedConstantsWith32BitSemantics) {
  const std::string assembly = compile(R"(
    unsigned int wrap = 0xffffffffu + 1u;
    unsigned int half = 0xffffffffu / 2u;
    int compare = 0xffffffffu > 1u;
    int trunc = -7 / 2;
  )");
  EXPECT_NE(assembly.find(".word 0"), std::string::npos);
  EXPECT_NE(assembly.find(".word 2147483647"), std::string::npos);
  EXPECT_NE(assembly.find(".word 1"), std::string::npos);
  EXPECT_NE(assembly.find(".word -3"), std::string::npos);
}

TEST(CompilerTest, FoldsConstantConditionalsAtO1) {
  const std::string assembly = compile(R"(
    int main(void) {
      int value = 1;
      int dead = 0 ? (value = 2) : 3;
      return value + dead;
    }
  )", roco::OptimizationLevel::O1);
  EXPECT_NE(assembly.find("li a0, 3"), std::string::npos);
  EXPECT_NO_THROW(roco::assemble(assembly, "compiler-output.S"));
}


TEST(CompilerTest, LowersConditionsToDirectBranchesAtO1) {
  const char* source = R"(
    int test(int x, int y) {
      if (x < y) return 1;
      return 0;
    }
    int unsigned_test(unsigned int x) {
      if (x < 5u) return 1;
      return 0;
    }
  )";
  const std::string optimized = compile(source, roco::OptimizationLevel::O1);
  EXPECT_NE(optimized.find("bge a1, a0"), std::string::npos);
  EXPECT_NE(optimized.find("bgeu a0, a1"), std::string::npos);
  EXPECT_EQ(optimized.find("slt a0, a1, a0"), std::string::npos);
  EXPECT_NO_THROW(roco::assemble(optimized, "compiler-output.S"));
}

TEST(CompilerTest, RemovesConstantConditionalBranchesAtO1) {
  const char* source = R"(
    int main(void) {
      if (1 > 2) return 12345;
      return 6789;
    }
  )";
  const std::string baseline = compile(source);
  const std::string optimized = compile(source, roco::OptimizationLevel::O1);
  EXPECT_NE(baseline.find("li a0, 12345"), std::string::npos);
  EXPECT_EQ(optimized.find("li a0, 12345"), std::string::npos);
  EXPECT_NE(optimized.find("li a0, 6789"), std::string::npos);
}

TEST(CompilerTest, ShortCircuitsLogicalConditionsAtO1) {
  const std::string assembly = compile(R"(
    int both(int x, int y) {
      if (x != 0 && y != 0) return 7;
      return 0;
    }
  )", roco::OptimizationLevel::O1);
  EXPECT_EQ(assembly.find("snez a0, a0"), std::string::npos);
  EXPECT_NE(assembly.find("beq a0, zero"), std::string::npos);
  EXPECT_NO_THROW(roco::assemble(assembly, "compiler-output.S"));
}


TEST(CompilerTest, ScalesIndexesWithShiftsAtO1) {
  const std::string assembly = compile(R"(
    int get(int *p, int index) { return p[index]; }
    void put(int *p, int index, int value) { p[index] = value; }
  )", roco::OptimizationLevel::O1);
  EXPECT_NE(assembly.find("slli a0, a0, 2"), std::string::npos);
  EXPECT_EQ(assembly.find("li a1, 4\n  mul a0, a0, a1"),
            std::string::npos);
  EXPECT_NO_THROW(roco::assemble(assembly, "compiler-output.S"));
}

TEST(CompilerTest, FoldsConstantIndexesIntoLoadsAtO1) {
  const std::string assembly = compile(R"(
    int table[4];
    int get(int *p) { return p[3]; }
    int global(void) { return table[2]; }
    int local(void) {
      int values[4];
      return values[2];
    }
    int distance(int *p, int *q) { return p - q; }
  )", roco::OptimizationLevel::O1);
  EXPECT_NE(assembly.find("lw a0, 12(a0)"), std::string::npos);
  EXPECT_NE(assembly.find("la a0, table\n  lw a0, 8(a0)"),
            std::string::npos);
  EXPECT_NE(assembly.find("lw a0, -8(s0)"), std::string::npos);
  EXPECT_NE(assembly.find("srai a0, a0, 2"), std::string::npos);
  EXPECT_NO_THROW(roco::assemble(assembly, "compiler-output.S"));
}


TEST(CompilerTest, PassesMultidimensionalRowsByAddress) {
  const std::string source = R"(
    static char names[4][24];
    void put(char *p);
    void pass(unsigned i) { put(names[i]); }
    char *row(unsigned i) { return names[i]; }
    char *next(unsigned i) { return names[i] + 1; }
  )";
  const std::string assembly = compile(source);
  // Rows scale by their 24-byte size, and a row address is never loaded.
  EXPECT_NE(assembly.find("li a1, 24"), std::string::npos);
  EXPECT_EQ(assembly.find("lw a0, 0(a0)"), std::string::npos);
  EXPECT_EQ(assembly.find("lb a0, 0(a0)"), std::string::npos);
  EXPECT_NE(assembly.find("call put"), std::string::npos);
  EXPECT_NO_THROW(roco::assemble(assembly, "compiler-output.S"));
}

TEST(CompilerTest, IndexesMultidimensionalArraysByRow) {
  const std::string source = R"(
    static unsigned counts[3][8];
    unsigned get(unsigned i, unsigned j) { return counts[i][j]; }
    void set(unsigned i, unsigned j, unsigned value) { counts[i][j] = value; }
  )";
  const std::string assembly = compile(source);
  // Rows scale by 32 bytes, elements load and store as words.
  EXPECT_NE(assembly.find("li a1, 32"), std::string::npos);
  EXPECT_NE(assembly.find("lw a0, 0(a0)"), std::string::npos);
  EXPECT_NE(assembly.find("sw a0, 0(a1)"), std::string::npos);
  EXPECT_NO_THROW(roco::assemble(assembly, "compiler-output.S"));
}

TEST(CompilerTest, DropsDeadExpressionResultsAtO1) {
  const char* decrement = "int f(int x) { while (x) x--; return x; }\n";
  const char* discard = "int f(int x, int y) { x + y; return x; }\n";
  const char* postfix = "int f(int x) { int old = x++; return old + x; }\n";

  const std::string baseline = compile(decrement);
  const std::string optimized =
      compile(decrement, roco::OptimizationLevel::O1);
  EXPECT_NE(baseline.find("mv a2, a0"), std::string::npos);
  EXPECT_EQ(optimized.find("mv a2, a0"), std::string::npos);

  const std::string discard_baseline = compile(discard);
  const std::string discard_optimized =
      compile(discard, roco::OptimizationLevel::O1);
  EXPECT_NE(discard_baseline.find("add a0, a1, a0"), std::string::npos);
  EXPECT_EQ(discard_optimized.find("add a0, a1, a0"), std::string::npos);

  const std::string postfix_optimized =
      compile(postfix, roco::OptimizationLevel::O1);
  EXPECT_NE(postfix_optimized.find("mv a0, a2"), std::string::npos);
  EXPECT_NO_THROW(roco::assemble(optimized, "compiler-output.S"));
  EXPECT_NO_THROW(roco::assemble(discard_optimized, "compiler-output.S"));
  EXPECT_NO_THROW(roco::assemble(postfix_optimized, "compiler-output.S"));
}


TEST(CompilerTest, StrengthReducesConstantsAtO2) {
  const char* source = R"(
    int multiply(int x) { return x * 11; }
    int divide(int x) { return x / 4; }
    int remainder(int x) { return x % 4; }
    unsigned int udivide(unsigned int x) { return x / 8u; }
    unsigned int uremainder(unsigned int x) { return x % 8u; }
  )";
  const std::string baseline = compile(source, roco::OptimizationLevel::O1);
  const std::string optimized = compile(source, roco::OptimizationLevel::O2);
  EXPECT_NE(baseline.find("mul a0, a1, a0"), std::string::npos);
  EXPECT_EQ(optimized.find("mul a0, a1, a0"), std::string::npos);
  EXPECT_EQ(optimized.find("div a0, a1, a0"), std::string::npos);
  EXPECT_EQ(optimized.find("rem a0, a1, a0"), std::string::npos);
  EXPECT_NE(optimized.find("srai a1, a0, 31"), std::string::npos);
  EXPECT_NE(optimized.find("andi a0, a0, 3"), std::string::npos);
  EXPECT_NE(optimized.find("srli a0, a0, 3"), std::string::npos);
  EXPECT_NE(optimized.find("andi a0, a0, 7"), std::string::npos);
  EXPECT_NO_THROW(roco::assemble(optimized, "compiler-output.S"));
}

TEST(CompilerTest, UsesCostModelToChooseInstructionSequences) {
  const char* source = "int f(int x) { return (x * 11) + (x / 4); }\n";
  roco::CompilerOptions options;
  options.optimization = roco::OptimizationLevel::O2;

  options.costs.multiply = 1;
  options.costs.divide = 1;
  const std::string cheap =
      roco::compile_to_assembly(source, "cost.c", options);
  EXPECT_NE(cheap.find("mul a0, a1, a0"), std::string::npos);
  EXPECT_NE(cheap.find("div a0, a1, a0"), std::string::npos);

  options.costs.multiply = 2;
  options.costs.divide = 20;
  const std::string expensive =
      roco::compile_to_assembly(source, "cost.c", options);
  EXPECT_EQ(expensive.find("mul a0, a1, a0"), std::string::npos);
  EXPECT_EQ(expensive.find("div a0, a1, a0"), std::string::npos);
  EXPECT_NO_THROW(roco::assemble(expensive, "compiler-output.S"));
}


TEST(CompilerTest, MaterializesConstantCallArgumentsDirectlyAtO1) {
  const char* source = R"(
    int add(int a, int b) { return a + b; }
    int main(void) { return add(4, 5); }
  )";
  const std::string baseline = compile(source);
  const std::string optimized = compile(source, roco::OptimizationLevel::O1);
  EXPECT_NE(baseline.find("mv t1, a0"), std::string::npos);
  EXPECT_EQ(optimized.find("mv t1, a0"), std::string::npos);
  EXPECT_NE(optimized.find("li a0, 4"), std::string::npos);
  EXPECT_NE(optimized.find("li a1, 5"), std::string::npos);
  EXPECT_NO_THROW(roco::assemble(optimized, "compiler-output.S"));
}


TEST(CompilerTest, CanonicalizesConstantsToTheRightAtO1) {
  const char* source = R"(
    int multiply(int x) { return 3 * x; }
    int compare(int x) {
      if (5 > x) return 1;
      return 0;
    }
  )";
  const std::string optimized = compile(source, roco::OptimizationLevel::O1);
  EXPECT_NE(optimized.find("li a1, 5\n  bge a0, a1"),
            std::string::npos);
  const std::string strengthened =
      compile(source, roco::OptimizationLevel::O2);
  EXPECT_EQ(strengthened.find("mul a0, a1, a0"), std::string::npos);
  EXPECT_NE(strengthened.find("slli a1, a0, 1"), std::string::npos);
  EXPECT_NO_THROW(roco::assemble(strengthened, "compiler-output.S"));
}


TEST(CompilerTest, AppliesImmediateCompoundAssignmentsAtO1) {
  const char* source = R"(
    int add(int x) { x += 1; return x; }
    int scale(int x) { x *= 3; return x; }
    int divide(int x) { x /= 4; return x; }
  )";
  const std::string optimized = compile(source, roco::OptimizationLevel::O1);
  EXPECT_NE(optimized.find("addi a0, a0, 1"), std::string::npos);
  EXPECT_NO_THROW(roco::assemble(optimized, "compiler-output.S"));

  const std::string strengthened =
      compile(source, roco::OptimizationLevel::O2);
  EXPECT_EQ(strengthened.find("mul a0, a1, a0"), std::string::npos);
  EXPECT_EQ(strengthened.find("div a0, a1, a0"), std::string::npos);
  EXPECT_NO_THROW(roco::assemble(strengthened, "compiler-output.S"));
}

TEST(CompilerTest, ReportsUnsupportedConstructs) {
  EXPECT_THROW(compile("#include <stdio.h>\n"), roco::Error);
  EXPECT_THROW(compile("struct point { int x; };\n"), roco::Error);
  EXPECT_THROW(compile("int main(void) { return missing; }\n"), roco::Error);
  EXPECT_THROW(
      compile("int main(void) { char text[4] = \"roco\"; return 0; }\n"),
      roco::Error);
  EXPECT_THROW(compile("int f(int x, ...) { return x; }\n"), roco::Error);
}

}  // namespace

TEST(CompilerTest, PreprocessesMacrosAndConditionals) {
  const std::string assembly = compile(R"(
    #define BASE 7
    #define ADD(a, b) ((a) + (b))
    #if defined(BASE) && BASE == 7
    int value = ADD(BASE, 1);
    #else
    #error BASE is missing
    #endif
    int main(void) {
      return value;
    }
  )");
  EXPECT_NE(assembly.find(".word 8"), std::string::npos);
  EXPECT_NE(assembly.find("main:"), std::string::npos);
}

TEST(CompilerTest, SupportsTypedefsIncludesAndAttributes) {
  const std::string assembly = compile(R"(
    #include <stdint.h>
    typedef uint32_t word;
    __attribute__((noinline)) static word identity(word value) {
      return value;
    }
    int main(void) {
      word value = (word)-1;
      return (int)(identity(value) & 1u);
    }
  )");
  EXPECT_NE(assembly.find("identity:"), std::string::npos);
  EXPECT_NE(assembly.find("main:"), std::string::npos);
  EXPECT_NO_THROW(roco::assemble(assembly, "compiler-output.S"));
}

TEST(CompilerTest, RemovesUnusedStaticFunctions) {
  const std::string assembly = compile(R"(
    static int unused(void) { return 7; }
    static int used(void) { return 3; }
    int main(void) { return used(); }
  )");
  EXPECT_EQ(assembly.find("unused:"), std::string::npos);
  EXPECT_NE(assembly.find("used:"), std::string::npos);
  EXPECT_NE(assembly.find("call used"), std::string::npos);
}

TEST(CompilerTest, UsesImmediateAndDirectLocalForms) {
  const std::string assembly = compile(R"(
    int add_seven(int value) { return value + 7; }
    int bump(void) {
      int value = 1;
      value++;
      return value;
    }
  )");
  EXPECT_NE(assembly.find("addi a0, a0, 7"), std::string::npos);
  EXPECT_NE(assembly.find("sw a0,"), std::string::npos);
  EXPECT_EQ(assembly.find("mv t0, a0\n  lw a0"), std::string::npos);
}
