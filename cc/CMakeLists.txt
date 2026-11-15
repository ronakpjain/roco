cmake_minimum_required(VERSION 3.20)
project(roco-cc LANGUAGES CXX)

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
)
target_include_directories(roco_core PUBLIC include PRIVATE src)
target_compile_definitions(roco_core PRIVATE
  ROCO_INCLUDE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/include/freestanding")
target_compile_options(roco_core PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wshadow)

add_executable(roco-as src/roco-as.cpp)
target_link_libraries(roco-as PRIVATE roco_core)
target_compile_options(roco-as PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wshadow)

add_executable(roco-ld src/roco-ld.cpp)
target_link_libraries(roco-ld PRIVATE roco_core)
target_compile_options(roco-ld PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wshadow)

add_executable(roco-cc src/roco-cc.cpp)
target_link_libraries(roco-cc PRIVATE roco_core)
target_compile_options(roco-cc PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wshadow)

enable_testing()
find_package(GTest REQUIRED)

add_executable(roco_tests
  tests/isa_test.cpp
  tests/elf_test.cpp
  tests/assembler_test.cpp
  tests/linker_test.cpp
  tests/compiler_test.cpp
)
target_link_libraries(roco_tests PRIVATE roco_core GTest::gtest_main)
target_include_directories(roco_tests PRIVATE include)
target_compile_options(roco_tests PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wshadow)

include(GoogleTest)
gtest_discover_tests(roco_tests)

# The CPU testbench lives in the sibling cpu/ tree. Run the complete
# assemble/link/execute path when both the simulator and image are present.
find_program(ROCO_VVP vvp)
set(ROCO_CPU_TESTBENCH
    "${CMAKE_CURRENT_SOURCE_DIR}/../cpu/build/tb_core.vvp"
    CACHE FILEPATH "roco core testbench used by the cpu_smoke test")
if(ROCO_VVP AND EXISTS "${ROCO_CPU_TESTBENCH}")
  add_test(NAME cpu_smoke
    COMMAND sh ${CMAKE_CURRENT_SOURCE_DIR}/tests/e2e/run.sh
            ${CMAKE_CURRENT_BINARY_DIR} ${CMAKE_CURRENT_SOURCE_DIR}
            $<TARGET_FILE:roco-as> $<TARGET_FILE:roco-ld>
            ${ROCO_VVP} ${ROCO_CPU_TESTBENCH})
  set_tests_properties(cpu_smoke PROPERTIES LABELS "cpu")

  add_test(NAME cpu_smoke_c
    COMMAND sh ${CMAKE_CURRENT_SOURCE_DIR}/tests/e2e/run-c.sh
            ${CMAKE_CURRENT_BINARY_DIR} ${CMAKE_CURRENT_SOURCE_DIR}
            $<TARGET_FILE:roco-cc> $<TARGET_FILE:roco-as> $<TARGET_FILE:roco-ld>
            ${ROCO_VVP} ${ROCO_CPU_TESTBENCH})
  set_tests_properties(cpu_smoke_c PROPERTIES LABELS "cpu")
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
