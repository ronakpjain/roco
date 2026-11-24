#pragma once

/// @file target.hpp
/// @brief Optimization levels and the configurable roco instruction costs.

#include <string>
#include <string_view>

namespace roco {

/** @brief Optimization level selected with `-O0`, `-O1`, or `-O2`.
 *
 * `O0` preserves the direct stack-machine lowering. `O1` enables local
 * scalar cleanups. `O2` additionally uses the target cost model to choose
 * between hardware multiply/divide and cheaper shift/add sequences.
 */
enum class OptimizationLevel { O0 = 0, O1 = 1, O2 = 2 };

/** @brief Relative instruction costs used by `-O2` instruction selection.
 *
 * The values are dependent-result latencies in cycles for the roco SoC.
 * Independent instructions continue to issue while a multi-cycle operation
 * is in flight. The compiler scores a candidate sequence instruction by
 * instruction, charging the issue interval for every instruction and the
 * extra result latency of every instruction that produces a register value.
 * Instructions without a result (`store`, conditional `branch`, and `jump`)
 * are charged their pipeline occupancy instead. Keeping these values in a
 * file makes it possible to retarget the compiler when the pipeline changes
 * without editing the backend.
 */
struct CostModel {
  /// Cycles between independent instructions (pipeline issue interval).
  int issue = 1;
  /// Result latency of a single-cycle integer ALU operation.
  int arithmetic = 1;
  /// Result latency of a shift or bitwise immediate operation.
  int shift = 1;
  /// Dependent-result latency of `mul` (one pipeline bubble on roco).
  int multiply = 2;
  /// Dependent-result latency of `div`/`rem` (iterative radix-four divider).
  int divide = 20;
  /// Dependent-result latency of a cache-hit load, including the load-use
  /// bubble that follows it.
  int load = 2;
  /// Pipeline occupancy of a store.
  int store = 1;
  /// Pipeline occupancy of a conditional branch.
  int branch = 1;
  /// Result latency of a comparison such as `slt` or `snez`.
  int compare = 1;
  /// Pipeline occupancy of an unconditional jump or call.
  int jump = 1;
};

/** @brief Return the roco defaults for the cost model. */
CostModel default_cost_model();

/** @brief Parse `key=value` cost entries, one per line.
 *
 * Blank lines and `#` comments are ignored. Unknown keys or malformed
 * values throw `roco::Error` with a source name and line number.
 *
 * @param text Cost file text.
 * @param source_name Name used in diagnostics.
 * @return Parsed model, starting from the roco defaults.
 */
CostModel parse_cost_model(std::string_view text,
                           const std::string& source_name = "<costs>");

/** @brief Read and parse a cost model file.
 *  @param path Filesystem path of the cost file.
 *  @return Parsed model.
 *  @throws roco::Error if the file cannot be read or parsed.
 */
CostModel load_cost_model(const std::string& path);

/** @brief Apply one `name=value` override to a cost model.
 *  @param costs Model to update.
 *  @param name Cost key such as `multiply` or `divide`.
 *  @param value Non-negative latency or issue cost.
 *  @return False if the key is unknown or the value is invalid.
 */
bool set_cost(CostModel& costs, std::string_view name, int value);

/** @brief Compiler options shared by the C frontend and backend. */
struct CompilerOptions {
  /// Optimization level. The default remains the direct `-O0` lowering.
  OptimizationLevel optimization = OptimizationLevel::O0;
  /// Target costs used by `-O2` instruction selection.
  CostModel costs = default_cost_model();
};

/** @brief Return the command-line spelling of an optimization level. */
const char* optimization_name(OptimizationLevel level);

}  // namespace roco
