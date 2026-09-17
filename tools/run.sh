#!/bin/bash
# Run NFSMW (Linux build) with sane defaults. Everything is overridable:
#
#   tools/run.sh                          # fullscreen, 1440p internal, saves in ./saves
#   SAVES=~/nfsmw-saves tools/run.sh      # saves/settings/cache somewhere else
#   SCALE=1 FULLSCREEN=false tools/run.sh # windowed, native 720p internal
#   tools/run.sh --gpu_backend=vulkan     # extra args go straight to the game
#
# Saves, settings (nfsmw.toml), and the shader cache all live under SAVES.
# Without --user_data_root the game would scatter them in ~/.local/share/nfsmw.
set -eu
cd "$(dirname "$0")/../build"

SAVES=${SAVES:-$PWD/saves}          # keep everything next to the game by default
SCALE=${SCALE:-2}                   # 2 = 2560x1440 internal; measured same fps as 1
FULLSCREEN=${FULLSCREEN:-true}
VSYNC=${VSYNC:-true}

mkdir -p "$SAVES"

exec ./nfsmw \
    --user_data_root="$SAVES" \
    --resolution_scale="$SCALE" \
    --fullscreen="$FULLSCREEN" \
    --vsync="$VSYNC" \
    "$@"
