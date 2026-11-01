#[=======================================================================[.rst:
FindHylo
--------

Finds the Hylo compiler (``hc``) and provides commands for building Hylo
modules with CMake.

Hylo is integrated as a *participant* in a CMake build, not as a CMake
language: each Hylo module is compiled by one custom command (``hc`` compiles a
whole module at once), and the resulting object is linked by CMake's ordinary C
link rules.  This keeps the integration on documented, stable CMake features
only -- no ``CMakeDetermine<LANG>Compiler`` internals -- and gives Ninja real
multi-output compile edges with ``restat``, which is what makes the compiler's
interface hash useful for pruning dependent rebuilds.  See ``README.md`` next
to this file for the design rationale.

Usage::

  list(APPEND CMAKE_MODULE_PATH "<this-directory>")
  find_package(Hylo 0.0.8 REQUIRED)

  hylo_add_library(Support SOURCES Support.hylo Extra.hylo)
  hylo_add_executable(app SOURCES main.hylo)
  target_link_libraries(app PRIVATE Support)   # links AND imports the module

Commands (see ``HyloTargets.cmake`` for the full documentation)::

  hylo_add_library(<target> [STATIC|SHARED|MODULE] [EXCLUDE_FROM_ALL]
                   [MODULE_NAME <name>] [NO_RUNTIME] [SOURCES] <source>...)
  hylo_add_executable(<target> [EXCLUDE_FROM_ALL] [MODULE_NAME <name>]
                      [NO_RUNTIME] [SOURCES] <source>...)
  hylo_target_module(<existing-target> [MODULE_NAME <name>] [NO_RUNTIME])
  hylo_target_compile_options(<target> <PRIVATE|PUBLIC|INTERFACE> <option>...)
  hylo_install_module(<target> [DESTINATION <dir>] [COMPONENT <component>])

Result variables::

  Hylo_FOUND            True if hc was found and compiles a trivial module.
  Hylo_VERSION          Numeric version reported by ``hc --version`` (unset for
                        ``development`` builds of the compiler).
  Hylo_VERSION_STRING   Raw output of ``hc --version``.
  Hylo_COMPILER         Path to hc.  (cache; may be preset)
  Hylo_STDLIB_ROOT      Root of the standard library sources; requeried from
                        hc on every configure unless overridden (see below).
  Hylo_STDLIB_SHIMS     The standard library's C shim, ``shims.c``.

Imported / provided targets::

  Hylo::hc              The compiler, as an IMPORTED executable.
  Hylo::Runtime         What every Hylo program must link: the standard
                        library's C shims (compiled once, as a static library)
                        and libm where it is separate.

Configuration variables (all cache entries, advanced)::

  Hylo_COMPILER         Override the compiler.  Also honoured as hints:
                        ``$ENV{HC}``, ``Hylo_ROOT`` / ``$ENV{HYLO_ROOT}``,
                        then ``PATH``.
  Hylo_FLAGS            Flags for every hc compile (string, like CMAKE_C_FLAGS).
  Hylo_FLAGS_<CONFIG>   Per-configuration flags; defaults: Debug "",
                        Release/RelWithDebInfo/MinSizeRel "-O".
  Hylo_STDLIB_ROOT      Override the standard library root instead of asking
                        hc for it (empty: query on every configure).
  Hylo_MODULE_CACHE_DIR Where hc caches the compiled standard library.  Defaults
                        to a directory inside the build tree so builds are
                        hermetic and do not share state with other toolchains.
                        Set to an empty string to use hc's own default.
  Hylo_TARGET_TRIPLE    Passed as ``hc --target``.  Defaults to
                        ``CMAKE_C_COMPILER_TARGET`` when that is set (experimental).
  Hylo_PROJECT_MANIFEST Path of the LSP-facing ``hylo-project.json`` written at
                        generate time (default ``${CMAKE_BINARY_DIR}/hylo-project.json``;
                        empty disables it).  Under a multi-config generator, one
                        manifest per configuration, in a ``<config>`` directory
                        next to the file name.

Requires CMake 3.30 (custom transitive target properties).
#]=======================================================================]

if(CMAKE_VERSION VERSION_LESS 3.30)
  message(FATAL_ERROR "FindHylo requires CMake 3.30 or newer. Running CMake ${CMAKE_VERSION}.")
endif()

cmake_policy(PUSH)
cmake_policy(VERSION 3.30)

include(FindPackageHandleStandardArgs)

# ---------------------------------------------------------------------------
# 1. Locate the compiler.
# ---------------------------------------------------------------------------

