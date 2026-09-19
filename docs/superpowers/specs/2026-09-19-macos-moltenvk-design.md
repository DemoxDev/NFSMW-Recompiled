# macOS build: the existing Vulkan backend on MoltenVK

Date: 2026-09-19. Status: approved (this work on branch `macos-vulkan`).

## Goal

A native macOS build (Apple Silicon, `mac-arm64`) that renders the game through
the SDK's existing Vulkan backend (`src/graphics/vulkan`, `src/ui/vulkan`) on
MoltenVK. No new GPU backend — the same policy as the Switch port. The
deliverable is a scripted pipeline (`tools/build_mac.sh`) that produces a
runnable `build/mac/` folder; a double-clickable `NFSMW.app` bundle follows as
a second phase once rendering is verified.

## Why this shape

- The SDK already ships first-class macOS support: `REX_PLATFORM_MAC` (64
  uses), SDL3 windowing (`window_sdl.cpp`, `windowed_app_context_sdl.cpp`),
  the posix core layers (memory, fibers, threading, exceptions, clock, dynlib)
  and a dedicated MoltenVK integration
  (`src/ui/vulkan/vulkan_moltenvk.cpp`), which detects the loader, the ICD and
  SPIRV-Tools from `VULKAN_SDK`/`REX_VULKAN_SDK`, bundle-relative roots and
  `/usr/local`/`/opt/homebrew` fallbacks, and configures the Vulkan loader
  environment before instance creation.
- The Vulkan presenter already supports `VK_EXT_metal_surface`
  (`Surface::kTypeIndex_CAMetalLayer`); the SDL window supplies the
  CAMetalLayer.
- The SDK's install rules deploy the whole stack for the `mac-*` presets:
  `Vulkan::Loader` → `lib/libvulkan.1.dylib`, `MoltenVK::MoltenVK` →
  `lib/libMoltenVK.dylib`, `cmake/MoltenVK_icd.json` →
  `share/vulkan/icd.d/` (its `library_path` is the relative
  `../../../lib/libMoltenVK.dylib`). Any folder that keeps that relative
  layout — the SDK prefix or our dist folder — works unchanged, and the
  runtime's own detection finds it.
- The Vulkan stack is vendored and pinned
  (`cmake/rexglue_vulkan_stack.cmake`: moltenvk `db445ff`, vulkan-loader
  `5f15762`, vulkan-headers `e3b1eec`, spirv-tools/headers pinned), so the
  build is reproducible from the SDK's git submodules.

## What changes (this repo unless noted)

1. `tools/build_mac.sh`: tool checks (clang, cmake, ninja, Python ≥3.10 —
   the system `python3` is 3.9.6, so prefer `python3.12`/`python3.11` from
   PATH and fail loudly if none); init the SDK's submodules
   (`git -C ../rexglue-sdk submodule update --init --recursive`); apply the
   nine `parche_*.py` in the Windows pipeline's order — `parche_diagnostico`
   first, `parche_anillo` before `parche_desatasco` — each verified with
   `--estado`, aborting if any anchor does not match exactly once; configure,
   build and install the SDK with the `mac-arm64` preset; run codegen
   (`rexglue codegen app/nfsmw_manifest.toml`, input
   `assets/game_root/default.xex`, generated sources shared with the other
   builds); configure and build the app through the generated preset
   (`mac-arm64-release`); build the `mac_dist` target.
2. `app/CMakeLists.txt` APPLE branch: a `mac_dist` custom target that
   assembles `build/mac/` (overridable `NFSMW_DIST_DIR`): the `nfsmw`
   binary, `librexruntime.dylib`, `librexgpu-xenos.dylib`, the SDL3 dylibs,
   `libvulkan.1.dylib`, `libMoltenVK.dylib`, `MoltenVK_icd.json` (plus the
   SPIRV-Tools dylib when linked), `app/nfsmw.toml` and a new
   `packaging/macos/README.txt`. The folder keeps the SDK-prefix relative
   layout (`lib/`, `share/vulkan/icd.d/`), RPATHs resolved through
   `@executable_path`. A leak check (mirroring `comprobar_dist`) refuses the
   folder if anything that looks like game data landed in it.
3. Phase 2 — `packaging/macos/`: an `Info.plist` template and a `mac_app`
   CMake target producing `NFSMW.app` (`Contents/MacOS/nfsmw`,
   `Contents/Frameworks/`, `Contents/Resources/vulkan/icd.d/` with the ICD
   retargeted, `nfsmw.toml` in Resources), ad-hoc signed. Built only after
   the plain folder is verified.
4. Docs: `docs/macos.md` (English, the style of `docs/switch.md`), a macOS
   section in `docs/00-entorno.md` (Spanish), README status/build rows, a
   CHANGELOG entry.

The SDK itself is expected to need no changes (macOS support is upstream).
If a patch anchor or the SDK build hits a mac-specific break, the fix becomes
a new `parche_*.py` per the repo's patch design (exact-text, revertible,
catalogued in `docs/parches.md`).

## Risks and how they are handled

- Untested driver pairing: the README still records the Vulkan backend
  "renders black on Intel" on Linux; MoltenVK is another driver and untested
  here. Mitigation: read the SDK's GPU logs per milestone (the logging work
  from the Switch branch helps), keep `gpu_backend = "null"` as the safe
  fallback, and record findings in `docs/macos.md` and
  `docs/problemas-conocidos.md`.
- MoltenVK feature gaps (formats, extensions) may surface during pipeline or
  shader creation; SPIR-V validation (`SpirvToolsContext`, dlopen of
  `libSPIRV-Tools-shared.dylib`) is available on mac — the detection covers
  it. RenderDoc is unavailable.
- First build is slow: MoltenVK from source (network + tens of minutes),
  once per SDK checkout.
- Codegen is a native host program; it runs on the mac directly, no cross
  toolchain needed.

## Testing

- `tools/build_mac.sh` from a clean state: green end to end.
- Run from `build/mac/`: log lines for the Vulkan runtime/instance/device
  (Apple GPU through MoltenVK), presenter connected, `[fps]` lines, no
  `[error]`; menus render; prologue and free roam run; saves, input and audio
  verified; quit is clean.
- Leak check: the dist folder contains no game data.

## Milestones

1. Compiles and links: SDK (patches + MoltenVK stack) and the app on
   `mac-arm64`.
2. Boots with rendering: instance, device and surface through MoltenVK;
   menus visible.
3. Playable: free roam with `[fps]` lines and no `[error]`; saves, input and
   audio verified.
4. `NFSMW.app` packaged and verified.

## Out of scope

Launcher, universal binary, code signing/notarization, a native Metal
backend, multiplayer.
