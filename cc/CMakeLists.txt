cmake_minimum_required(VERSION 3.20)
project(roco_cc LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

add_library(roco_core
  src/isa.cpp
  src/elf/writer.cpp
  src/elf/reader.cpp
  src/assembler.cpp
  src/linker.cpp
  src/compiler.cpp
  src/compiler/token.cpp
  src/target.cpp
)
target_include_directories(roco_core PUBLIC include PRIVATE src)
target_compile_definitions(roco_core PRIVATE
  ROCO_INCLUDE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/include/freestanding")
target_compile_options(roco_core PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wshadow)

add_executable(roco_as src/roco_as.cpp)
target_link_libraries(roco_as PRIVATE roco_core)
target_compile_options(roco_as PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wshadow)

add_executable(roco_ld src/roco_ld.cpp)
target_link_libraries(roco_ld PRIVATE roco_core)
target_compile_options(roco_ld PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wshadow)

add_executable(roco_cc src/roco_cc.cpp)
target_link_libraries(roco_cc PRIVATE roco_core)
target_compile_options(roco_cc PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wshadow)

enable_testing()
find_package(GTest REQUIRED)

add_executable(roco_tests
  tests/isa_test.cpp
  tests/elf_test.cpp
  tests/assembler_test.cpp
  tests/linker_test.cpp
  tests/compiler_test.cpp
  tests/target_test.cpp
)
target_link_libraries(roco_tests PRIVATE roco_core GTest::gtest_main)
target_include_directories(roco_tests PRIVATE include)
target_compile_options(roco_tests PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wshadow)

include(GoogleTest)
gtest_discover_tests(roco_tests)

# The CPU testbench lives in the sibling soc/ tree. Run the complete
# assemble/link/execute path when both the simulator and image are present.
find_program(ROCO_VVP vvp)
set(ROCO_CPU_TESTBENCH
    "${CMAKE_CURRENT_SOURCE_DIR}/../soc/build/tb_core.vvp"
    CACHE FILEPATH "roco core testbench used by the cpu_smoke test")
if(ROCO_VVP AND EXISTS "${ROCO_CPU_TESTBENCH}")
  add_test(NAME cpu_smoke
    COMMAND sh ${CMAKE_CURRENT_SOURCE_DIR}/tests/e2e/run.sh
            ${CMAKE_CURRENT_BINARY_DIR} ${CMAKE_CURRENT_SOURCE_DIR}
            $<TARGET_FILE:roco_as> $<TARGET_FILE:roco_ld>
            ${ROCO_VVP} ${ROCO_CPU_TESTBENCH})
  set_tests_properties(cpu_smoke PROPERTIES LABELS "cpu")

  add_test(NAME cpu_smoke_c
    COMMAND sh ${CMAKE_CURRENT_SOURCE_DIR}/tests/e2e/run_c.sh
            ${CMAKE_CURRENT_BINARY_DIR} ${CMAKE_CURRENT_SOURCE_DIR}
            $<TARGET_FILE:roco_cc> $<TARGET_FILE:roco_as> $<TARGET_FILE:roco_ld>
            ${ROCO_VVP} ${ROCO_CPU_TESTBENCH})
  set_tests_properties(cpu_smoke_c PROPERTIES LABELS "cpu")

  add_test(NAME cpu_smoke_c_o2
    COMMAND sh ${CMAKE_CURRENT_SOURCE_DIR}/tests/e2e/run_c.sh
            ${CMAKE_CURRENT_BINARY_DIR} ${CMAKE_CURRENT_SOURCE_DIR}
            $<TARGET_FILE:roco_cc> $<TARGET_FILE:roco_as> $<TARGET_FILE:roco_ld>
            ${ROCO_VVP} ${ROCO_CPU_TESTBENCH} -O2)
  set_tests_properties(cpu_smoke_c_o2 PROPERTIES LABELS "cpu")

  add_custom_target(cycles
    COMMAND sh ${CMAKE_CURRENT_SOURCE_DIR}/tests/e2e/bench_cycles.sh
            ${CMAKE_CURRENT_BINARY_DIR} ${CMAKE_CURRENT_SOURCE_DIR}
            $<TARGET_FILE:roco_cc> $<TARGET_FILE:roco_as> $<TARGET_FILE:roco_ld>
            ${ROCO_VVP} ${ROCO_CPU_TESTBENCH}
    DEPENDS roco_cc roco_as roco_ld
    COMMENT "Reporting C end-to-end cycle counts"
    VERBATIM)
endif()

option(ROCO_BUILD_DOCS "Generate HTML documentation with Doxygen" ON)
if(ROCO_BUILD_DOCS)
  find_package(Doxygen QUIET)
  if(Doxygen_FOUND)
    add_custom_target(docs
      COMMAND ${DOXYGEN_EXECUTABLE} ${PROJECT_SOURCE_DIR}/Doxyfile
      WORKING_DIRECTORY ${PROJECT_SOURCE_DIR}
      COMMENT "Generating roco toolchain HTML documentation"
      VERBATIM
    )
  else()
    message(STATUS "Doxygen not found; the docs target is unavailable")
  endif()
endif()
