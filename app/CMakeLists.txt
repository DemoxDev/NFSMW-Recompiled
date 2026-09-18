# nfsmw - ReXGlue Recompiled Project
#
# SDK boilerplate lives in generated/rexglue.cmake.

cmake_minimum_required(VERSION 3.25)
project(nfsmw LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Nintendo Switch homebrew: the code generator is a host program, so the
# cross build runs the one from the host SDK install. Build that first
# (docs/switch.md); the generated sources are shared with the PC builds.
if(NINTENDO_SWITCH)
    set(NFSMW_HOST_REXGLUE
        "${CMAKE_CURRENT_SOURCE_DIR}/../../rexglue-sdk/out/install/linux-amd64/bin/rexglue"
        CACHE FILEPATH "Host rexglue executable used to run the code generator")
    if(NOT EXISTS "${NFSMW_HOST_REXGLUE}")
        message(FATAL_ERROR "Host rexglue not found at ${NFSMW_HOST_REXGLUE}. Build and install "
                            "the SDK for the host first, or set NFSMW_HOST_REXGLUE.")
    endif()
    add_executable(rex::rexglue IMPORTED)
    set_target_properties(rex::rexglue PROPERTIES IMPORTED_LOCATION "${NFSMW_HOST_REXGLUE}")
endif()

include(generated/rexglue.cmake)

# Sources
set(NFSMW_SOURCES
    src/main.cpp
    src/nfsmw_menu.cpp
)

if(WIN32)
    add_executable(nfsmw WIN32 ${NFSMW_SOURCES})
else()
    add_executable(nfsmw ${NFSMW_SOURCES})
endif()

# GPU_PLUGINS places the graphics backend DLL next to the .exe
# (rexgpu-xenosd.dll in Debug, rexgpu-xenos.dll in Release).
#
# BOTH THINGS are needed to see an image:
#   1. this line, which puts the DLL where the loader looks for it
#   2. gpu_plugin being set to "xenos" at runtime
#
# The gpu_plugin CVar comes empty by default, and empty means "no GPU
# emulation": the game initializes its ring buffer and graphics callbacks,
# the runtime discards them with "no GPU emulation loaded", and the screen
# stays black even though the game is running perfectly.
#
# Since src/nfsmw_app.h sets gpu_plugin=xenos by default, the --gpu_plugin
# argument is no longer required; it can still be passed to change it.
rexglue_setup_target(nfsmw GPU_PLUGINS xenos)

# =============================================================================
#  NINTENDO SWITCH - nfsmw-recomp.nro and the folder that goes on the SD card
#
#      build/switch/nfsmw-recomp/   ->   sdmc:/switch/nfsmw-recomp/
#
#  The game data is not part of it: the user extracts their own copy into
#  game/ next to the .nro. See docs/switch.md.
# =============================================================================
if(NINTENDO_SWITCH)
    set_target_properties(nfsmw PROPERTIES OUTPUT_NAME "nfsmw-recomp" SUFFIX ".elf")
    # Where the app looks for its folder when the loader passes no argv
    # (emulators); hbmenu passes the real path.
    target_compile_definitions(rexcore PRIVATE
        REX_SWITCH_DEFAULT_APP_PATH="/switch/nfsmw-recomp/nfsmw-recomp.nro")

    set(NFSMW_SWITCH_ICON "${NX_DEFAULT_ICON}" CACHE FILEPATH "256x256 JPEG icon for hbmenu")
    set(NFSMW_NACP "${CMAKE_CURRENT_BINARY_DIR}/nfsmw-recomp.nacp")
    set(NFSMW_NRO "${CMAKE_CURRENT_BINARY_DIR}/nfsmw-recomp.nro")
    add_custom_command(
        OUTPUT "${NFSMW_NACP}"
        COMMAND "${NX_NACPTOOL}" --create "NFS Most Wanted Recompiled" "NFSMW Recompiled"
                "0.0.2" "${NFSMW_NACP}"
        VERBATIM)
    add_custom_command(
        OUTPUT "${NFSMW_NRO}"
        COMMAND "${NX_ELF2NRO}" "$<TARGET_FILE:nfsmw>" "${NFSMW_NRO}"
                "--nacp=${NFSMW_NACP}" "--icon=${NFSMW_SWITCH_ICON}"
        DEPENDS nfsmw "${NFSMW_NACP}" "${NFSMW_SWITCH_ICON}"
        COMMENT "Packing nfsmw-recomp.nro"
        VERBATIM)
    add_custom_target(nfsmw_nro ALL DEPENDS "${NFSMW_NRO}")

    if(NOT DEFINED NFSMW_SWITCH_DIST_DIR)
        set(NFSMW_SWITCH_DIST_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../build/switch/nfsmw-recomp")
    endif()
    add_custom_target(switch_dist
        DEPENDS nfsmw_nro
        COMMAND ${CMAKE_COMMAND} -E make_directory "${NFSMW_SWITCH_DIST_DIR}/game"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${NFSMW_NRO}" "${NFSMW_SWITCH_DIST_DIR}/"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "${CMAKE_CURRENT_SOURCE_DIR}/../packaging/switch/README.txt"
                "${NFSMW_SWITCH_DIST_DIR}/"
        COMMENT "Assembling the SD card folder in ${NFSMW_SWITCH_DIST_DIR}"
        VERBATIM)
    return()
endif()

# Native Qt launcher (Linux). Used by packaging/appimage/.
option(NFSMW_BUILD_LAUNCHER "Build the native Qt launcher" ON)
option(NFSMW_LAUNCHER_BUILD_TESTS "Build Qt launcher tests" OFF)
if(NFSMW_BUILD_LAUNCHER AND UNIX AND NOT APPLE)
    find_package(Qt6 6.4 COMPONENTS Core Gui Widgets QUIET)
    if(Qt6_FOUND)
        if(NFSMW_LAUNCHER_BUILD_TESTS)
            enable_testing()
        endif()
        add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../launcher-linux"
                         "${CMAKE_CURRENT_BINARY_DIR}/launcher-linux")
    else()
        message(WARNING
            "Qt 6.4+ was not found; nfsmw_launcher will not be built")
    endif()
endif()


# =============================================================================
#  TARGET "dist" - the portable folder, named  build\
#
#  Gathers the executable, the project's DLLs, and the Visual C++ runtime's
#  into a single folder, so it can be carried to a machine without dev
#  tools.
#
#      cmake --build --preset win-amd64-release --target dist
#
#  THE TARGET IS CALLED "dist" AND THE FOLDER "build". That's not an
#  oversight: build/ was already in .gitignore and dist/ wasn't, so leaving
#  the folder there -which carries the executable with the game's code
#  inside- keeps it out of git on its own. To put it somewhere else:
#  -D NFSMW_DIST_DIR=...
#
#  DO NOT CONFUSE with app/out/build/win-amd64-release, which is where CMake
#  compiles. This is the already-assembled folder, ready to be carried off.
#
#  WHAT IT DOES NOT DO, AND THAT MATTERS:
#  it doesn't bundle the ISO into anything. It stays a loose file that the
#  game reads on the fly, and src/nfsmw_app.h looks for it next to the .exe.
#  That way the folder works wherever it ends up, with no fixed path.
#
#  None of this changes how the project is built: it's an extra, separate
#  step.
# =============================================================================
if(WIN32)
    # Resolves the VC runtime DLLs from whichever toolchain is in use.
    # With _SKIP set to TRUE it doesn't install anything: it only fills the
    # list, which is all we want. Without this we'd have to hand-write a
    # path like "C:\Program Files\Microsoft Visual Studio\...\Microsoft.VC143.CRT",
    # which is exactly what shouldn't be here.
    set(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_SKIP TRUE)
    set(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_NO_WARNINGS TRUE)
    include(InstallRequiredSystemLibraries)

    # NOT cache variables, on purpose. If they were cache variables, changing
    # the default value would do nothing in an already-configured tree: it
    # would keep using the old one without a peep, the target would say
    # "done", and the folder would show up where it was before. This way
    # what's here always wins, and a command-line -D still overrides it.
    if(NOT DEFINED NFSMW_DIST_NOMBRE)
        set(NFSMW_DIST_NOMBRE "NFS_Most_Wanted")
    endif()
    if(NOT DEFINED NFSMW_DIST_DIR)
        set(NFSMW_DIST_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../build")
    endif()

    add_custom_target(dist
        DEPENDS nfsmw
        COMMAND ${CMAKE_COMMAND}
                -D "D_EXE=$<TARGET_FILE:nfsmw>"
                -D "D_BUILD=$<TARGET_FILE_DIR:nfsmw>"
                -D "D_DIST=${NFSMW_DIST_DIR}"
                -D "D_NOMBRE=${NFSMW_DIST_NOMBRE}"
                -D "D_VCRUNTIME=${CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS}"
                -D "D_REDIST=$ENV{VCToolsRedistDir}"
                -D "D_PLANTILLA=${CMAKE_CURRENT_SOURCE_DIR}/dist_leeme.txt"
                -D "D_CONFIG=${CMAKE_CURRENT_SOURCE_DIR}/nfsmw.toml"
                -D "D_EDRAM=${CMAKE_CURRENT_SOURCE_DIR}/dist_comparar_edram.bat"
                -D "D_LANZADOR=${CMAKE_CURRENT_SOURCE_DIR}/../tools/lanzador/lanzador.ps1"
                -D "D_LANZADOR_BAT=${CMAKE_CURRENT_SOURCE_DIR}/dist_lanzador.bat"
                -D "D_MATRIZ=${CMAKE_CURRENT_SOURCE_DIR}/../tools/matriz.ps1"
                -D "D_PROBAR=${CMAKE_CURRENT_SOURCE_DIR}/dist_probar.bat"
                -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/hacer_dist.cmake"
        COMMENT "Armando la carpeta portable en ${NFSMW_DIST_DIR}"
        VERBATIM
    )
endif()
