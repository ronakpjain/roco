#include "roco/compiler.hpp"
#include "roco/target.hpp"

#include "roco/diagnostic.hpp"

#include <gtest/gtest.h>

namespace {

TEST(TargetTest, UsesRocoDefaults) {
  const roco::CostModel costs = roco::default_cost_model();
  EXPECT_EQ(costs.issue, 1);
  EXPECT_EQ(costs.arithmetic, 1);
  EXPECT_EQ(costs.shift, 1);
  EXPECT_EQ(costs.compare, 1);
  EXPECT_EQ(costs.multiply, 2);
  EXPECT_EQ(costs.divide, 20);
  EXPECT_EQ(costs.load, 2);
  EXPECT_EQ(costs.store, 1);
  EXPECT_EQ(costs.branch, 1);
  EXPECT_EQ(costs.jump, 1);
}

TEST(TargetTest, ParsesCommentsAndOverrides) {
  const roco::CostModel costs = roco::parse_cost_model(R"(
    # roco pipeline costs
    multiply = 3
    divide=24
    shift = 1
    compare = 2
    jump = 3
  )");
  EXPECT_EQ(costs.multiply, 3);
  EXPECT_EQ(costs.divide, 24);
  EXPECT_EQ(costs.shift, 1);
  EXPECT_EQ(costs.compare, 2);
  EXPECT_EQ(costs.jump, 3);
  EXPECT_EQ(costs.arithmetic, 1);
}

TEST(TargetTest, RejectsMalformedAndUnknownEntries) {
  EXPECT_THROW(roco::parse_cost_model("multiply 2\n"), roco::Error);
  EXPECT_THROW(roco::parse_cost_model("multiply=-1\n"), roco::Error);
  EXPECT_THROW(roco::parse_cost_model("unknown=1\n"), roco::Error);
  roco::CostModel costs = roco::default_cost_model();
  EXPECT_FALSE(roco::set_cost(costs, "issue", 0));
  EXPECT_TRUE(roco::set_cost(costs, "divide", 32));
  EXPECT_EQ(costs.divide, 32);
}

TEST(TargetTest, CompilesAtEveryOptimizationLevel) {
  const char* source = "int main(void) { return 1 + 2 * 3; }\n";
  for (const roco::OptimizationLevel level :
       {roco::OptimizationLevel::O0, roco::OptimizationLevel::O1,
        roco::OptimizationLevel::O2}) {
    roco::CompilerOptions options;
    options.optimization = level;
    const std::string assembly =
        roco::compile_to_assembly(source, "levels.c", options);
    EXPECT_NE(assembly.find("main:"), std::string::npos)
        << roco::optimization_name(level);
  }
}

}  // namespace