# A cached compiler that has since been moved, rebuilt elsewhere or deleted
# would be used forever and fail deep inside the build; forget it and search
# again (starting with the hints below), so a build directory survives its
# toolchain being replaced.
if(Hylo_COMPILER AND NOT EXISTS "${Hylo_COMPILER}")
  if(NOT Hylo_FIND_QUIETLY)
    message(STATUS "Hylo: the compiler this build was configured with is gone "
      "(${Hylo_COMPILER}); searching for another one")
  endif()
  unset(Hylo_COMPILER CACHE)
endif()

if(NOT Hylo_COMPILER AND DEFINED ENV{HC} AND NOT "$ENV{HC}" STREQUAL "")
  set(Hylo_COMPILER "$ENV{HC}" CACHE FILEPATH "Hylo compiler (hc)")
endif()

find_program(Hylo_COMPILER
  NAMES hc
  HINTS "${Hylo_ROOT}" ENV HYLO_ROOT
  PATH_SUFFIXES bin
  DOC "Hylo compiler (hc)")
mark_as_advanced(Hylo_COMPILER)

# Everything below needs the compiler; without it, let FPHSA report the failure.
if(Hylo_COMPILER AND EXISTS "${Hylo_COMPILER}")

  # -------------------------------------------------------------------------
  # 2. Query it: version and standard library location.
  # -------------------------------------------------------------------------
  execute_process(
    COMMAND "${Hylo_COMPILER}" --version
    OUTPUT_VARIABLE Hylo_VERSION_STRING
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
    RESULT_VARIABLE _hylo_version_result)
  if(NOT _hylo_version_result EQUAL 0)
    set(Hylo_VERSION_STRING "")
  endif()
  # "0.0.8" for releases, "development" for local builds of hylo-new.
  if(Hylo_VERSION_STRING MATCHES "^v?([0-9]+(\\.[0-9]+)*)")
    set(Hylo_VERSION "${CMAKE_MATCH_1}")
  else()
    unset(Hylo_VERSION)
  endif()

  # The standard library's location is baked into the compiler at build time
  # (a resource bundle for distributed builds, a source path for local ones), so
  # the compiler is the only thing that can report it.  The cache entry is an
  # ordinary knob, empty by default like Hylo_MODULE_CACHE_DIR and
  # Hylo_TARGET_TRIPLE: set it to override the query -- the escape hatch for a
  # compiler that misreports its own layout.  When empty, hc is requeried on
  # every configure, like --version above, into a normal variable shadowing the
  # cache entry: the answer belongs to the compiler that gave it, and caching
  # it would go stale when the toolchain is replaced (behaviour.toolchain-swap).
  set(Hylo_STDLIB_ROOT "" CACHE PATH
    "Root of the Hylo standard library's sources (empty: ask hc)")
  mark_as_advanced(Hylo_STDLIB_ROOT)
  if(Hylo_STDLIB_ROOT)
    if(NOT Hylo_FIND_QUIETLY)
      message(STATUS "Hylo: standard library root overridden: ${Hylo_STDLIB_ROOT}")
    endif()
  else()
    execute_process(
      COMMAND "${Hylo_COMPILER}" --print-stdlib-root
      OUTPUT_VARIABLE _hylo_stdlib_root
      OUTPUT_STRIP_TRAILING_WHITESPACE
      ERROR_VARIABLE _hylo_stdlib_root_error
      RESULT_VARIABLE _hylo_stdlib_root_result)
    if(_hylo_stdlib_root_result EQUAL 0 AND IS_DIRECTORY "${_hylo_stdlib_root}")
      set(Hylo_STDLIB_ROOT "${_hylo_stdlib_root}")
    elseif(NOT Hylo_FIND_QUIETLY)
      message(STATUS "Hylo: '${Hylo_COMPILER} --print-stdlib-root' failed: ${_hylo_stdlib_root_error}")
    endif()
  endif()

  # shims.c implements the @extern_c_indirect functions the standard library
  # declares (c_malloc_indirect, c_free_indirect).  `hc --emit binary` compiles
  # and links it automatically; anyone linking Hylo objects themselves -- i.e.
  # any build system -- has to supply it.  We compile it once (Hylo::Runtime).
  # The root is the stdlib bundle (hc >= 0.0.8, hylo-new#523): sources and
  # shims.c under Sources/, Generated.hylo at the root.  Older compilers
  # reported the Sources directory instead and are not supported.
  if(Hylo_STDLIB_ROOT AND EXISTS "${Hylo_STDLIB_ROOT}/Sources/shims.c")
    set(Hylo_STDLIB_SHIMS "${Hylo_STDLIB_ROOT}/Sources/shims.c"
      CACHE INTERNAL "The Hylo standard library's C shim source")
  else()
    # Leaving it empty makes the check below report an unusable compiler,
    # rather than letting the runtime target fail on a missing source file.
    set(Hylo_STDLIB_SHIMS "" CACHE INTERNAL "The Hylo standard library's C shim source")
    if(Hylo_STDLIB_ROOT AND NOT Hylo_FIND_QUIETLY)
      message(STATUS "Hylo: no Sources/shims.c under the standard library "
        "${Hylo_COMPILER} reports (${Hylo_STDLIB_ROOT}); hc 0.0.8 or newer is "
        "required (older compilers lay out the standard library differently)")
    endif()
  endif()

  # -------------------------------------------------------------------------
  # 3. Configuration knobs.
  # -------------------------------------------------------------------------
  set(Hylo_FLAGS "" CACHE STRING "Flags used by the Hylo compiler during all build types")
  set(Hylo_FLAGS_DEBUG "" CACHE STRING "Flags used by the Hylo compiler during DEBUG builds")
  set(Hylo_FLAGS_RELEASE "-O" CACHE STRING "Flags used by the Hylo compiler during RELEASE builds")
  set(Hylo_FLAGS_RELWITHDEBINFO "-O" CACHE STRING "Flags used by the Hylo compiler during RELWITHDEBINFO builds")
  set(Hylo_FLAGS_MINSIZEREL "-O" CACHE STRING "Flags used by the Hylo compiler during MINSIZEREL builds")
  mark_as_advanced(Hylo_FLAGS Hylo_FLAGS_DEBUG Hylo_FLAGS_RELEASE
    Hylo_FLAGS_RELWITHDEBINFO Hylo_FLAGS_MINSIZEREL)

  # hc caches the compiled standard library (Hylo.hylomodule) in a module cache.
  # Its default is a per-user directory shared by every hc on the machine; two
  # compiler versions then fight over one archive.  A cache inside the build
  # tree is hermetic, and warming it costs well under a second (measured 0.9s
  # cold vs 0.3s warm for a trivial module with hc 0.0.6).  The compiler check
  # below warms it at configure time, before parallel compiles could race on it.
  set(Hylo_MODULE_CACHE_DIR "${CMAKE_BINARY_DIR}/CMakeFiles/hylo-module-cache"
    CACHE PATH "Module cache used by the Hylo compiler (empty: hc's default)")
  mark_as_advanced(Hylo_MODULE_CACHE_DIR)

  if(NOT DEFINED Hylo_TARGET_TRIPLE AND CMAKE_C_COMPILER_TARGET)
    set(Hylo_TARGET_TRIPLE "${CMAKE_C_COMPILER_TARGET}")
  endif()
  set(Hylo_TARGET_TRIPLE "${Hylo_TARGET_TRIPLE}" CACHE STRING
    "Target triple passed to hc --target (empty: host)")
  mark_as_advanced(Hylo_TARGET_TRIPLE)

  set(Hylo_PROJECT_MANIFEST "${CMAKE_BINARY_DIR}/hylo-project.json" CACHE FILEPATH
    "Where to write the LSP-facing Hylo project manifest (empty: do not write it)")
  mark_as_advanced(Hylo_PROJECT_MANIFEST)

  # -------------------------------------------------------------------------
  # 4. Check that the compiler works (and warm the module cache).
  # -------------------------------------------------------------------------
  # Keyed on the compiler path, version, module cache and target triple so a
  # changed toolchain, cache or triple is re-checked (the probe passes
  # --target below).
  set(_hylo_works_key "${Hylo_COMPILER}|${Hylo_VERSION_STRING}|${Hylo_MODULE_CACHE_DIR}|${Hylo_TARGET_TRIPLE}")
  if(NOT Hylo_COMPILER_WORKS_KEY STREQUAL _hylo_works_key)
    set(_hylo_test_dir "${CMAKE_BINARY_DIR}/CMakeFiles/HyloCompilerTest")
    file(MAKE_DIRECTORY "${_hylo_test_dir}")
    set(_hylo_test_src "${_hylo_test_dir}/HyloCompilerTest.hylo")
    file(WRITE "${_hylo_test_src}" "public fun main() -> Int32 {\n  0\n}\n")
    set(_hylo_test_cmd "${Hylo_COMPILER}")
    if(Hylo_MODULE_CACHE_DIR)
      file(MAKE_DIRECTORY "${Hylo_MODULE_CACHE_DIR}")
      list(APPEND _hylo_test_cmd --module-cache "${Hylo_MODULE_CACHE_DIR}")
    endif()
    if(Hylo_TARGET_TRIPLE)
      list(APPEND _hylo_test_cmd --target "${Hylo_TARGET_TRIPLE}")
    endif()
    list(APPEND _hylo_test_cmd --module-name HyloCompilerTest
      --emit object "${_hylo_test_src}" -o "${_hylo_test_dir}/HyloCompilerTest.o")
    execute_process(
      COMMAND ${_hylo_test_cmd}
      RESULT_VARIABLE _hylo_test_result
      OUTPUT_VARIABLE _hylo_test_output
      ERROR_VARIABLE _hylo_test_output)
    if(_hylo_test_result EQUAL 0)
      set(Hylo_COMPILER_WORKS TRUE CACHE INTERNAL "hc compiles a trivial module")
      set(Hylo_COMPILER_WORKS_KEY "${_hylo_works_key}" CACHE INTERNAL "")
      if(NOT Hylo_FIND_QUIETLY)
        message(STATUS "Check for working Hylo compiler: ${Hylo_COMPILER} -- works")
      endif()
    else()
      set(Hylo_COMPILER_WORKS FALSE CACHE INTERNAL "hc compiles a trivial module")
      set(Hylo_COMPILER_WORKS_KEY "" CACHE INTERNAL "")
      message(WARNING
        "The Hylo compiler\n  \"${Hylo_COMPILER}\"\n"
        "is not able to compile a simple test program. It fails with:\n${_hylo_test_output}")
    endif()
  endif()
