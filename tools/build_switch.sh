#!/bin/bash
# Builds the Nintendo Switch homebrew and the folder that goes on the SD card:
#
#   build/switch/nfsmw-recomp/   ->   copy to   sdmc:/switch/nfsmw-recomp/
#
# Needs devkitPro (devkitA64 + libnx) in DEVKITPRO, clang 18+, cmake, ninja,
# and the SDK checked out next to this repository. See docs/switch.md.
#
#   tools/build_switch.sh
#   DEVKITPRO=~/devkitpro tools/build_switch.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${DEVKITPRO:-}" ]; then
    for d in /opt/devkitpro "$HOME/.local/opt/devkitpro"; do
        [ -f "$d/libnx/switch.specs" ] && DEVKITPRO=$d && break
    done
fi
export DEVKITPRO=${DEVKITPRO:-/opt/devkitpro}
if [ ! -f "$DEVKITPRO/libnx/switch.specs" ]; then
    echo "libnx not found under DEVKITPRO=$DEVKITPRO (see docs/switch.md)." >&2
    exit 1
fi

SDK=$(realpath ../rexglue-sdk)
HOST_REXGLUE=$SDK/out/install/linux-amd64/bin/rexglue

# 1. The code generator is a host program: build and install the host SDK
#    once. The generated sources are shared with the PC builds.
if [ ! -x "$HOST_REXGLUE" ]; then
    cmake -S "$SDK" --preset linux-amd64
    cmake --build "$SDK/out/build/linux-amd64" --config Release
    cmake --install "$SDK/out/build/linux-amd64" --config Release
fi

# 2. Cross build: codegen (if its inputs changed), the SDK for Horizon, the
#    game, the .nro, and the SD card folder.
cmake --preset switch-release -S app
cmake --build app/out/build/switch-release --target switch_dist

echo
echo "Done: build/switch/nfsmw-recomp/"
echo "Copy it to sdmc:/switch/nfsmw-recomp/ and extract your game into its game/ folder."
