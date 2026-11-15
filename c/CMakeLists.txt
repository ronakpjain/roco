cmake_minimum_required(VERSION 3.20)
project(roco_toolchain LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

add_library(roco_core src/isa.cpp src/elf.cpp src/assembler.cpp)
target_include_directories(roco_core PUBLIC include)
target_compile_options(roco_core PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wshadow)

add_executable(roco-as src/roco-as.cpp)
target_link_libraries(roco-as PRIVATE roco_core)
target_compile_options(roco-as PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wshadow)

enable_testing()
find_package(GTest REQUIRED)

add_executable(roco_tests tests/isa_test.cpp tests/elf_test.cpp tests/assembler_test.cpp)
target_link_libraries(roco_tests PRIVATE roco_core GTest::gtest_main)
target_include_directories(roco_tests PRIVATE include)
target_compile_options(roco_tests PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wshadow)

include(GoogleTest)
gtest_discover_tests(roco_tests)
