#!/bin/bash
# Builds NFSMW natively for macOS (Apple Silicon) and assembles build/mac/:
#
#   build/mac/   ->   run ./nfsmw inside, drop your game files next to it
#
# Needs Xcode Command Line Tools (clang), cmake 3.25+, ninja, python 3.10+
# (brew install cmake ninja python), and the SDK checked out next to this
# repository. See docs/macos.md.
#
#   tools/build_mac.sh
#   REX_PYTHON=python3.12 tools/build_mac.sh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p logs
LOG=logs/construir-mac.log
exec > >(tee -a "$LOG") 2>&1

SDK_DIR=$(realpath ../rexglue-sdk)
SDK_BUILD=$SDK_DIR/out/build/mac-arm64
SDK_INSTALL=$SDK_DIR/out/install/mac-arm64
APP_BUILD=app/out/build/mac-arm64-release
DIST_DIR=${NFSMW_MAC_DIST_DIR:-build/mac}

# ---------------------------------------------------------------------------
# 0. Comprobaciones. Sin estas el build falla a mitad, peor.
# ---------------------------------------------------------------------------
fase_comprobaciones() {
    echo "== 0. Comprobaciones =="
    local py
    if [ -n "${REX_PYTHON:-}" ]; then
        py=$REX_PYTHON
    else
        for py in python3.12 python3.11 python3; do
            command -v "$py" >/dev/null 2>&1 && break
        done
    fi
    command -v "$py" >/dev/null 2>&1 || {
        echo "[ERROR] No encuentro Python (necesito >= 3.10 para los parches)."; exit 1; }
    if ! "$py" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)'; then
        echo "[ERROR] $py no es 3.10+. brew install python, o REX_PYTHON=python3.12."; exit 1
    fi
    REX_PYTHON=$py
    for tool in clang clang++ cmake ninja git install_name_tool codesign otool lipo; do
        command -v "$tool" >/dev/null 2>&1 || { echo "[ERROR] Falta $tool."; exit 1; }
    done
    cmake --version | head -1 | grep -qE 'cmake version (3\.(2[5-9]|[3-9][0-9])|[4-9])' \
        || { echo "[ERROR] CMake 3.25+ requerido."; exit 1; }
    [ -d "$SDK_DIR/src/graphics" ] || { echo "[ERROR] No veo $SDK_DIR."; exit 1; }
    # El SDK de la CLI de Xcode puede ser mas nuevo que su compilador (el tbd del
    # MacOSX27.0.sdk no lo parsea el tapi de Xcode 26) y el enlace falla a mitad
    # del build. Anclar SDKROOT al SDK de Xcode; si el usuario ya fijó el suyo,
    # se respeta.
    if [ -z "${SDKROOT:-}" ]; then
        local dev sdk
        dev=$(xcode-select -p 2>/dev/null || true)
        if [ -n "$dev" ] && [ -d "$dev/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" ]; then
            SDKROOT=$dev/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
        elif sdk=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null) && [ -n "$sdk" ] && [ -d "$sdk" ]; then
            SDKROOT=$sdk
        else
            echo "[ERROR] No encuentro un SDK de macOS util (¿falta Xcode?)."
            echo "        Exporta SDKROOT a mano: SDKROOT=\$(xcrun --sdk macosx --show-sdk-path) tools/build_mac.sh"
            exit 1
        fi
        export SDKROOT
        echo "   SDKROOT: $SDKROOT"
    fi
    echo "   python: $REX_PYTHON   clang: $(clang --version | head -1)"
}

# ---------------------------------------------------------------------------
# 1. Submódulos del SDK. La primera vez tarda: FFmpeg y MoltenVK pesan.
# ---------------------------------------------------------------------------
fase_submodulos() {
    echo "== 1. Submódulos del SDK =="
    local req="cli11 libmspack FFmpeg tomlplusplus simde xxHash spdlog fmt utfcpp imgui sdl3 \
vulkan-headers vulkan-memory-allocator spirv-headers spirv-tools glslang vulkan-loader moltenvk"
    local missing=""
    for m in $req; do
        [ -n "$(ls -A "$SDK_DIR/thirdparty/$m" 2>/dev/null)" ] || missing="$missing $m"
    done
    if [ -n "${missing:-}" ]; then
        echo "   Init submódulos:$missing"
        git -C "$SDK_DIR" submodule update --init --recursive
    fi
    for m in $req; do
        [ -n "$(ls -A "$SDK_DIR/thirdparty/$m" 2>/dev/null)" ] || {
            echo "[ERROR] El submódulo $m quedó vacío. Revisa la red y vuelve."; exit 1; }
    done
}