endif()

set(_hylo_required_vars Hylo_COMPILER Hylo_STDLIB_ROOT Hylo_STDLIB_SHIMS Hylo_COMPILER_WORKS)
if(DEFINED Hylo_VERSION)
  find_package_handle_standard_args(Hylo
    REQUIRED_VARS ${_hylo_required_vars}
    VERSION_VAR Hylo_VERSION)
else()
  # A "development" compiler has no comparable version; accept it but say so.
  find_package_handle_standard_args(Hylo
    REQUIRED_VARS ${_hylo_required_vars}
    REASON_FAILURE_MESSAGE "hc was not found, did not report a standard library, or does not work")
  if(Hylo_FOUND AND Hylo_FIND_VERSION AND NOT Hylo_FIND_QUIETLY)
    message(STATUS "Hylo: compiler reports version '${Hylo_VERSION_STRING}'; "
      "cannot check the requested version ${Hylo_FIND_VERSION}")
  endif()
endif()

if(Hylo_FOUND)
  # -------------------------------------------------------------------------
  # 5. Targets.
  # -------------------------------------------------------------------------
  if(NOT TARGET Hylo::hc)
    add_executable(Hylo::hc IMPORTED GLOBAL)
    set_target_properties(Hylo::hc PROPERTIES IMPORTED_LOCATION "${Hylo_COMPILER}")
  endif()

  # Hylo programs are linked with the C toolchain, so C must be enabled.  The
  # runtime shim is C anyway.
  if(NOT CMAKE_C_COMPILER_LOADED)
    enable_language(C)
  endif()

  if(NOT TARGET hylo-runtime)
    add_library(hylo-runtime STATIC "${Hylo_STDLIB_SHIMS}")
    # hc emits position-independent code (on Linux it defaults to the pic
    # relocation model), so Hylo shared libraries are possible; the runtime they
    # pull in must be PIC too.
    set_target_properties(hylo-runtime PROPERTIES
      POSITION_INDEPENDENT_CODE ON
      FOLDER "Hylo")
    # Instruction selection may lower some operations (e.g. frem) to libm calls;
    # hc's own link step adds -lm on Linux (Driver.linkExecutable).
    if(UNIX AND NOT APPLE)
      target_link_libraries(hylo-runtime INTERFACE m)
    endif()
    # MSVC's linker learns which C runtime to link from /DEFAULTLIB directives
    # embedded in C objects; hc's objects carry none.  A Hylo program that never
    # allocates would not pull shims.obj out of the archive, link no CRT at all,
    # and fail with "unresolved external symbol mainCRTStartup".  Force the shim
    # in so its CRT directive always applies (matches CMAKE_MSVC_RUNTIME_LIBRARY).
    # (Unprefixed: hc targets only 64-bit Windows, where C symbols carry no
    # leading underscore.)
    if(MSVC)
      target_link_options(hylo-runtime INTERFACE "LINKER:/INCLUDE:c_malloc_indirect")
    endif()
    add_library(Hylo::Runtime ALIAS hylo-runtime)
  endif()

  include("${CMAKE_CURRENT_LIST_DIR}/HyloTargets.cmake")
endif()

cmake_policy(POP)
