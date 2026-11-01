#[=======================================================================[.rst:
HyloTargets
-----------

Commands for building Hylo modules.  Included by ``FindHylo.cmake``; do not
include directly.

THE MODEL
^^^^^^^^^

``hc`` compiles a *whole module* -- every source of the module, in one
invocation -- into exactly one object file, and can publish the module's
archive (``.hylomodule``, what importers read) and an *interface hash* (a
digest of the module's observable surface) alongside it.  CMake's native
compile model is one object per source, so a Hylo module is not expressed as
compiled sources.  Instead, each Hylo target gets ONE custom command::

    hc --module-name M [flags] --import=Dep... --module-search-path=<dir>...
       --emit object -o M.o --emit-module-to M.hylomodule
       --emit-module-interface-hash-to M.iface  <all .hylo sources of the target>

whose object is added to the target as an external object and linked by the
C toolchain.  The ``.hylo`` sources stay in the target (so IDEs see them) but
are not compiled by CMake -- Hylo is not an enabled CMake language, so CMake
has no rule for them.

Module dependencies are ordinary ``target_link_libraries`` calls: linking a
Hylo library target makes its module visible to the dependent's compile
(``--import``), adds its archive directory to the module search path, and
makes the dependent's compile depend on the library's *interface hash file*.
Because custom commands get Ninja's ``restat = 1``, a rebuild of the library
that leaves the interface hash untouched (hc writes it only when its content
changes) prunes the dependents' recompiles: they are only relinked.  This is
the separate-compilation payoff Hylo is designed for.  (Today hc's hash is
still a hash of the whole archive, so only no-op rebuilds are pruned; the
build graph is ready for a precise hash.)

The propagation uses CMake 3.30 custom transitive properties:

``HYLO_IMPORTS`` (compile-transitive)
  modules a target makes visible to its dependents -- its own module name.
  Follows ``PUBLIC``/``INTERFACE`` links only, like include directories: a
  ``PRIVATE`` dependency is not re-exported.  Use ``PUBLIC`` when your module's
  public declarations mention types of the dependency.
``HYLO_MODULE_SEARCH_PATHS`` (link-transitive)
  directories containing the ``.hylomodule`` archives of every module in the
  link closure, so hc can resolve transitive imports it discovers in archives.
``HYLO_MODULE_DEPENDS`` (link-transitive)
  the interface hash files of every module in the link closure.  Conservative
  on purpose: a dependent recompiles when *any* module it may have seen through
  an archive changes its interface.
``HYLO_COMPILE_OPTIONS`` (compile-transitive)
  extra hc options; see ``hylo_target_compile_options``.

COMMANDS
^^^^^^^^

.. command:: hylo_add_library

  ::

    hylo_add_library(<target> [STATIC | SHARED | MODULE] [EXCLUDE_FROM_ALL]
                     [MODULE_NAME <name>] [NO_RUNTIME]
                     [SOURCES] <source>...)

  Like ``add_library``, then ``hylo_target_module``.  Non-``.hylo`` sources
  (C files etc.) are compiled by CMake's own language support and archived or
  linked alongside the module's object.  With no library type the usual
  ``BUILD_SHARED_LIBS`` rule applies.  ``OBJECT`` libraries are not supported:
  CMake's ``$<TARGET_OBJECTS>`` does not see external objects.

.. command:: hylo_add_executable

  ::

    hylo_add_executable(<target> [EXCLUDE_FROM_ALL] [MODULE_NAME <name>]
                        [NO_RUNTIME] [SOURCES] <source>...)

  Like ``add_executable``, then ``hylo_target_module``.

.. command:: hylo_target_module

  ::

    hylo_target_module(<target> [MODULE_NAME <name>] [NO_RUNTIME])

  Turns an existing static/shared/module library or executable target into a
  Hylo module: every ``.hylo`` file among the target's ``SOURCES`` (evaluated
  at generate time, so later ``target_sources`` calls count) is compiled into
  one module named ``<name>`` (default: the target name, which must then be a
  valid identifier).  The target's ``LINKER_LANGUAGE`` is set to ``C`` unless
  already set (set it to ``CXX`` yourself if the target also has C++ sources),
  and ``Hylo::Runtime`` is linked privately unless ``NO_RUNTIME``.  Must be
  called from the directory that created the target.

  Sets the target properties ``HYLO_MODULE_NAME``, ``HYLO_MODULE_OBJECT``, and
  for libraries ``HYLO_MODULE_ARCHIVE`` and ``HYLO_MODULE_INTERFACE_HASH``.

