# macOS Vulkan→MoltenVK — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native Apple Silicon macOS build of NFSMW that renders through the SDK's existing Vulkan backend on MoltenVK, produced by `tools/build_mac.sh` into a self-contained `build/mac/` folder and an `NFSMW.app` bundle.

**Architecture:** No new GPU backend. The SDK already ships macOS support (SDL3 windowing, posix core layers, `vulkan_moltenvk.cpp` runtime detection, CAMetalLayer surfaces). The work is the pipeline: init SDK submodules, apply the nine patches, build+install the SDK for `mac-arm64` with the vendored Vulkan→MoltenVK stack, build the app, and assemble a dist folder that keeps the SDK-prefix relative layout so the shipped ICD and the runtime's own detection work as-is.

**Tech Stack:** C++23, CMake 3.25+/Ninja, Apple clang, Python 3.10+, SDL3, Vulkan loader + MoltenVK (both built from the SDK's pinned submodules), `install_name_tool`/`codesign` for bundling.

**Spec:** `docs/superpowers/specs/2026-09-19-macos-moltenvk-design.md` (app repo). All paths below are in the app repo `/Users/chris/Documents/Projects/NFSMW-Recompiled` unless prefixed `SDK/` = `/Users/chris/Documents/Projects/rexglue-sdk` (checked out at `../rexglue-sdk`, branch `main`, v0.10.0). Branch: `macos-vulkan` (already checked out).

## Global Constraints

- Target: `mac-arm64` presets, this machine's Apple Silicon. Intel (`mac-amd64`) is out of scope.
- SDK repo gets **no source changes**: the nine patches are pre-existing scripts applied to the SDK working tree (`git -C ../rexglue-sdk status` must show only their edits). All commits happen in the app repo.
- Patch order is fixed (`CONSTRUIR.bat:161-212`): `parche_diagnostico`, `parche_anillo`, `parche_desatasco`, `parche_presentador`, `parche_gpu_fallback`, `parche_restaurar`, `parche_velocidad`, `parche_backend`, `parche_privilegios`. If any anchor fails to match exactly once, STOP and fix the patch per `docs/parches.md` — never hand-edit the SDK.
- SDK configure command: `cmake --preset mac-arm64 -S "$SDK" -DREXGLUE_USE_VULKAN=ON` (Vulkan is default-ON off-Windows; pass it explicitly anyway, as `CONSTRUIR.bat` does). SDK build/install: `cmake --build "$SDK/out/build/mac-arm64" --config Release --target install` (Ninja Multi-Config). Install prefix: `$SDK/out/install/mac-arm64`.
- App configure: `cmake --preset mac-arm64-release -S app -DCMAKE_PREFIX_PATH="$SDK/out/install/mac-arm64"` (single-config Ninja; binary dir `app/out/build/mac-arm64-release`). Two passes, per `CONSTRUIR.bat` comment: `--target nfsmw_codegen` first, then the full build — codegen rewrites `generated/default/nfsmw_pch.h`, and a single pass makes ninja link against a stale PCH.
- Dist folder layout mirrors the SDK install prefix: binary at the root, dylibs in `lib/`, ICD at `share/vulkan/icd.d/MoltenVK_icd.json` shipped verbatim (its `library_path` `../../../lib/libMoltenVK.dylib` resolves inside the folder). RPATHs `@executable_path` (binary) / `@loader_path` (dylibs). Every modified binary/dylib gets re-signed ad-hoc (`codesign -f -s -`) — Apple Silicon refuses modified unsigned binaries.
- Dist ships no game data: reject `*.iso`, `*.xex`, `*.xexp`, `default.xex`, and `NFS/`/`Movies/` folders (mirror of `comprobar_dist.ps1`).
- Python: system `python3` is 3.9.6; the script picks `REX_PYTHON` env, then `python3.12`, `python3.11`, then `python3` — failing loudly if the chosen interpreter is < 3.10.
- Commits: Conventional Commits, imperative, ≤72 chars, no attribution trailers.

## Review Focus

The five inputs most likely to bite, and the tests that pin each to its owning task:

1. **Clean-checkout reproducibility / idempotency** — running `tools/build_mac.sh` twice must be a no-op the second time (submodules already init, patches say "already applied", builds rebuild nothing but re-link). Test: Task 2 Step 5 + Task 4 Step 6 run the full script twice.
2. **Dist self-containment** — moving the dist folder elsewhere must not break it (no absolute-path install names). Test: Task 4 Step 7 copies `build/mac` to `/tmp` and boots from there.
3. **Game data leak** — a `.iso`/`default.xex`/`NFS/` landing in the dist must make `comprobar_dist.sh` exit non-zero. Test: Task 4 Step 6 plants a fake `default.xex` and expects failure.
4. **Stale codegen after manifest change** — touching `app/nfsmw_manifest.toml` and rebuilding must succeed cleanly thanks to the two-pass order (the classic PCH failure is `fatal error: file 'nfsmw_pch.h' has been modified...`). Test: Task 3 Step 7.
5. **Bundled .app without argv** — Finder launches pass no flags; the game must find the game files beside the executable (`Contents/MacOS/game_root/` or an ISO), same search `nfsmw_app.h` does on Windows. Test: Task 5 Step 6 boots the bundle by direct exec without `--game_data_root` after dropping a `game_root` link into `Contents/MacOS/`.

---

### Task 1: Restore executable bits lost on the macOS checkout

**Files:**
- Modify (mode only): `packaging/appimage/AppRun`, `packaging/appimage/build-appimage-arm64.sh`, `tools/build_switch.sh`, `tools/run.sh`, `tools/sondeo.sh`

**Interfaces:**
- Produces: working-tree cleanliness for the scripts later tasks create; no content changes anywhere.

- [ ] **Step 1: Verify the working tree is only mode noise**

Run: `git status --short && git diff`
Expected: five `M` entries, all `old mode 100755 / new mode 100644`, no content hunks; `tools/switch-glspike/` untracked (leave it alone).

- [ ] **Step 2: Restore the modes**

```bash
chmod +x packaging/appimage/AppRun packaging/appimage/build-appimage-arm64.sh \
         tools/build_switch.sh tools/run.sh tools/sondeo.sh
```

- [ ] **Step 3: Verify clean**

Run: `git status --short`
Expected: only `?? tools/switch-glspike/` remains.

- [ ] **Step 4: Commit**

```bash
git add packaging/appimage/AppRun packaging/appimage/build-appimage-arm64.sh \
        tools/build_switch.sh tools/run.sh tools/sondeo.sh
git commit -m "fix: restore executable bits lost on macOS checkout"
```

---

### Task 2: `tools/build_mac.sh` — environment, submodules, patches, SDK with the MoltenVK stack

**Files:**
- Create: `tools/build_mac.sh`

**Interfaces:**
- Produces (used by Tasks 3–5): the script with phases `fase_comprobaciones`, `fase_submodulos`, `fase_parches`, `fase_sdk`, and these variables: `REX_PYTHON` (chosen interpreter), `SDK_DIR=../rexglue-sdk`, `SDK_BUILD=$SDK_DIR/out/build/mac-arm64`, `SDK_INSTALL=$SDK_DIR/out/install/mac-arm64`. Later tasks append `fase_app`, `fase_dist`, `fase_bundle` — the script runs every defined phase in order.

- [ ] **Step 1: Write the script**

`tools/build_mac.sh`:

```bash
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
# ---------------------------------------------------------------------------
fase_parches() {
    echo "== 2. Parches del SDK =="
    local parches="parche_diagnostico parche_anillo parche_desatasco parche_presentador \
parche_gpu_fallback parche_restaurar parche_velocidad parche_backend parche_privilegios"
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
echo
echo "Done (fases 0-3). Sigue: fase_app (Task 3)."
```

- [ ] **Step 2: Make it executable and run it**

```bash
chmod +x tools/build_mac.sh
tools/build_mac.sh
```

Expected: phases 0–3 complete; first run is long (submodule fetch, MoltenVK from source). Known failure modes and remedies: FFmpeg assembler errors → `brew install nasm` and re-run; a patch anchor failure → read the failing anchor per `docs/parches.md`; MoltenVK build errors → record the error, check the pinned commit builds on Apple clang (it must — the SDK pins it), and stop for diagnosis rather than improvising flags.

- [ ] **Step 3: Verify the SDK install prefix**

Run:
```bash
ls ../rexglue-sdk/out/install/mac-arm64/bin/rexglue \
   ../rexglue-sdk/out/install/mac-arm64/lib/libvulkan.1.dylib \
   ../rexglue-sdk/out/install/mac-arm64/lib/libMoltenVK.dylib \
   ../rexglue-sdk/out/install/mac-arm64/share/vulkan/icd.d/MoltenVK_icd.json
otool -L ../rexglue-sdk/out/install/mac-arm64/lib/libvulkan.1.dylib | head -5
```
Expected: all four files exist; `libvulkan.1.dylib` links system libs only (it is the loader; MoltenVK is the ICD, loaded at runtime via the ICD json).

- [ ] **Step 4: Verify patch state**

Run: `for p in tools/parche_*.py; do python3.12 "$p" --estado; done | grep -c aplicado` — replace the interpreter with the one the script chose.
Expected: the nine patches report applied (grep count ≥ 9; report the exact count).

- [ ] **Step 5: Verify idempotency**

Run: `tools/build_mac.sh` again.
Expected: submodule phase says nothing to init, patches say already-applied and touch nothing, SDK configure/build no-op in seconds, exits 0.

- [ ] **Step 6: Commit**

```bash
git add tools/build_mac.sh
git commit -m "build(macos): bootstrap script builds the SDK with the MoltenVK stack"
```

---

### Task 3: App builds on mac and boots with the Vulkan backend on MoltenVK

**Files:**
- Modify: `tools/build_mac.sh` (append `fase_app`)

**Interfaces:**
- Consumes: `SDK_INSTALL` from Task 2 (the SDK package config there: `rex::runtime`, `rex::gpu-xenos`, `rex::rexglue`, `SDL3::SDL3`, `rex::vulkan-loader`, `rex::moltenvk`, `REXGLUE_MOLTENVK_ICD`).
- Produces: `fase_app` phase in the script; artifacts in `app/out/build/mac-arm64-release/` (`nfsmw`, plus the runtime/GPU-plugin dylibs); a boot log under the build dir proving MoltenVK rendering.

- [ ] **Step 1: Configure the app**

Run:
```bash
cmake --preset mac-arm64-release -S app -DCMAKE_PREFIX_PATH="$(realpath ../rexglue-sdk/out/install/mac-arm64)"
```
Expected: configure succeeds; `find_package(rexglue)` resolves from the SDK install prefix. Failure mode to expect and fix: `find_package` misses the registry on a fresh machine — that is why `CMAKE_PREFIX_PATH` is passed explicitly here.

- [ ] **Step 2: Two-pass build**

Run:
```bash
cmake --build --preset mac-arm64-release --target nfsmw_codegen
cmake --build --preset mac-arm64-release
```
Expected: codegen generates `app/generated/default/` (131 files pattern per `docs/02-codegen.md`), then the build links `nfsmw`. A PCH-size mismatch error here means the two-pass order was violated — re-run pass 1 then pass 2.

- [ ] **Step 3: Inventory the artifacts**

Run:
```bash
ls -la app/out/build/mac-arm64-release/ | grep -E 'nfsmw|\.dylib'
otool -L app/out/build/mac-arm64-release/nfsmw | grep -E 'librex|libSDL3'
```
Expected: `nfsmw` binary plus `librexruntime.dylib` and `librexgpu-xenos.dylib` next to it (the same files the Windows dist globs, per `hacer_dist.cmake`). If the dylibs are NOT in the build dir, note exactly which SDK install path they live in (`SDK_INSTALL/lib`) — Task 4's dist step uses the build-dir copies when present and falls back to `SDK_INSTALL/lib`.

- [ ] **Step 4: Boot test**

Run:
```bash
cd app/out/build/mac-arm64-release
mkdir -p boot-test
./nfsmw --game_data_root="$(realpath ../../../../assets/game_root)" \
        --user_data_root="$PWD/boot-test" --fullscreen=false &
GAME_PID=$!
sleep 75
kill "$GAME_PID" 2>/dev/null || true
sleep 2; pkill -x nfsmw 2>/dev/null || true
ls -t logs/nfsmw_*.log boot-test/logs/nfsmw_*.log 2>/dev/null | head -1
```
Expected: a window opens (SDL3/Cocoa); the newest log file prints a boot sequence that reaches `[fps]` lines.

- [ ] **Step 5: Verify the log**

With the newest log path from Step 4:
```bash
LOG=$(ls -t logs/nfsmw_*.log boot-test/logs/nfsmw_*.log 2>/dev/null | head -1)
grep -E '\[fps\]' "$LOG" | head -3
grep -cE '\[error\]' "$LOG"
grep -iE 'apple m[0-9]|molv|vulkan' "$LOG" | head -5
```
Expected: `[fps]` lines present (frame counting — the game is running), zero `[error]` lines, and a Vulkan instance/device line whose GPU name is an Apple M-series device (proving the MoltenVK stack is the driver). If rendering is black but the log is clean, record the exact device/present lines in `docs/macos.md` troubleshooting and continue — driver diagnosis gets its own loop like Task 5 of the Switch plan.

- [ ] **Step 6: Verify the two-pass recovers a stale codegen**

Run:
```bash
touch app/nfsmw_manifest.toml
cmake --build --preset mac-arm64-release --target nfsmw_codegen
cmake --build --preset mac-arm64-release
```
Expected: codegen re-runs (its DEPFILE notices the manifest), PCH rebuilt first, full build clean.

- [ ] **Step 7: Append the phase and commit**

Append to `tools/build_mac.sh` before the final `echo` lines:

```bash
# ---------------------------------------------------------------------------
# 4. App: dos pasadas. La primera solo codegen: reescribe nfsmw_pch.h y en
#    una sola pasada ninja enlazaria con el PCH viejo (CONSTRUIR.bat lo
#    documenta; el fallo tipico es 'nfsmw_pch.h has been modified').
# ---------------------------------------------------------------------------
fase_app() {
    echo "== 4. App (mac-arm64-release) =="
    cmake --preset mac-arm64-release -S app -DCMAKE_PREFIX_PATH="$SDK_INSTALL"
    cmake --build --preset mac-arm64-release --target nfsmw_codegen
    cmake --build --preset mac-arm64-release
}

fase_app
```
(Keep the trailing `fase_app` call after the four existing calls; adjust the final echo to "Done (fases 0-4). Sigue: fase_dist (Task 4).")

```bash
git add tools/build_mac.sh
git commit -m "build(macos): build and boot the game with the Vulkan backend"
```

---

### Task 4: `mac_dist` — the self-contained `build/mac/` folder

**Files:**
- Create: `packaging/macos/relink.sh`
- Create: `packaging/macos/comprobar_dist.sh`
- Create: `packaging/macos/README.txt`
- Create: `app/cmake/hacer_dist_mac.cmake`
- Modify: `app/CMakeLists.txt` (append the APPLE branch at the end)

**Interfaces:**
- Consumes: `nfsmw` target (Task 3); SDK package variables `rex::vulkan-loader`, `rex::moltenvk`, `SDL3::SDL3`, `REXGLUE_MOLTENVK_ICD`; `hacer_dist.cmake`'s conventions (script mode via `-P`, `D_*` vars).
- Produces: `mac_dist` CMake target and `NFSMW_MAC_DIST_DIR` cache var (default `build/mac`); the folder Task 5 bundles; `comprobar_dist.sh` (reused by Task 5's bundle check).

- [ ] **Step 1: Write the relink helper**

`packaging/macos/relink.sh`:

```bash
#!/bin/bash
# Rewrites the dist's dylib references to @rpath and ad-hoc re-signs everything.
# Usage: relink.sh <dist-dir>
set -euo pipefail
DIST="$1"; cd "$DIST"
shopt -s nullglob
libs=(nfsmw lib/*.dylib)

# 1. IDs: every shipped dylib answers to @rpath/<name>.
for f in lib/*.dylib; do
    install_name_tool -id "@rpath/$(basename "$f")" "$f"
done

# 2. Deps: a reference to a dylib we ship becomes @rpath/<name>.
#    System dylibs (not shipped) keep their absolute paths: they exist on
#    every mac. The guard is "is there a file of that name in lib/".
rewrite_deps() {
    local f="$1" dep name
    otool -L "$f" | awk 'NR>2 {print $1}' | while IFS= read -r dep; do
        name=$(basename "$dep")
        [ -f "lib/$name" ] || continue
        install_name_tool -change "$dep" "@rpath/$name" "$f"
    done
}
for f in "${libs[@]}"; do rewrite_deps "$f"; done

# 3. RPATH: dylibs find each other via @loader_path, the binary via @executable_path.
for f in lib/*.dylib; do
    install_name_tool -add_rpath "@loader_path" "$f" 2>/dev/null || true
done
install_name_tool -add_rpath "@executable_path" nfsmw 2>/dev/null || true

# 4. Re-sign ad hoc. Apple Silicon refuses modified binaries with stale
#    signatures: without this the game dies at exec.
codesign -f -s - nfsmw lib/*.dylib
```

- [ ] **Step 2: Write the check**

`packaging/macos/comprobar_dist.sh`:

```bash
#!/bin/bash
# Verifies the dist is self-contained and carries no game data.
# Usage: comprobar_dist.sh <dist-dir> ; exits non-zero on the first problem.
set -euo pipefail
DIST="$1"; cd "$DIST"
shopt -s nullglob

# 1. Game data must not travel (mirror of comprobar_dist.ps1).
for bad in *.iso *.xex *.xexp default.xex NFS Movies; do
    for hit in $bad; do
        [ -e "$hit" ] || continue
        echo "[ERROR] game data in the dist: $hit"; exit 1
    done
done

# 2. Every @rpath reference resolves inside the folder; nothing that should
#    be relocatable is left with an absolute path.
check_file() {
    local f="$1" dep name rc=0
    while IFS= read -r dep; do
        name=$(basename "$dep")
        case "$dep" in
            @rpath/*)
                [ -f "lib/$name" ] || { echo "[ERROR] $f: missing $dep"; rc=1; } ;;
            *librexruntime*|*librexgpu*|*libSDL3*|*libMoltenVK*|*libvulkan*|*libSPIRV*)
                echo "[ERROR] $f: not relocatable: $dep"; rc=1 ;;
        esac
    done < <(otool -L "$f" | awk 'NR>2 {print $1}')
    return $rc
}
check_file nfsmw
for f in lib/*.dylib; do check_file "$f"; done

# 3. The binary is arm64.
lipo -archs nfsmw | grep -q arm64 || { echo "[ERROR] nfsmw is not arm64"; exit 1; }

echo "Comprobar_dist: OK ($(pwd))"
```

- [ ] **Step 3: Write the README**

`packaging/macos/README.txt` (mirror `packaging/switch/README.txt`'s structure):

```
NFS Most Wanted Recompiled - macOS (Apple Silicon)
==================================================

EXPERIMENTAL: the game runs and renders through Vulkan on MoltenVK
(Khronos' Vulkan implementation of Apple's Metal).

WHERE THINGS GO
  This whole folder is self-contained:

    build/mac/
      nfsmw                 the game
      lib/                  dylibs: runtime, GPU plugin, SDL3, Vulkan
                            loader, MoltenVK (do not delete any)
      share/vulkan/icd.d/   MoltenVK_icd.json (points at ../lib)
      nfsmw.toml            settings, same format as on PC
      README.txt            this file
      game/  saves/  logs/  yours

  Put YOUR game files next to nfsmw, either a disc image (an .iso is
  read in place) or the extracted folder named game_root:
      game_root/default.xex   must exist

LAUNCHING
  From a terminal:
      ./nfsmw
  or with flags (everything is overridable):
      ./nfsmw --game_data_root=/path/to/game --user_data_root="$PWD/saves"

  Quit with Cmd+Q (or the window close button).

TROUBLE
  The log is logs/nfsmw_NNN.log. If the screen stays black with
  gpu_backend = "vulkan", try "null" in nfsmw.toml (no rendering, but the
  game runs) and send the log with the report.
```

- [ ] **Step 4: Write the dist script**

`app/cmake/hacer_dist_mac.cmake`:

```cmake
# =============================================================================
#  hacer_dist_mac.cmake - arma la carpeta autocontenida  build/mac/
#
#  Lo lanza el target "mac_dist" de app/CMakeLists.txt en modo script (-P).
#  El layout replica el del install del SDK (lib/, share/vulkan/icd.d/) para
#  que el ICD que viaja dentro y la deteccion propia del runtime (vulkan_
#  moltenvk.cpp) funcionen tal cual. El ejecutable conserva el nombre
#  nfsmw, que es como lo llama tools/run.sh en Linux.
#
#  LA ISO NO SE COPIA: igual que en Windows, el usuario pone su juego (un
#  .iso o la carpeta game_root/) junto al binario. comprobar_dist.sh se
#  niega a dar la carpeta por buena si viaja cualquier cosa que parezca
#  juego.
# =============================================================================
cmake_minimum_required(VERSION 3.25)

foreach(v D_DIST D_EXE D_BUILD D_SDK_INSTALL D_VULKAN_LOADER D_MOLTENVK
           D_SDL3 D_ICD D_CONFIG D_README D_PACKAGING)
    if(NOT DEFINED ${v})
        message(FATAL_ERROR "hacer_dist_mac.cmake: falta ${v}")
    endif()
endforeach()

file(REMOVE_RECURSE "${D_DIST}")
file(MAKE_DIRECTORY "${D_DIST}" "${D_DIST}/lib" "${D_DIST}/share/vulkan/icd.d")

# ---- El juego ---------------------------------------------------------------
execute_process(COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${D_EXE}" "${D_DIST}/nfsmw")

# ---- Dylibs del proyecto: del build dir, o del install del SDK ---------------
#  Igual que en Windows (hacer_dist.cmake), rexruntime y el plugin de GPU se
#  cargan en runtime (dlopen) y no figuran en las dependencias del enlazador:
#  hay que copiarlos a mano. Salen del directorio de compilacion si el helper
#  del SDK los copia junto al exe; si no, del install del SDK. Si el runtime
#  solo existe como estatica (.a) van dentro del binario y no hay nada que
#  llevar: no es error.
set(DYLIBS)
file(GLOB DYLIBS "${D_BUILD}/*.dylib")
foreach(n librexruntime librexgpu-xenos)
    file(GLOB hit "${D_BUILD}/${n}*.dylib")
    if(NOT hit)
        file(GLOB hit "${D_SDK_INSTALL}/lib/${n}*.dylib")
    endif()
    if(hit)
        list(APPEND DYLIBS ${hit})
    elseif(NOT EXISTS "${D_SDK_INSTALL}/lib/${n}.a")
        message(FATAL_ERROR "hacer_dist_mac.cmake: no encuentro ${n} ni dylib ni "
                            "estatica (busque en ${D_BUILD} y ${D_SDK_INSTALL}/lib)")
    endif()
endforeach()
endif()
foreach(dylib IN LISTS DYLIBS)
    file(COPY "${dylib}" DESTINATION "${D_DIST}/lib")
endforeach()

# ---- Stack Vulkan->MoltenVK y SDL3, del install del SDK ----------------------
#  El ICD viaja intacto: su library_path es ../../../lib/libMoltenVK.dylib,
#  que resuelve dentro de la carpeta. SDL3 solo si es dylib (si salio
#  estatica no hay nada que llevar).
if(NOT "${D_VULKAN_LOADER}" STREQUAL "")
    file(COPY "${D_VULKAN_LOADER}" DESTINATION "${D_DIST}/lib")
endif()
if(NOT "${D_MOLTENVK}" STREQUAL "")
    file(COPY "${D_MOLTENVK}" DESTINATION "${D_DIST}/lib")
endif()
if("${D_SDL3}" MATCHES "\\.dylib$")
    file(COPY "${D_SDL3}" DESTINATION "${D_DIST}/lib")
endif()
if(NOT "${D_ICD}" STREQUAL "")
    file(COPY "${D_ICD}" DESTINATION "${D_DIST}/share/vulkan/icd.d/")
endif()

# ---- Config y README ---------------------------------------------------------
file(COPY "${D_CONFIG}" DESTINATION "${D_DIST}")
file(COPY "${D_README}" DESTINATION "${D_DIST}")

# ---- Relink y comprobacion ---------------------------------------------------
execute_process(COMMAND "${D_PACKAGING}/relink.sh" "${D_DIST}"
    RESULT_VARIABLE rc COMMAND_ECHO STDOUT)
if(NOT rc EQUAL 0)
    message(FATAL_ERROR "hacer_dist_mac.cmake: relink.sh fallo (${rc})")
endif()
execute_process(COMMAND "${D_PACKAGING}/comprobar_dist.sh" "${D_DIST}"
    RESULT_VARIABLE rc COMMAND_ECHO STDOUT)
if(NOT rc EQUAL 0)
    message(FATAL_ERROR "hacer_dist_mac.cmake: comprobar_dist.sh fallo (${rc})")
endif()
```

- [ ] **Step 5: Wire the target**

Append to `app/CMakeLists.txt` (after the WIN32 `dist` block):

```cmake
# =============================================================================
#  macOS - mac_dist: carpeta autocontenida en build/mac, con el layout del
#  install del SDK (lib/, share/vulkan/icd.d/) para que el ICD que viaja y
#  la deteccion propia del runtime (src/ui/vulkan/vulkan_moltenvk.cpp)
#  funcionen sin cambios. Ver docs/macos.md.
# =============================================================================
if(APPLE)
    if(NOT DEFINED NFSMW_MAC_DIST_DIR)
        set(NFSMW_MAC_DIST_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../build/mac")
    endif()
    find_package(SDL3 CONFIG REQUIRED)
    add_custom_target(mac_dist
        DEPENDS nfsmw
        COMMAND ${CMAKE_COMMAND}
                -D "D_EXE=$<TARGET_FILE:nfsmw>"
                -D "D_BUILD=$<TARGET_FILE_DIR:nfsmw>"
                -D "D_SDK_INSTALL=${rexglue_DIR}"
                -D "D_VULKAN_LOADER=$<TARGET_FILE:rex::vulkan-loader>"
                -D "D_MOLTENVK=$<TARGET_FILE:rex::moltenvk>"
                -D "D_SDL3=$<TARGET_FILE:SDL3::SDL3>"
                -D "D_ICD=${REXGLUE_MOLTENVK_ICD}"
                -D "D_CONFIG=${CMAKE_CURRENT_SOURCE_DIR}/nfsmw.toml"
                -D "D_README=${CMAKE_CURRENT_SOURCE_DIR}/../packaging/macos/README.txt"
                -D "D_PACKAGING=${CMAKE_CURRENT_SOURCE_DIR}/../packaging/macos"
                -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/hacer_dist_mac.cmake"
        COMMENT "Armando la carpeta autocontenida en ${NFSMW_MAC_DIST_DIR}"
        VERBATIM)
endif()
```

- [ ] **Step 6: Assemble and verify**

Run:
```bash
cmake --build --preset mac-arm64-release --target mac_dist
packaging/macos/comprobar_dist.sh build/mac
```
Expected: the folder assembles, the check prints `Comprobar_dist: OK`.

Leak-check test: plant a fake game file and expect failure:
```bash
touch build/mac/default.xex
packaging/macos/comprobar_dist.sh build/mac && echo "SHOULD HAVE FAILED" || echo "rejected OK"
rm build/mac/default.xex
cmake --build --preset mac-arm64-release --target mac_dist   # rebuild clean
```
Expected: the planted file makes the check exit non-zero; the rebuild comes back clean.

- [ ] **Step 7: Boot from the dist**

Run:
```bash
cd build/mac
./nfsmw --user_data_root="$PWD/saves" --fullscreen=false &
GAME_PID=$!
sleep 75
kill "$GAME_PID" 2>/dev/null || true
sleep 2; pkill -x nfsmw 2>/dev/null || true
grep -E '\[fps\]' logs/nfsmw_*.log saves/logs/nfsmw_*.log 2>/dev/null | head -3
grep -cE '\[error\]' logs/nfsmw_*.log saves/logs/nfsmw_*.log 2>/dev/null
```
Expected: `[fps]` lines, zero `[error]`.

- [ ] **Step 8: Boot the moved folder (self-containment)**

Run:
```bash
rm -rf /tmp/nfsmw-dist-check
cp -R build/mac /tmp/nfsmw-dist-check
cd /tmp/nfsmw-dist-check
./nfsmw --user_data_root="$PWD/saves" --fullscreen=false &
GAME_PID=$!
sleep 75
kill "$GAME_PID" 2>/dev/null || true
sleep 2; pkill -x nfsmw 2>/dev/null || true
grep -E '\[fps\]' logs/nfsmw_*.log saves/logs/nfsmw_*.log 2>/dev/null | head -3
```
Expected: the game boots and renders from `/tmp` — no absolute-path dependency survived the copy. Clean up: `rm -rf /tmp/nfsmw-dist-check`.

- [ ] **Step 9: Wire the phase, commit**

Append to `tools/build_mac.sh`:

```bash
# ---------------------------------------------------------------------------
# 5. La carpeta build/mac. El juego viaja sin datos: el usuario pone su
#    .iso o su game_root/ junto al binario. comprobar_dist.sh lo verifica.
# ---------------------------------------------------------------------------
fase_dist() {
    echo "== 5. mac_dist =="
    cmake --build --preset mac-arm64-release --target mac_dist
}
fase_dist
```
(Trailing call after `fase_app`; final echo now "Done (fases 0-5).")

```bash
git add tools/build_mac.sh app/CMakeLists.txt app/cmake/hacer_dist_mac.cmake \
        packaging/macos/relink.sh packaging/macos/comprobar_dist.sh packaging/macos/README.txt
git commit -m "build(macos): assemble the self-contained build/mac folder"
```

---

### Task 5: `NFSMW.app` bundle

**Files:**
- Create: `packaging/macos/Info.plist.in`
- Create: `app/cmake/hacer_app_mac.cmake`
- Modify: `app/CMakeLists.txt` (extend the APPLE block with `mac_app`)

**Interfaces:**
- Consumes: the `mac_dist` output convention (same `D_*` variables; `comprobar_dist.sh` for the inner check).
- Produces: `mac_app` CMake target assembling `build/mac/NFSMW.app` (`Contents/MacOS/nfsmw`, `Contents/Frameworks/`, `Contents/Resources/vulkan/icd.d/` with the ICD retargeted to `@executable_path/../Frameworks/libMoltenVK.dylib`, `Contents/Resources/nfsmw.toml`), ad-hoc signed.

- [ ] **Step 1: Write the Info.plist template**

`packaging/macos/Info.plist.in`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>nfsmw</string>
    <key>CFBundleIdentifier</key><string>org.rexglue.nfsmw</string>
    <key>CFBundleName</key><string>NFS Most Wanted</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>@NFSMW_VERSION@</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
```

- [ ] **Step 2: Write the bundle script**

`app/cmake/hacer_app_mac.cmake` (same `D_*` inputs as `hacer_dist_mac.cmake`, plus `D_BUNDLE` for the output `.app` and `D_PLIST` for the template):

```cmake
# =============================================================================
#  hacer_app_mac.cmake - arma NFSMW.app sobre la carpeta build/mac/
#
#  Contenido: Contents/MacOS/nfsmw (el binario de la carpeta dist, ya
#  relinkado), Contents/Frameworks/ (las mismas dylibs, con @rpath),
#  Contents/Resources/vulkan/icd.d/ con el ICD re-targetado, nfsmw.toml y
#  el README. Firma ad hoc: sin firmar no arranca en Apple Silicon.
# =============================================================================
cmake_minimum_required(VERSION 3.25)

foreach(v D_BUNDLE D_EXE D_BUILD D_SDK_INSTALL D_VULKAN_LOADER D_MOLTENVK
           D_SDL3 D_ICD D_CONFIG D_README D_PACKAGING)
    if(NOT DEFINED ${v})
        message(FATAL_ERROR "hacer_app_mac.cmake: falta ${v}")
    endif()
endforeach()

file(REMOVE_RECURSE "${D_BUNDLE}")
file(MAKE_DIRECTORY "${D_BUNDLE}/Contents/MacOS" "${D_BUNDLE}/Contents/Frameworks"
                    "${D_BUNDLE}/Contents/Resources/vulkan/icd.d")

configure_file("${D_PLIST}" "${D_BUNDLE}/Contents/Info.plist" @ONLY)

# ---- El binario y las dylibs (mismo criterio que hacer_dist_mac.cmake) ------
file(COPY "${D_EXE}" DESTINATION "${D_BUNDLE}/Contents/MacOS")
file(GLOB DYLIBS "${D_BUILD}/*.dylib")
if(NOT DYLIBS)
    foreach(n librexruntime librexgpu-xenos)
        file(GLOB hit "${D_SDK_INSTALL}/lib/${n}*.dylib")
        if(NOT hit)
            message(FATAL_ERROR "hacer_app_mac.cmake: no encuentro ${n}*.dylib")
        endif()
        list(APPEND DYLIBS ${hit})
    endforeach()
endif()
foreach(dylib IN LISTS DYLIBS)
    file(COPY "${dylib}" DESTINATION "${D_BUNDLE}/Contents/Frameworks")
endforeach()
if(NOT "${D_VULKAN_LOADER}" STREQUAL "")
    file(COPY "${D_VULKAN_LOADER}" DESTINATION "${D_BUNDLE}/Contents/Frameworks")
endif()
if(NOT "${D_MOLTENVK}" STREQUAL "")
    file(COPY "${D_MOLTENVK}" DESTINATION "${D_BUNDLE}/Contents/Frameworks")
endif()
if("${D_SDL3}" MATCHES "\\.dylib$")
    file(COPY "${D_SDL3}" DESTINATION "${D_BUNDLE}/Contents/Frameworks")
endif()
if(NOT "${D_ICD}" STREQUAL "")
    # Re-target the ICD at the bundle layout. MoltenVK's json accepts
    # @executable_path, which from Contents/Resources/vulkan/icd.d/ reaches
    # Contents/Frameworks via ../Frameworks.
    file(READ "${D_ICD}" icd_content)
    string(REPLACE "../../../lib/libMoltenVK.dylib"
                   "@executable_path/../Frameworks/libMoltenVK.dylib"
                   icd_content "${icd_content}")
    file(WRITE "${D_BUNDLE}/Contents/Resources/vulkan/icd.d/MoltenVK_icd.json"
               "${icd_content}")
endif()
file(COPY "${D_CONFIG}" DESTINATION "${D_BUNDLE}/Contents/Resources")
file(COPY "${D_README}" DESTINATION "${D_BUNDLE}/Contents/Resources")

# ---- Firma ad hoc del bundle ------------------------------------------------
#  Las dylibs ya salieron de la dist con @rpath (IDs puestos y deps
#  reescritas por relink.sh), y el binario ya lleva @executable_path. Pero
#  dentro del bundle las dylibs viven en Contents/Frameworks, asi que el
#  binario necesita ademas el rpath @executable_path/../Frameworks. Luego
#  re-firmar binario y dylibs (modificarlos invalida la firma y Apple
#  Silicon mata el proceso al arrancarlo) y firmar el bundle.
find_program(CS codesign REQUIRED)
find_program(INT install_name_tool REQUIRED)
execute_process(COMMAND ${INT} -add_rpath "@executable_path/../Frameworks"
                "${D_BUNDLE}/Contents/MacOS/nfsmw"
                ERROR_QUIET)  # ya puede traer ese rpath de la dist: da igual
execute_process(COMMAND ${CS} -f -s - "${D_BUNDLE}/Contents/MacOS/nfsmw"
                RESULT_VARIABLE rc)
if(NOT rc EQUAL 0)
    message(FATAL_ERROR "hacer_app_mac.cmake: codesign del binario fallo (${rc})")
endif()
file(GLOB FW_DYLIBS "${D_BUNDLE}/Contents/Frameworks/*.dylib")
execute_process(COMMAND ${CS} -f -s - ${FW_DYLIBS} RESULT_VARIABLE rc)
if(NOT rc EQUAL 0)
    message(FATAL_ERROR "hacer_app_mac.cmake: codesign de las dylibs fallo (${rc})")
endif()
execute_process(COMMAND ${CS} -f -s - "${D_BUNDLE}" RESULT_VARIABLE rc)
if(NOT rc EQUAL 0)
    message(FATAL_ERROR "hacer_app_mac.cmake: codesign del bundle fallo (${rc})")
endif()
```

- [ ] **Step 3: Wire the target**

Extend the APPLE block in `app/CMakeLists.txt` with:

```cmake
    add_custom_target(mac_app
        DEPENDS nfsmw
        COMMAND ${CMAKE_COMMAND}
                -D "D_BUNDLE=${NFSMW_MAC_DIST_DIR}/NFSMW.app"
                -D "D_PLIST=${CMAKE_CURRENT_SOURCE_DIR}/../packaging/macos/Info.plist.in"
                -D "D_EXE=$<TARGET_FILE:nfsmw>"
                -D "D_BUILD=$<TARGET_FILE_DIR:nfsmw>"
                -D "D_SDK_INSTALL=${rexglue_DIR}"
                -D "D_VULKAN_LOADER=$<TARGET_FILE:rex::vulkan-loader>"
                -D "D_MOLTENVK=$<TARGET_FILE:rex::moltenvk>"
                -D "D_SDL3=$<TARGET_FILE:SDL3::SDL3>"
                -D "D_ICD=${REXGLUE_MOLTENVK_ICD}"
                -D "D_CONFIG=${CMAKE_CURRENT_SOURCE_DIR}/nfsmw.toml"
                -D "D_README=${CMAKE_CURRENT_SOURCE_DIR}/../packaging/macos/README.txt"
                -D "D_PACKAGING=${CMAKE_CURRENT_SOURCE_DIR}/../packaging/macos"
                -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/hacer_app_mac.cmake"
        COMMENT "Armando NFSMW.app en ${NFSMW_MAC_DIST_DIR}"
        VERBATIM)
```
And set `NFSMW_VERSION` at the top of the APPLE block from the SDK version (` rexglue` already exports `REXGLUE_VERSION_STRING`; use `set(NFSMW_VERSION ${REXGLUE_VERSION_STRING})` guarded by `if(NOT DEFINED)`).

- [ ] **Step 4: Assemble and check**

Run:
```bash
cmake --build --preset mac-arm64-release --target mac_app
plutil -lint build/mac/NFSMW.app/Contents/Info.plist
codesign -dv build/mac/NFSMW.app 2>&1 | head -3
```
Expected: the bundle assembles; the plist is valid; the signature is ad-hoc ("Signature=adhoc").

- [ ] **Step 5: Boot the bundle by direct exec**

Run:
```bash
cd build/mac/NFSMW.app/Contents/MacOS
./nfsmw --user_data_root="$PWD/../../../saves" --fullscreen=false &
GAME_PID=$!
sleep 75
kill "$GAME_PID" 2>/dev/null || true
sleep 2; pkill -x nfsmw 2>/dev/null || true
grep -E '\[fps\]' ../logs/nfsmw_*.log 2>/dev/null | head -3 || \
  grep -rE '\[fps\]' ./logs 2>/dev/null | head -3
```
Expected: `[fps]` lines. (The Vulkan stack resolves through the bundle-relative ICD — this proves the `@executable_path/../Frameworks` retarget.)

- [ ] **Step 6: Bundle without argv (the Finder case)**

Run:
```bash
ln -s "$(realpath assets/game_root)" build/mac/NFSMW.app/Contents/MacOS/game_root
open build/mac/NFSMW.app
sleep 75
pkill -x nfsmw 2>/dev/null || true
ls build/mac/NFSMW.app/Contents/MacOS/logs/ 2>/dev/null || \
  ls ~/Library/Logs 2>/dev/null | grep -i nfsmw || true
grep -rE '\[fps\]' build/mac/NFSMW.app/Contents/MacOS/logs/ 2>/dev/null | head -3
rm build/mac/NFSMW.app/Contents/MacOS/game_root
```
Expected: the game finds `game_root/` beside the executable (the same search `nfsmw_app.h` runs on Windows), boots and renders with no flags; the log shows `[fps]`. If the log lands somewhere else (LaunchServices relaunches from a different cwd), record where in `docs/macos.md` and rely on the direct-exec test as the automated proof — the `open` test is the visual confirmation for the user.

- [ ] **Step 7: Wire the phase, commit**

Append to `tools/build_mac.sh`:

```bash
# ---------------------------------------------------------------------------
# 6. El bundle NFSMW.app. Doble clic en Finder: sin argv, el juego busca su
#    data junto al ejecutable (game_root/ o un .iso) dentro de Contents/MacOS.
# ---------------------------------------------------------------------------
fase_bundle() {
    echo "== 6. mac_app =="
    cmake --build --preset mac-arm64-release --target mac_app
}
fase_bundle
```
(Trailing call after `fase_dist`; final echo now "Done (fases 0-6).")

```bash
git add tools/build_mac.sh app/CMakeLists.txt app/cmake/hacer_app_mac.cmake \
        packaging/macos/Info.plist.in
git commit -m "feat(macos): NFSMW.app bundle"
```

---

### Task 6: Documentation

**Files:**
- Create: `docs/macos.md`
- Modify: `docs/00-entorno.md` (append a macOS section after the Linux one)
- Modify: `README.md` (status table row + build section line)
- Modify: `CHANGELOG.md` (Unreleased entry)

**Interfaces:**
- Consumes: everything above (the doc describes exactly what Tasks 2–5 produce, with the real verification results).

- [ ] **Step 1: `docs/macos.md`**

Write it in English, in the style of `docs/switch.md`, with these sections filled from the actual runs (not aspirational values):

```markdown
# macOS (Apple Silicon)

A native arm64 build for macOS, rendering through Vulkan on MoltenVK
(Khronos' Vulkan implementation of Apple's Metal). It is the same recompiled
code as the PC builds, compiled for Apple Silicon, windowed by SDL3, with the
Xenos GPU translated to Vulkan exactly as on Linux.

## Status

**Experimental.** (Fill the table from the observed runs of Tasks 3-5: which of
boot / menus / free roam / graphics / controller / audio / saves work.)

Graphics: the PC builds translate the Xbox 360 GPU to Vulkan or D3D12; this
build runs the same Vulkan backend unmodified (`src/graphics/vulkan`,
`src/ui/vulkan` in the SDK) on MoltenVK, built from the SDK's pinned
submodules together with the Vulkan loader and deployed as a portability
driver (`share/vulkan/icd.d/MoltenVK_icd.json` with `is_portability_driver`).
No new GPU backend was written. `gpu_backend = "null"` keeps the no-rendering
fallback.

## What goes in the folder / Building / Running / Controls / Troubleshooting

(As in docs/switch.md: the layout, the build command tools/build_mac.sh, the
run commands, the note that there is no launcher — options via nfsmw.toml or
flags — and the troubleshooting entries actually observed on this machine:
MoltenVK device name line, any present quirks, the null fallback.)
```

Content requirements: the folder layout from Task 4's README; the build prerequisites from Task 2 (`brew install cmake ninja python`, Xcode CLT, SDK checkout + submodules, first-run duration); the boot/run commands; a MoltenVK notes section listing whatever the log showed (device name, any extensions the backend asked for that MoltenVK lacked, black-frame troubleshooting if it happened); a licensing note (SDK BSD-3-Clause, app GPL-3.0, MoltenVK Apache-2.0 — state the three licenses are compatible in one binary).

- [ ] **Step 2: `docs/00-entorno.md` macOS section**

Append (Spanish, matching the file's tone):

```markdown
## macOS (Apple Silicon)

```bash
xcode-select --install
brew install cmake ninja python
python3 --version    # 3.10+; si no, brew te enlaza python3.12
```

El SDK, igual que en Linux:

```bash
cd rexglue-sdk
git submodule update --init --recursive
cmake --preset mac-arm64 -DREXGLUE_USE_VULKAN=ON
cmake --build out/build/mac-arm64 --config Release --target install
```

El juego: `tools/build_mac.sh` hace todo (parches, SDK, codegen, juego, carpeta
`build/mac/` y el bundle `NFSMW.app`). Ver [macos.md](macos.md).
```

- [ ] **Step 3: `README.md`**

Status table: add after the Switch row:

```markdown
| macOS (Apple Silicon, MoltenVK) | **Experimental.** Builds and boots with rendering through Vulkan on MoltenVK; see [docs/macos.md](docs/macos.md) |
```

Build section: after the three bat lines, add:

```markdown
On macOS (Apple Silicon): `tools/build_mac.sh` — see [docs/macos.md](docs/macos.md).
```

- [ ] **Step 4: `CHANGELOG.md`**

Add at the top of the releases (below the intro line), Spanish, Keep-a-Changelog style:

```markdown
## [Sin publicar]

### Añadido

- Compilación nativa de macOS (Apple Silicon) con Vulkan sobre MoltenVK:
  `tools/build_mac.sh` aplica los parches al SDK, lo compila con el stack
  Vulkan→MoltenVK de sus submódulos (loader + ICD), genera el código, compila
  el juego y arma `build/mac/` autocontenida y el bundle `NFSMW.app`.
  Documentación en `docs/macos.md`.
```

- [ ] **Step 5: Full-script verification from a near-clean state**

Run: `tools/build_mac.sh` end to end (submodules already in, patches already applied — verify idempotency survives every new phase).
Expected: all six phases pass; `build/mac/` and `NFSMW.app` rebuilt; exit 0.

- [ ] **Step 6: Commit**

```bash
git add docs/macos.md docs/00-entorno.md README.md CHANGELOG.md
git commit -m "docs(macos): macOS build and run documentation"
```

---

## Self-review

- Spec coverage: env bootstrap + submodules (T2), patches + SDK/MoltenVK stack (T2), codegen + app build + boot (T3), dist folder + leak check + docs-in-package (T4), `.app` bundle (T5), docs (T6). Milestones map: T2+T3 → M1/M2, T4 → M3, T5 → M4.
- Placeholders: Task 6's docs section pins structure and content requirements, with the observed-results rule stated. The artifact inventory in T3 Step 3 exists because the posix copy behavior of `rexglue_configure_target` cannot be known before the first mac build — the dist script handles both outcomes explicitly (build-dir glob with `SDK_INSTALL/lib` fallback and a static-archive escape hatch), so no unresolved decision is left. The bundle signature (T5) is written as plain CMake (`execute_process` + `codesign`/`install_name_tool`), matching the rest of the CMake scripts.
- Names: `mac_dist`, `mac_app`, `NFSMW_MAC_DIST_DIR`, `hacer_dist_mac.cmake`, `hacer_app_mac.cmake`, `relink.sh`, `comprobar_dist.sh`, `fase_*` consistent across T2–T6.
- Review Focus: each of the five has its owning test (T2 Step 5 / T4 Step 8, T4 Step 8, T4 Step 6 leak test, T3 Step 6, T5 Step 6).
