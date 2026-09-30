#!/bin/bash
# Runs the code generator on one edition tree and the two steps the build depends on.
#
#   REXGLUE=out/host/rexglue tools/codegen.sh app
#   REXGLUE=out/host/rexglue tools/codegen.sh app_usa app_usa/enganchadas.txt app_usa/tabla.tsv
#
# The second and third arguments are for the trees made by tools/editions/crear_arbol.py: the list of hooked
# functions of that edition and the address table used to create it (see docs/editions.md).
# Set PYTHON if the Python launcher is not "python" (on Windows it is usually "py").
set -e
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
APP=$RAIZ/${1:?usage: tools/codegen.sh <app folder> [hooked functions] [address table]}
REXGLUE=${REXGLUE:?set REXGLUE to the rexglue executable built from the SDK}
PY=${PYTHON:-$(command -v python3 || echo python)}
cd "$APP"
# First run: seed the function partition with the one the PAL English PGO profile was recorded with,
# so every nfsmw_recomp.N.cpp holds the functions its .gcda expects (tools/editions/pal_en/pal_en.py).
if [ ! -f generated/default/codegen.partition.json ]; then
  mkdir -p generated/default
  "$PY" "$RAIZ/tools/editions/pal_en/pal_en.py" reparto generated/default/codegen.partition.json
fi
echo "== codegen ($APP)"
"$REXGLUE" codegen nfsmw_manifest.toml > codegen.log 2>&1 || { echo "codegen failed, see $APP/codegen.log"; exit 1; }
cd "$RAIZ"
echo "== direct calls"
if [ -n "${2:-}" ]; then
  "$PY" tools/llamadas_directas.py --gen "$APP/generated/default" --enganchadas "$RAIZ/$2"
else
  "$PY" tools/llamadas_directas.py --gen "$APP/generated/default"
fi
echo "== literal copies"
if [ -n "${3:-}" ]; then
  "$PY" tools/copia_literal.py "$APP/generated/default" "$APP/src/copias_literales" --tabla "$RAIZ/$3"
else
  "$PY" tools/copia_literal.py "$APP/generated/default" "$APP/src/copias_literales"
fi
echo "done"
