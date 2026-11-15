#include "roco/compiler.hpp"

#include "roco/assembler.hpp"
#include "roco/diagnostic.hpp"

#include <gtest/gtest.h>
#include <string>

namespace {

std::string compile(const std::string& source) {
  return roco::compile_to_assembly(source, "test.c");
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