# ---------------------------------------------------------------------------
# 2. Parches. Idempotentes; el orden es el de CONSTRUIR.bat y no es capricho
#    (anillo va antes que desatasco, que usa lo que anillo añade).
#    parche_fotogramas es el décimo y último, y no está en CONSTRUIR.bat: es
#    el parche LOCAL del contador de fotogramas que la app lee para el [fps]
#    y que nunca llegó al SDK puro (v0.10.0).
# ---------------------------------------------------------------------------
fase_parches() {
    echo "== 2. Parches del SDK =="
    local parches="parche_diagnostico parche_anillo parche_desatasco parche_presentador \
parche_gpu_fallback parche_restaurar parche_velocidad parche_backend parche_privilegios \
parche_fotogramas"
    local p
    for p in $parches; do
        echo "   $p"
        "$REX_PYTHON" "tools/$p.py" || {
            echo "[ERROR] Falló $p. Mira tools/$p.py --estado y docs/parches.md."; exit 1; }
    done
}

# ---------------------------------------------------------------------------
# 3. SDK: configurar con Vulkan ON, compilar e instalar. El install deja en
#    SDK_INSTALL el CLI rexglue, las dylibs y el stack Vulkan->MoltenVK
#    (lib/libvulkan.1.dylib, lib/libMoltenVK.dylib, share/vulkan/icd.d/).
# ---------------------------------------------------------------------------
fase_sdk() {
    echo "== 3. SDK (mac-arm64) =="
    cmake --preset mac-arm64 -S "$SDK_DIR" -DREXGLUE_USE_VULKAN=ON
    cmake --build "$SDK_BUILD" --config Release --target install
    local f
    for f in bin/rexglue lib/libvulkan.1.dylib lib/libMoltenVK.dylib \
             share/vulkan/icd.d/MoltenVK_icd.json; do
        [ -f "$SDK_INSTALL/$f" ] || { echo "[ERROR] Falta $SDK_INSTALL/$f."; exit 1; }
    done
    # El runtime y el plugin: dylib si son compartidas (lo normal fuera de
    # Switch); si el build mac las saca estaticas, van dentro del binario.
    ls "$SDK_INSTALL"/lib/librexruntime.* >/dev/null 2>&1 \
        || { echo "[ERROR] No hay librexruntime en $SDK_INSTALL/lib."; exit 1; }
    ls "$SDK_INSTALL"/lib/librexgpu-xenos* >/dev/null 2>&1 \
        || { echo "[ERROR] No hay librexgpu-xenos en $SDK_INSTALL/lib."; exit 1; }
    ls "$SDK_INSTALL"/lib/libSDL3*.dylib >/dev/null 2>&1 \
        || echo "[AVISO] No hay libSDL3*.dylib en SDK_INSTALL/lib; lo revisa la fase app."
}

fase_comprobaciones
fase_submodulos
fase_parches
fase_sdk

# ---------------------------------------------------------------------------
# 4. App: dos pasadas. La primera solo codegen: reescribe nfsmw_pch.h y en
#    una sola pasada ninja enlazaria con el PCH viejo (CONSTRUIR.bat lo
#    documenta; el fallo tipico es 'nfsmw_pch.h has been modified').
# ---------------------------------------------------------------------------
fase_app() {
    echo "== 4. App (mac-arm64-release) =="
    cmake --preset mac-arm64-release -S app -DCMAKE_PREFIX_PATH="$SDK_INSTALL"
    # Los presets del build viven en app/CMakePresets.json: cmake --build
    # --preset los busca en el cwd, asi que la pasada se lanza desde app.
    ( cd app && cmake --build --preset mac-arm64-release --target nfsmw_codegen )
    ( cd app && cmake --build --preset mac-arm64-release )
}

fase_app
echo
echo "Done (fases 0-4). Sigue: fase_dist (Task 4)."
