cmake_minimum_required(VERSION 3.13)
project(valkey-luajit C)

# Options
option(LUAJIT_ENABLE_GC64 "Enable GC64 mode for >2GB memory on 64-bit" ON)

# CMake functionality includes
include(ExternalProject)

# Detect platform
if(APPLE)
    set(IS_MACOS TRUE)
else()
    set(IS_MACOS FALSE)
endif()

# ---------------------------------------------------------------------------
# Build LuaJIT as a static library
# ---------------------------------------------------------------------------

set(LUAJIT_SOURCE_DIR ${CMAKE_SOURCE_DIR}/deps/luajit)
set(LUAJIT_BUILD_DIR ${CMAKE_BINARY_DIR}/luajit-build)
set(LUAJIT_INCLUDE_DIR ${LUAJIT_SOURCE_DIR}/src)

# Determine the static lib name
if(IS_MACOS)
    set(LUAJIT_STATIC_LIB ${LUAJIT_SOURCE_DIR}/src/libluajit.a)
else()
    set(LUAJIT_STATIC_LIB ${LUAJIT_SOURCE_DIR}/src/libluajit.a)
endif()

# Build LuaJIT using its Makefile
set(LUAJIT_MAKE_FLAGS "")
if(LUAJIT_ENABLE_GC64)
    set(LUAJIT_MAKE_FLAGS "XCFLAGS=-DLUAJIT_ENABLE_GC64")
endif()

# Use -fPIC so the static lib can be linked into a shared library
set(LUAJIT_CFLAGS "-fPIC")

# Detect macOS deployment target
if(IS_MACOS)
    if(DEFINED ENV{MACOSX_DEPLOYMENT_TARGET} AND NOT "$ENV{MACOSX_DEPLOYMENT_TARGET}" STREQUAL "")
        set(LUAJIT_DEPLOYMENT_TARGET "$ENV{MACOSX_DEPLOYMENT_TARGET}")
    else()
        execute_process(
            COMMAND sw_vers -productVersion
            OUTPUT_VARIABLE _macos_version
            OUTPUT_STRIP_TRAILING_WHITESPACE
        )
        # Extract major version (e.g., "15" from "15.3.1")
        string(REGEX MATCH "^[0-9]+" _macos_major "${_macos_version}")
        set(LUAJIT_DEPLOYMENT_TARGET "${_macos_major}.0")
    endif()
    set(LUAJIT_ENV_VARS "MACOSX_DEPLOYMENT_TARGET=${LUAJIT_DEPLOYMENT_TARGET}")
    # Export as environment variable for use in other targets (e.g., luajit_clean)
    set(ENV{MACOSX_DEPLOYMENT_TARGET} "${LUAJIT_DEPLOYMENT_TARGET}")
else()
    set(LUAJIT_ENV_VARS "")
endif()

include(ProcessorCount)
ProcessorCount(NPROC)
if(NPROC EQUAL 0)
    set(NPROC 1)
endif()

add_custom_command(
    OUTPUT ${LUAJIT_STATIC_LIB}
    COMMAND ${CMAKE_COMMAND} -E env
        ${LUAJIT_ENV_VARS}
        ${CMAKE_MAKE_PROGRAM}
        -C ${LUAJIT_SOURCE_DIR}
        "CC=${CMAKE_C_COMPILER}"
        "TARGET_CFLAGS=${LUAJIT_CFLAGS}"
        "BUILDMODE=static"
        "--jobs=${NPROC}"
        ${LUAJIT_MAKE_FLAGS}
    COMMENT "Building LuaJIT static library"
    VERBATIM
)

add_custom_target(luajit_build DEPENDS ${LUAJIT_STATIC_LIB})

# Create imported target for LuaJIT
add_library(luajit STATIC IMPORTED)
set_target_properties(luajit PROPERTIES
    IMPORTED_LOCATION ${LUAJIT_STATIC_LIB}
)
add_dependencies(luajit luajit_build)

# ---------------------------------------------------------------------------
# Embed FFI Lua files as C string literals
# ---------------------------------------------------------------------------

set(FFI_CDEF_LUA ${CMAKE_SOURCE_DIR}/src/lua/ffi_cdef.lua)
set(FFI_API_LUA ${CMAKE_SOURCE_DIR}/src/lua/ffi_api.lua)
set(FFI_EMBEDDED_H ${CMAKE_BINARY_DIR}/ffi_lua_embedded.h)

