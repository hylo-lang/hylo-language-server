# Cross-compilation fidelity (no cross C toolchain needed): the target triple
# reaches every hc command line, Hylo_TARGET_TRIPLE beats the
# CMAKE_C_COMPILER_TARGET default, and the object hc emits is really for the
# target architecture (ELF e_machine, checked with pure CMake).  Execution
# under qemu is the cross-aarch64 CI job's business.  Ninja only (the
# build.ninja grep and single-object build).
include("${CMAKE_CURRENT_LIST_DIR}/Harness.cmake")
fixture_create(diamond)

fixture_configure(ARGS "-DHylo_TARGET_TRIPLE=aarch64-unknown-linux-gnu")
file(READ "${WORK_DIR}/build/build.ninja" _ninja)
assert_contains("${_ninja}" "--target aarch64-unknown-linux-gnu"
  "the triple must reach the hc command lines")
file(READ "${WORK_DIR}/build/hylo-project.json" _manifest)
string(JSON _target GET "${_manifest}" target)
if(NOT _target STREQUAL "aarch64-unknown-linux-gnu")
  message(FATAL_ERROR "the manifest must name the target triple, got '${_target}'")
endif()

# Build just the Hylo object (the host C toolchain cannot link aarch64).
# MAKE_PROGRAM, not a PATH lookup: it is the ninja the fixture was configured
# with, which an IDE may have supplied off PATH.
set(_obj "diamond/CMakeFiles/Base.hylo.dir/Base${HYLO_OBJ_EXT}")
execute_process(
  COMMAND "${MAKE_PROGRAM}" -C "${WORK_DIR}/build" "${_obj}"
  RESULT_VARIABLE _r OUTPUT_VARIABLE _o ERROR_VARIABLE _e)
if(NOT _r EQUAL 0)
  message(FATAL_ERROR "cross object build failed (${_r}):\n${_o}\n${_e}")
endif()

# ELF header: magic, 64-bit class, e_machine (offset 18, little endian) 0xB7 =
# AArch64.
file(READ "${WORK_DIR}/build/${_obj}" _hdr LIMIT 20 HEX)
if(NOT _hdr MATCHES "^7f454c4602")
  message(FATAL_ERROR "Base.o is not a 64-bit ELF object (header ${_hdr})")
endif()
string(SUBSTRING "${_hdr}" 36 4 _machine)
if(NOT _machine STREQUAL "b700")
  message(FATAL_ERROR "Base.o e_machine is ${_machine}, expected b700 (AArch64)")
endif()

# The CMAKE_C_COMPILER_TARGET default: used when Hylo_TARGET_TRIPLE is unset...
# CMAKE_TRY_COMPILE_TARGET_TYPE: clang-based hosts honour the target during
# the C ABI check and then cannot link host binaries; compiling to a static
# library sidesteps the link.
fixture_configure(BUILD_DIR "${WORK_DIR}/build-default"
  ARGS "-DCMAKE_C_COMPILER_TARGET=aarch64-unknown-linux-gnu"
       "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY")
file(READ "${WORK_DIR}/build-default/build.ninja" _ninja)
assert_contains("${_ninja}" "--target aarch64-unknown-linux-gnu"
  "CMAKE_C_COMPILER_TARGET must become the default triple")

# ...and beaten by an explicit Hylo_TARGET_TRIPLE.
fixture_configure(BUILD_DIR "${WORK_DIR}/build-override"
  ARGS "-DCMAKE_C_COMPILER_TARGET=aarch64-unknown-linux-gnu"
       "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY"
       "-DHylo_TARGET_TRIPLE=armv5te-unknown-linux-gnueabi")
file(READ "${WORK_DIR}/build-override/build.ninja" _ninja)
assert_contains("${_ninja}" "--target armv5te-unknown-linux-gnueabi"
  "an explicit Hylo_TARGET_TRIPLE must win")
assert_not_contains("${_ninja}" "--target aarch64" "the default must not also apply")
