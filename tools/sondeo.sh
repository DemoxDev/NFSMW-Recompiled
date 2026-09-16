#!/bin/bash
# Sondeo COMPLETO: lleva el juego del arranque hasta la carrera solito.
#
# Cada pasada:
#   1. lanza el juego con ventana (X11 para poder mandarle teclas),
#   2. le mete ENTER en bucle (start -> cargar save -> empezar carrera),
#   3. cuando revienta, saca del log la direccion del [FATAL]
#      ("Call to invalid or unregistered function" o
#      "Unresolved call/branch from X to Y"),
#   4. la declara en app/huecos.toml, rehace codegen + build, y repite.
#
# Todo corre en un escritorio VIRTUAL (Xvfb en :99): la ventana del juego
# nunca aparece en la pantalla del usuario y las teclas inyectadas por
# xdotool tampoco le roban el foco.
#
# Uso:  REXGLUE=... bash tools/sondeo.sh [pasadas]
set -u
cd "$(dirname "$0")/.."

REXGLUE=${REXGLUE:-rexglue}
DIR_APP=app
DIR_BUILD=build
TOPE=${1:-30}
# Segundos por pasada: tiene que dar tiempo a start -> save -> cargar carrera
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

# Escritorio virtual; queda corriendo entre pasadas.
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

    # Lanzar con X11 en el escritorio virtual
    ( cd "$DIR_BUILD" && DISPLAY=$DISPLAY_VIRTUAL timeout "$RUN_SEG" ./nfsmw --video_driver=x11 >/dev/null 2>&1 ) &
    JUEGO=$!

    # Spam de A (Space con mnk_mode; keybind_a) mientras el juego viva:
    # salta menus Y cutscenes. Varias pulsaciones por segundo. Con foco por
    # XSetInputFocus (no hay gestor de ventanas en el escritorio virtual).
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

    # 1) llamada indirecta a funcion no registrada
    DIR=$(grep -h "Call to invalid or unregistered function at guest address" \
              "$DIR_BUILD/logs/nfsmw_"*.log 2>/dev/null | tail -1 | grep -o "0x[0-9A-F]\{8\}" | tail -1)
    # 2) trampa de salto sin resolver: importa el OBJETIVO (to)
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