.. command:: hylo_install_module

  ::

    hylo_install_module(<target> [DESTINATION <dir>] [COMPONENT <component>])

  Installs a Hylo library's ``.hylomodule`` archive and ``.iface`` interface
  hash (default destination ``${CMAKE_INSTALL_LIBDIR}/hylo`` or ``lib/hylo``)
  and records their installed locations in the target's interface, so that
  after the usual ``install(TARGETS <target> EXPORT ...)`` +
  ``install(EXPORT ...)`` a consumer's ``target_link_libraries`` against the
  imported target imports the module from the installed files.  The consumer
  needs its own ``find_package(Hylo)`` (for ``hylo_add_executable`` and
  ``Hylo::Runtime``) with a compatible compiler.

.. command:: hylo_target_compile_options

  ::

    hylo_target_compile_options(<target> <PRIVATE|PUBLIC|INTERFACE> <option>...)

  Adds options to the hc command line of ``<target>`` (``PRIVATE``/``PUBLIC``)
  and/or of its dependents (``PUBLIC``/``INTERFACE``), mirroring
  ``target_compile_options``.  Ordinary ``COMPILE_OPTIONS`` are *not* passed to
  hc: in a mixed target they are meant for the C compiler.

Configuration-wide flags come from ``Hylo_FLAGS`` and ``Hylo_FLAGS_<CONFIG>``
(see FindHylo).
#]=======================================================================]

include_guard(GLOBAL)

cmake_policy(PUSH)
cmake_policy(VERSION 3.30)

define_property(TARGET PROPERTY HYLO_MODULE_NAME
  BRIEF_DOCS "Name of the Hylo module compiled from this target's .hylo sources")
define_property(TARGET PROPERTY HYLO_MODULE_OBJECT
  BRIEF_DOCS "Object file produced by compiling this target's Hylo module")
define_property(TARGET PROPERTY HYLO_MODULE_ARCHIVE
  BRIEF_DOCS "The .hylomodule archive this library publishes for importers")
define_property(TARGET PROPERTY HYLO_MODULE_INTERFACE_HASH
  BRIEF_DOCS "File holding the interface hash of this library's Hylo module")
define_property(TARGET PROPERTY HYLO_COMPILE_OPTIONS
  BRIEF_DOCS "Extra hc options for this target's module (see hylo_target_compile_options)")
define_property(TARGET PROPERTY INTERFACE_HYLO_COMPILE_OPTIONS
  BRIEF_DOCS "Extra hc options for dependents' modules")
define_property(TARGET PROPERTY INTERFACE_HYLO_IMPORTS
  BRIEF_DOCS "Hylo modules made visible (--import) to dependents' modules")
define_property(TARGET PROPERTY INTERFACE_HYLO_MODULE_SEARCH_PATHS
  BRIEF_DOCS "Directories where dependents find this target's .hylomodule")
define_property(TARGET PROPERTY INTERFACE_HYLO_MODULE_DEPENDS
  BRIEF_DOCS "Files whose change must recompile dependents' Hylo modules")

# The standard library is read by every hc invocation.  Releases bundle an
# immutable copy, but a locally built hc reads it from the source tree, where it
# can change without the compiler binary changing; depending on the sources
# keeps objects from going stale against a modified stdlib either way.
# Reglobbed on every configure so a replaced toolchain cannot leave modules
# depending on the old one's files (behaviour.toolchain-swap); CACHE INTERNAL,
# always overwritten, only makes the list visible in every directory.  The
# root is the whole bundle (Sources/ and Generated.hylo), so one recursive
# glob covers everything hc reads.
file(GLOB_RECURSE _hylo_stdlib_sources "${Hylo_STDLIB_ROOT}/*.hylo")
set(_Hylo_STDLIB_SOURCES "${_hylo_stdlib_sources}" CACHE INTERNAL "Hylo stdlib sources")

