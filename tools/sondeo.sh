#!/bin/bash
# FULL probe: takes the game from boot to the race all by itself.
#
# Each pass:
#   1. launches the game with a window (X11 so it can be sent keystrokes),
#   2. feeds it ENTER in a loop (start -> load save -> start race),
#   3. when it crashes, pulls the [FATAL] address out of the log
#      ("Call to invalid or unregistered function" or
#      "Unresolved call/branch from X to Y"),
#   4. declares it in app/huecos.toml, redoes codegen + build, and repeats.
#
# Everything runs on a VIRTUAL desktop (Xvfb on :99): the game window never
# appears on the user's screen, and the keystrokes injected by xdotool don't
# steal its focus either.
#
# Usage:  REXGLUE=... bash tools/sondeo.sh [passes]
set -u
cd "$(dirname "$0")/.."

REXGLUE=${REXGLUE:-rexglue}
DIR_APP=app
DIR_BUILD=build
TOPE=${1:-30}
# Seconds per pass: has to give enough time for start -> save -> load race
RUN_SEG=${RUN_SEG:-90}
DISPLAY_VIRTUAL=:99
RES_VIRTUAL=${RES_VIRTUAL:-1280x720x24}

if ! command -v "$REXGLUE" >/dev/null 2>&1; then
    echo "[ERROR] No encuentro rexglue en el PATH: export REXGLUE=/ruta/rexglue"
    exit 1
fi
if ! command -v xdotool >/dev/null 2>&1; then
    echo "[ERROR] falta xdotool (pacman -S xdotool)"
    exit 1
fi

# Virtual desktop; stays running between passes.
if ! DISPLAY=$DISPLAY_VIRTUAL timeout 1 xset q >/dev/null 2>&1; then
    Xvfb $DISPLAY_VIRTUAL -screen 0 "$RES_VIRTUAL" >/dev/null 2>&1 &
    XVFB_PID=$!
    sleep 2
    echo "Escritorio virtual en $DISPLAY_VIRTUAL (${RES_VIRTUAL})."
else
    XVFB_PID=""
fi
trap '[ -n "$XVFB_PID" ] && kill "$XFB_PID" 2>/dev/null' EXIT

for ((i=1; i<=TOPE; i++)); do
    rm -f "$DIR_BUILD/logs/nfsmw_"*.log 2>/dev/null

    # Launch with X11 on the virtual desktop
    ( cd "$DIR_BUILD" && DISPLAY=$DISPLAY_VIRTUAL timeout "$RUN_SEG" ./nfsmw --video_driver=x11 >/dev/null 2>&1 ) &
    JUEGO=$!

    # Spam A (Space with mnk_mode; keybind_a) while the game is alive:
    # skips menus AND cutscenes. Several presses per second. Focus is set
    # via XSetInputFocus (there's no window manager on the virtual desktop).
    ( while kill -0 "$JUEGO" 2>/dev/null; do
          VENTANA=$(DISPLAY=$DISPLAY_VIRTUAL xdotool search --name 'nfsmw' 2>/dev/null | head -1)
          if [ -n "$VENTANA" ]; then
              DISPLAY=$DISPLAY_VIRTUAL xdotool windowfocus --sync "$VENTANA" 2>/dev/null
              DISPLAY=$DISPLAY_VIRTUAL xdotool key --delay 60 space 2>/dev/null
              DISPLAY=$DISPLAY_VIRTUAL xdotool key --delay 60 Return 2>/dev/null
          fi
          sleep 0.25
      done ) &
    SPAM=$!

    wait "$JUEGO" 2>/dev/null
    kill "$SPAM" 2>/dev/null
    wait 2>/dev/null

    # 1) indirect call to an unregistered function
    DIR=$(grep -h "Call to invalid or unregistered function at guest address" \
              "$DIR_BUILD/logs/nfsmw_"*.log 2>/dev/null | tail -1 | grep -o "0x[0-9A-F]\{8\}" | tail -1)
    # 2) unresolved branch trap: import the TARGET (to)
    BRANCH=$(grep -hE "FATAL.*Unresolved (call|branch) from" \
                 "$DIR_BUILD/logs/nfsmw_"*.log 2>/dev/null | tail -1 | grep -o "to 0x[0-9A-F]\{8\}" | grep -o "0x[0-9A-F]\{8\}")
    DIR=${DIR:-$BRANCH}

    if [ -z "$DIR" ]; then
        echo "PASADA $i: sin FATAL. Corrida completa limpia."
        break
    fi
    if grep -q "\"$DIR\"" "$DIR_APP/huecos.toml"; then
        echo "PASADA $i: $DIR ya declarada pero sigue reventando. PARO."
        break
    fi
    echo "PASADA $i: declarando $DIR"

    if ! grep -q "SONDEO" "$DIR_APP/huecos.toml"; then
        printf '\n# --- SONDEO: destinos de llamada indirecta, aparecen al ejecutar ---\n' >> "$DIR_APP/huecos.toml"
    fi
    printf '"%s" = { }\n' "$DIR" >> "$DIR_APP/huecos.toml"

    ( cd "$DIR_APP" && "$REXGLUE" codegen nfsmw_manifest.toml > sondeo-codegen.log 2>&1 ) || {
        echo "[ERROR] Codegen fallo:"; tail -5 "$DIR_APP/sondeo-codegen.log"; exit 1; }
    ( cd "$DIR_APP" && cmake --build --preset linux-amd64-release > sondeo-build.log 2>&1 ) || {
        echo "[ERROR] Build fallo:"; tail -10 "$DIR_APP/sondeo-build.log"; exit 1; }
    cp "$DIR_APP/out/build/linux-amd64-release/nfsmw" "$DIR_BUILD/nfsmw"
    cp "$DIR_BUILD/nfsmw" "$DIR_APP/out/build/linux-amd64-release/nfsmw"
    echo "PASADA $i: rehacer y copiado listos."
done