add_custom_command(
    OUTPUT ${FFI_EMBEDDED_H}
    COMMAND ${CMAKE_COMMAND}
        -DLUA_FILE_1=${FFI_CDEF_LUA}
        -DLUA_FILE_2=${FFI_API_LUA}
        -DVAR_NAME_1=ffi_cdef_lua
        -DVAR_NAME_2=ffi_api_lua
        -DOUTPUT_FILE=${FFI_EMBEDDED_H}
        -P ${CMAKE_SOURCE_DIR}/cmake/lua2c.cmake
    DEPENDS ${FFI_CDEF_LUA} ${FFI_API_LUA} ${CMAKE_SOURCE_DIR}/cmake/lua2c.cmake
    COMMENT "Embedding FFI Lua files into C header"
    VERBATIM
)

add_custom_target(ffi_lua_embed DEPENDS ${FFI_EMBEDDED_H})

# ---------------------------------------------------------------------------
# Module shared library
# ---------------------------------------------------------------------------

set(MODULE_SRCS
    src/engine_luajit.c
    src/script_luajit.c
    src/function_luajit.c
    src/sha1.c
    src/rand.c
    src/lua_cjson.c
    src/lua_struct.c
    src/lua_cmsgpack.c
    src/strbuf.c
    src/fpconv.c
    src/fpconv_dtoa.c
)

add_library(valkeyluajit SHARED ${MODULE_SRCS})

# C standard and warnings
target_compile_options(valkeyluajit PRIVATE
    -std=gnu11
    -W -Wall
    -fno-common
    -fPIC
    -O2
    -D_GNU_SOURCE
)

# Include directories
target_include_directories(valkeyluajit PRIVATE
    ${CMAKE_SOURCE_DIR}/src
    ${LUAJIT_INCLUDE_DIR}
    ${CMAKE_BINARY_DIR}
)

# Ensure embedded FFI header is generated before compiling
add_dependencies(valkeyluajit ffi_lua_embed luajit_build)

# Link LuaJIT static library
# Platform-specific linking to ensure luaopen_ffi and all FFI symbols are exported
if(IS_MACOS)
    # On macOS, link normally and explicitly allow undefined symbols for FFI
    # This avoids symbol resolution conflicts with valkey's internal structures
    target_link_libraries(valkeyluajit PRIVATE "$<TARGET_FILE:luajit>")
    # Export only specific symbols needed from LuaJIT
    target_link_options(valkeyluajit PRIVATE "-Wl,-U,luaopen_ffi")
else()
    # On Linux, use --whole-archive to ensure ALL symbols from libluajit.a are included
    # This is critical for LuaJIT runtime dependencies (JIT, FFI, etc.) that may not
    # be directly referenced at link time but are needed at runtime
    target_link_libraries(valkeyluajit PRIVATE
        "-Wl,--whole-archive" "$<TARGET_FILE:luajit>" "-Wl,--no-whole-archive"
    )
endif()

# Platform-specific link flags
if(IS_MACOS)
    # On macOS, use -bundle for Valkey module loading, and -undefined dynamic_lookup
    # so ValkeyModule_* symbols are resolved at load time from the host process.
    set_target_properties(valkeyluajit PROPERTIES
        SUFFIX ".so"
        PREFIX "lib"
        LINK_FLAGS "-undefined dynamic_lookup"
    )
else()
    # On Linux, use -shared and control symbol visibility with version script
    # This prevents internal LuaJIT symbols from conflicting with valkey's internal structures
    # --whole-archive ensures symbols are INCLUDED, version script controls EXPOSURE
    set_target_properties(valkeyluajit PROPERTIES
        SUFFIX ".so"
        PREFIX "lib"
    )
    target_link_libraries(valkeyluajit PRIVATE m dl)
    # Use version script to control which symbols are exported/hidden
    # --whole-archive ensures all LuaJIT symbols are included internally
    # Version script hides internal symbols and exports only luaopen_ffi and ValkeyModule_*
    target_link_options(valkeyluajit PRIVATE
        "-Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/valkeyluajit.map"
    )
endif()

# Clean target for LuaJIT
add_custom_target(luajit_clean
    COMMAND ${CMAKE_COMMAND} -E env
        ${LUAJIT_ENV_VARS}
        ${CMAKE_MAKE_PROGRAM}
        -C ${LUAJIT_SOURCE_DIR}
        clean
    COMMENT "Cleaning LuaJIT build"
)

# Install
install(TARGETS valkeyluajit
    LIBRARY DESTINATION lib
)