# Evaluates to "/<config>" under multi-config generators and "" otherwise, so
# per-target outputs do not collide across configurations.
function(_hylo_config_subdir out)
  get_property(_multi GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
  if(_multi)
    set(${out} "/$<CONFIG>" PARENT_SCOPE)
  else()
    set(${out} "" PARENT_SCOPE)
  endif()
endfunction()

# Returns, as a list of generator expressions, the configuration-wide hc flags:
# Hylo_FLAGS plus Hylo_FLAGS_<CONFIG> for the active configuration.
function(_hylo_global_flags out)
  set(_result)
  separate_arguments(_f NATIVE_COMMAND "${Hylo_FLAGS}")
  list(APPEND _result ${_f})

  set(_configs ${CMAKE_CONFIGURATION_TYPES})
  if(NOT _configs)
    set(_configs ${CMAKE_BUILD_TYPE})
  endif()
  foreach(_c IN LISTS _configs)
    string(TOUPPER "${_c}" _C)
    separate_arguments(_f NATIVE_COMMAND "${Hylo_FLAGS_${_C}}")
    if(_f)
      # Keep the list inside one generator expression: the command line is
      # split on ';' only after evaluation (COMMAND_EXPAND_LISTS).
      string(REPLACE ";" "$<SEMICOLON>" _f "${_f}")
      list(APPEND _result "$<$<CONFIG:${_c}>:${_f}>")
    endif()
  endforeach()
  set(${out} "${_result}" PARENT_SCOPE)
endfunction()

function(hylo_target_module target)
  cmake_parse_arguments(PARSE_ARGV 1 arg "NO_RUNTIME" "MODULE_NAME" "")
  if(arg_UNPARSED_ARGUMENTS)
    message(FATAL_ERROR "hylo_target_module(${target}): unexpected arguments: ${arg_UNPARSED_ARGUMENTS}")
  endif()
  if(NOT TARGET ${target})
    message(FATAL_ERROR "hylo_target_module: '${target}' is not a target")
  endif()

  # A Hylo module's object is a generated, per-configuration source (its path
  # contains $<CONFIG>), and Xcode is the one generator without per-config
  # sources: it evaluates the path with the literal configuration "NOCONFIG"
  # and fails on the missing file (observed with CMake 4.3 / Xcode 26).
  if(CMAKE_GENERATOR STREQUAL "Xcode")
    message(FATAL_ERROR
      "hylo_target_module(${target}): the Xcode generator is not supported (it has no "
      "per-config sources, which the module's per-configuration object requires). "
      "Use the Ninja Multi-Config generator instead.")
  endif()

  get_target_property(_type ${target} TYPE)
  if(_type STREQUAL "OBJECT_LIBRARY")
    message(FATAL_ERROR
      "hylo_target_module(${target}): OBJECT libraries are not supported. A Hylo module's "
      "object is an external object of its target, and CMake's $<TARGET_OBJECTS> does not "
      "include external objects, so linking the object library would drop the module. "
      "Use a STATIC library.")
  elseif(NOT _type MATCHES "^(STATIC_LIBRARY|SHARED_LIBRARY|MODULE_LIBRARY|EXECUTABLE)$")
    message(FATAL_ERROR "hylo_target_module(${target}): unsupported target type ${_type}")
  endif()

  get_target_property(_srcdir ${target} SOURCE_DIR)
  if(NOT _srcdir STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    # The custom command's outputs must be consumed by a target of the same
    # directory for CMake to attach the rule to that target.
    message(FATAL_ERROR
      "hylo_target_module(${target}) must be called from the directory that created the "
      "target (${_srcdir}), not from ${CMAKE_CURRENT_SOURCE_DIR}")
  endif()

  get_target_property(_already ${target} HYLO_MODULE_NAME)
  if(_already)
    message(FATAL_ERROR "hylo_target_module(${target}): target is already the Hylo module '${_already}'")
  endif()

  set(_module "${arg_MODULE_NAME}")
  if(NOT _module)
    set(_module "${target}")
  endif()
  if(NOT _module MATCHES "^[A-Za-z_][A-Za-z0-9_]*$")
    message(FATAL_ERROR
      "hylo_target_module(${target}): '${_module}' is not a valid Hylo module name; "
      "pass MODULE_NAME <identifier>")
  endif()

  set(_is_library FALSE)
  if(_type MATCHES "LIBRARY$")
    set(_is_library TRUE)
  endif()

  # Two libraries publishing the same module name cannot both be in one link
  # closure; catch the obvious case early.
  if(_is_library)
    get_property(_owner GLOBAL PROPERTY "_HYLO_MODULE_OWNER_${_module}")
    if(_owner AND NOT _owner STREQUAL target)
      message(WARNING
        "hylo: Hylo module '${_module}' is published by both targets '${_owner}' and "
        "'${target}'; a program linking both will not build. Give one a MODULE_NAME.")
    endif()
    set_property(GLOBAL PROPERTY "_HYLO_MODULE_OWNER_${_module}" "${target}")
  endif()

  # ---- Outputs -------------------------------------------------------------
  _hylo_config_subdir(_cfg)
  set(_dir "${CMAKE_CURRENT_BINARY_DIR}/CMakeFiles/${target}.hylo.dir${_cfg}")
  set(_object "${_dir}/${_module}${CMAKE_C_OUTPUT_EXTENSION}")
  set(_archive "${_dir}/${_module}.hylomodule")
  set(_iface "${_dir}/${_module}.iface")

  # ---- Inputs (all evaluated at generate time) -----------------------------
  # Every .hylo source of the target, made absolute.  Relative entries in
  # SOURCES are relative to the target's source directory (CMP0076).
  set(_sources
    "$<PATH:ABSOLUTE_PATH,NORMALIZE,$<FILTER:$<TARGET_PROPERTY:${target},SOURCES>,INCLUDE,\\.hylo$>,${CMAKE_CURRENT_SOURCE_DIR}>")
  # $<BUILD_INTERFACE:...>/$<INSTALL_INTERFACE:...> entries evaluate to empty
  # strings in the other context; drop those before prefixing with flags.
  set(_imports "$<REMOVE_DUPLICATES:$<FILTER:$<TARGET_PROPERTY:${target},HYLO_IMPORTS>,EXCLUDE,^$>>")
  set(_search_paths "$<REMOVE_DUPLICATES:$<FILTER:$<TARGET_PROPERTY:${target},HYLO_MODULE_SEARCH_PATHS>,EXCLUDE,^$>>")
  set(_module_depends "$<REMOVE_DUPLICATES:$<FILTER:$<TARGET_PROPERTY:${target},HYLO_MODULE_DEPENDS>,EXCLUDE,^$>>")
  set(_options "$<FILTER:$<TARGET_PROPERTY:${target},HYLO_COMPILE_OPTIONS>,EXCLUDE,^$>")

  # ---- Command -------------------------------------------------------------
  set(_cmd "${Hylo_COMPILER}" --module-name "${_module}")
  if(Hylo_MODULE_CACHE_DIR)
    list(APPEND _cmd --module-cache "${Hylo_MODULE_CACHE_DIR}")
  endif()
  if(Hylo_TARGET_TRIPLE)
    list(APPEND _cmd --target "${Hylo_TARGET_TRIPLE}")
  endif()
  _hylo_global_flags(_flags)
  list(APPEND _cmd ${_flags} "${_options}")
  # Each genex below is one argument that evaluates to a ';'-list (or to
  # nothing); COMMAND_EXPAND_LISTS splits it and drops empty entries.
  list(APPEND _cmd
    "$<$<BOOL:${_imports}>:$<LIST:TRANSFORM,${_imports},PREPEND,--import=>>"
    "$<$<BOOL:${_search_paths}>:$<LIST:TRANSFORM,${_search_paths},PREPEND,--module-search-path=>>"
    --emit object -o "${_object}")
  set(_outputs "${_object}")
  if(_is_library)
    list(APPEND _cmd
      --emit-module-to "${_archive}"
      --emit-module-interface-hash-to "${_iface}")
    list(APPEND _outputs "${_archive}" "${_iface}")
  endif()
  list(APPEND _cmd "${_sources}")

  add_custom_command(
    OUTPUT ${_outputs}
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${_dir}"
    COMMAND ${_cmd}
    # The compiler itself and the standard library are inputs of every module:
    # a new hc means new archive/object formats, and there is no other way to
    # know the stdlib did not change.
    DEPENDS "${_sources}" "${_module_depends}" "${Hylo_COMPILER}" ${_Hylo_STDLIB_SOURCES}
    COMMAND_EXPAND_LISTS
    VERBATIM
    # The behaviour tests key their recompile assertions on this wording
    # (HYLO_COMPILE_MESSAGE in tests/Harness.cmake); change both together.
    COMMENT "Compiling Hylo module ${_module} (${target})")

  # The object is an EXTERNAL_OBJECT source (by extension); CMake links it and
  # knows it is generated by the command above.
  target_sources(${target} PRIVATE "${_object}")

  # ---- Properties ----------------------------------------------------------
  set_target_properties(${target} PROPERTIES
    HYLO_MODULE_NAME "${_module}"
    HYLO_MODULE_OBJECT "${_object}"
    TRANSITIVE_COMPILE_PROPERTIES "HYLO_IMPORTS;HYLO_COMPILE_OPTIONS"
    TRANSITIVE_LINK_PROPERTIES "HYLO_MODULE_SEARCH_PATHS;HYLO_MODULE_DEPENDS")
  if(_is_library)
    # Build-tree paths only; hylo_install_module() adds the INSTALL_INTERFACE
    # counterparts so an exported target points consumers at the installed
    # archive and hash.
    set_target_properties(${target} PROPERTIES
      HYLO_MODULE_ARCHIVE "${_archive}"
      HYLO_MODULE_INTERFACE_HASH "${_iface}"
      INTERFACE_HYLO_IMPORTS "${_module}"
      INTERFACE_HYLO_MODULE_SEARCH_PATHS "$<BUILD_INTERFACE:${_dir}>"
      INTERFACE_HYLO_MODULE_DEPENDS "$<BUILD_INTERFACE:${_iface}>")
  endif()

  get_target_property(_linker_language ${target} LINKER_LANGUAGE)
  if(NOT _linker_language)
    set_target_properties(${target} PROPERTIES LINKER_LANGUAGE C)
  endif()

  if(NOT arg_NO_RUNTIME)
    if(_is_library)
      # Libraries carry the runtime to their consumers in the build tree only.
      # An installed/exported library must not reference our hylo-runtime target
      # (it is not in the user's export set); consumers get the runtime from
      # their own find_package(Hylo) + hylo_add_executable. Shared libraries
      # link it in directly, so their install interface needs nothing.
      target_link_libraries(${target} PRIVATE "$<BUILD_INTERFACE:Hylo::Runtime>")
    else()
      target_link_libraries(${target} PRIVATE Hylo::Runtime)
    endif()
  endif()

  # ---- Project manifest (for the language server) --------------------------
  _hylo_manifest_record("${target}" "${_module}" "${_sources}" "${_imports}")
endfunction()

function(hylo_add_library target)
  cmake_parse_arguments(PARSE_ARGV 1 arg
    "STATIC;SHARED;MODULE;OBJECT;INTERFACE;EXCLUDE_FROM_ALL;NO_RUNTIME" "MODULE_NAME" "SOURCES")
  if(arg_OBJECT OR arg_INTERFACE)
    message(FATAL_ERROR "hylo_add_library(${target}): only STATIC, SHARED and MODULE libraries can be Hylo modules")
  endif()
  set(_kind)
  foreach(_k STATIC SHARED MODULE)
    if(arg_${_k})
      if(_kind)
        message(FATAL_ERROR "hylo_add_library(${target}): more than one library type given")
      endif()
      set(_kind ${_k})
    endif()
  endforeach()
  set(_excl)
  if(arg_EXCLUDE_FROM_ALL)
    set(_excl EXCLUDE_FROM_ALL)
  endif()
  set(_sources ${arg_SOURCES} ${arg_UNPARSED_ARGUMENTS})
  if(NOT _sources)
    message(FATAL_ERROR "hylo_add_library(${target}): no sources given")
  endif()
  add_library(${target} ${_kind} ${_excl} ${_sources})
  set(_module_args)
  if(arg_MODULE_NAME)
    set(_module_args MODULE_NAME "${arg_MODULE_NAME}")
  endif()
  if(arg_NO_RUNTIME)
    list(APPEND _module_args NO_RUNTIME)
  endif()
  hylo_target_module(${target} ${_module_args})
endfunction()

function(hylo_add_executable target)
  cmake_parse_arguments(PARSE_ARGV 1 arg "EXCLUDE_FROM_ALL;NO_RUNTIME" "MODULE_NAME" "SOURCES")
  set(_excl)
  if(arg_EXCLUDE_FROM_ALL)
    set(_excl EXCLUDE_FROM_ALL)
  endif()
  set(_sources ${arg_SOURCES} ${arg_UNPARSED_ARGUMENTS})
  if(NOT _sources)
    message(FATAL_ERROR "hylo_add_executable(${target}): no sources given")
  endif()
  add_executable(${target} ${_excl} ${_sources})
  set(_module_args)
  if(arg_MODULE_NAME)
    set(_module_args MODULE_NAME "${arg_MODULE_NAME}")
  endif()
  if(arg_NO_RUNTIME)
    list(APPEND _module_args NO_RUNTIME)
  endif()
  hylo_target_module(${target} ${_module_args})
endfunction()

function(hylo_target_compile_options target)
  if(NOT TARGET ${target})
    message(FATAL_ERROR "hylo_target_compile_options: '${target}' is not a target")
  endif()
  set(_scope)
  foreach(_a IN LISTS ARGN)
    if(_a MATCHES "^(PRIVATE|PUBLIC|INTERFACE)$")
      set(_scope "${_a}")
    elseif(NOT _scope)
      message(FATAL_ERROR "hylo_target_compile_options(${target}): expected PRIVATE, PUBLIC or INTERFACE before '${_a}'")
    else()
      if(_scope MATCHES "PRIVATE|PUBLIC")
        set_property(TARGET ${target} APPEND PROPERTY HYLO_COMPILE_OPTIONS "${_a}")
      endif()
      if(_scope MATCHES "PUBLIC|INTERFACE")
        set_property(TARGET ${target} APPEND PROPERTY INTERFACE_HYLO_COMPILE_OPTIONS "${_a}")
      endif()
    endif()
  endforeach()
endfunction()

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------

function(hylo_install_module target)
  cmake_parse_arguments(PARSE_ARGV 1 arg "" "DESTINATION;COMPONENT" "")
  if(arg_UNPARSED_ARGUMENTS)
    message(FATAL_ERROR "hylo_install_module(${target}): unexpected arguments: ${arg_UNPARSED_ARGUMENTS}")
  endif()
  if(NOT TARGET ${target})
    message(FATAL_ERROR "hylo_install_module: '${target}' is not a target")
  endif()
  get_target_property(_archive ${target} HYLO_MODULE_ARCHIVE)
  get_target_property(_iface ${target} HYLO_MODULE_INTERFACE_HASH)
  get_target_property(_module ${target} HYLO_MODULE_NAME)
  if(NOT _archive)
    message(FATAL_ERROR "hylo_install_module(${target}): not a Hylo library target")
  endif()

  set(_dest "${arg_DESTINATION}")
  if(NOT _dest)
    if(DEFINED CMAKE_INSTALL_LIBDIR)
      set(_dest "${CMAKE_INSTALL_LIBDIR}/hylo")
    else()
      set(_dest "lib/hylo")
    endif()
  endif()
  set(_component)
  if(arg_COMPONENT)
    set(_component COMPONENT "${arg_COMPONENT}")
  endif()

  install(FILES "${_archive}" "${_iface}" DESTINATION "${_dest}" ${_component})

  # Absolute destinations are used as-is; relative ones are under the prefix
  # ($<INSTALL_PREFIX> becomes ${_IMPORT_PREFIX} in the export file).
  if(IS_ABSOLUTE "${_dest}")
    set(_installed_dir "${_dest}")
  else()
    set(_installed_dir "$<INSTALL_PREFIX>/${_dest}")
  endif()
  set_property(TARGET ${target} APPEND PROPERTY
    INTERFACE_HYLO_MODULE_SEARCH_PATHS "$<INSTALL_INTERFACE:${_installed_dir}>")
  set_property(TARGET ${target} APPEND PROPERTY
    INTERFACE_HYLO_MODULE_DEPENDS "$<INSTALL_INTERFACE:${_installed_dir}/${_module}.iface>")
endfunction()

# ---------------------------------------------------------------------------
# Project manifest: hylo-project.json
#
# A language server needs, for any file it is asked about, the MODULE the file
# belongs to, that module's other sources, and what it imports -- a per-module
# view (the shape of rust-project.json), not compile_commands.json's per-source
# one.  The manifest holds only what the language server reads; it is not a
# build description.  Each hylo_target_module call records one entry; at the
# end of the top-level directory the entries are written with file(GENERATE),
# so that the generator-expression parts (sources, imports) are resolved.
# Under a multi-config generator each configuration gets its own manifest in a
# <config> directory, and the language server chooses among them.
# ---------------------------------------------------------------------------

# Wraps each element of a (generator-expression) list in JSON quotes and joins
# them with ", ".  Paths containing '"' or '\' are not escaped -- generator
# expressions cannot do that -- which is documented as a limitation.
function(_hylo_json_string_array out list_genex)
  set(${out}
    "$<JOIN:$<LIST:TRANSFORM,${list_genex},REPLACE,^(.+)$,$<QUOTE>\\1$<QUOTE>>,$<COMMA> >"
    PARENT_SCOPE)
endfunction()

function(_hylo_manifest_record target module sources_genex imports_genex)
  _hylo_json_string_array(_sources "${sources_genex}")
  _hylo_json_string_array(_imports "${imports_genex}")
  set(_entry
"    {
      \"name\": \"${module}\",
      \"originTarget\": \"${target}\",
      \"imports\": [${_imports}],
      \"sources\": [${_sources}]
    }")
  set_property(GLOBAL APPEND PROPERTY HYLO_MANIFEST_MODULES "${_entry}")

  get_property(_registered GLOBAL PROPERTY _HYLO_MANIFEST_WRITER_REGISTERED)
  if(NOT _registered)
    set_property(GLOBAL PROPERTY _HYLO_MANIFEST_WRITER_REGISTERED TRUE)
    cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _hylo_write_project_manifest)
  endif()
endfunction()

function(_hylo_write_project_manifest)
  if(NOT Hylo_PROJECT_MANIFEST)
    return()
  endif()
  get_property(_modules GLOBAL PROPERTY HYLO_MANIFEST_MODULES)
  list(JOIN _modules ",\n" _modules_json)
  # Absent when Hylo_TARGET_TRIPLE is empty: hc then targets the build machine.
  set(_target_line "")
  if(Hylo_TARGET_TRIPLE)
    set(_target_line "  \"target\": \"${Hylo_TARGET_TRIPLE}\",\n")
  endif()
  set(_content
"{
  \"schemaVersion\": 1,
${_target_line}  \"modules\": [
${_modules_json}
  ]
}
")
  # One manifest per configuration under a multi-config generator, in a
  # <config> directory next to Hylo_PROJECT_MANIFEST's file name.
  get_filename_component(_directory "${Hylo_PROJECT_MANIFEST}" DIRECTORY)
  get_filename_component(_name "${Hylo_PROJECT_MANIFEST}" NAME)
  _hylo_config_subdir(_config)
  file(GENERATE OUTPUT "${_directory}${_config}/${_name}" CONTENT "${_content}")
  message(STATUS "Hylo: project manifest will be written to ${_directory}${_config}/${_name}")
endfunction()

cmake_policy(POP)
