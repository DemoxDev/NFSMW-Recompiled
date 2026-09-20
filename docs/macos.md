# macOS (Apple Silicon)

A native arm64 build for macOS, rendering through Vulkan on MoltenVK
(Khronos' Vulkan implementation of Apple's Metal). It is the same recompiled
code as the PC builds, compiled for Apple Silicon, windowed by SDL3, with the
Xenos GPU translated to Vulkan exactly as on Linux.

## Status

**Experimental. Boots, renders and plays sound on Apple Silicon through
MoltenVK. The verification runs were ~75 s boot/shutdown tests through the
title load; free roam and long sessions are not verified yet.**

| Area | State |
|---|---|
| Boot, XEX load, guest threads | Working |
| Title/menu rendering (Vulkan on MoltenVK) | Working. Apple M1 GPU: 60 fps steady at `resolution_scale = 1`, ~30 fps at the shipped `resolution_scale = 2` (2560×1440 internal). The four performance patches below are applied by `tools/build_mac.sh`; without them the UI repaints unthrottled and the game drops to 4–15 fps |
| Audio | Working. Opens the default CoreAudio output device (observed: "MacBook Air Speakers", 6 ch, 48000 Hz) |
| Controller | SDL3 gamepad support is in; not exercised with a pad in the verification runs |
| Saves | Written to the `--user_data_root` folder, created on demand. Not exercised beyond directory creation |
| Free roam, long sessions | Not verified |

Graphics: the PC builds translate the Xbox 360 GPU to Vulkan or D3D12; this
build runs the same Vulkan backend unmodified (`src/graphics/vulkan`,
`src/ui/vulkan` in the SDK) on MoltenVK, built from the SDK's pinned
submodules together with the Vulkan loader and deployed as a portability
driver (`share/vulkan/icd.d/MoltenVK_icd.json` with `is_portability_driver`).
No new GPU backend was written. `gpu_backend = "null"` keeps the no-rendering
fallback (the text status console).

Two more things the build carries: the repo's ten patch scripts are applied
to the SDK before it is compiled (the nine `CONSTRUIR.bat` ones plus
`parche_fotogramas`, the frame counter that feeds the `[fps]` log line — see
[docs/parches.md](parches.md)), and SDL3 links statically into the game
binary, so there is no `libSDL3.dylib` to carry around.

## What goes in the folder

The script produces two artifacts under `build/mac/`: the self-contained
folder and, on top of it, the `NFSMW.app` bundle.

### `build/mac/` (the folder)

Everything lives in one folder:

```
build/mac/
├── nfsmw                     the game
├── librexgpu-xenos.dylib     the GPU plugin (dlopen'ed next to the game)
├── lib/                      dylibs: librexgpu-xenos, librexruntime,
│                             libTracyClient, libvulkan.1 (the Vulkan
│                             loader), libMoltenVK (do not delete any)
├── share/vulkan/icd.d/       MoltenVK_icd.json (library_path is relative
│                             to the json: ../../../lib/libMoltenVK.dylib)
├── nfsmw.toml                optional settings, same format as on PC
├── README.txt                short version of this page
└── game_root/  saves/  logs/ yours, created here
```

1. Build it (below), or take `build/mac/` from someone who built it. The
   folder contains **no game data**.
2. Put your game files next to `nfsmw`: either the extracted folder named
   `game_root` (`game_root/default.xex` must exist — the same extraction as
   on the PC, e.g. `extract-xiso -x "Need for Speed Most Wanted.iso" -d game`)
   or the `.iso` itself, which is read in place.
3. Run `./nfsmw` from that folder (below).

`game_root/` and `saves/` are the only folders you need to care about. Back
up `saves/` if you care about your progress.

There is no launcher on this platform: options come from `nfsmw.toml` next to
the game or from command-line flags (which override the file), like on the
PC builds minus the launcher.

### `NFSMW.app/` (the bundle)

```
NFSMW.app/
  Contents/MacOS/          nfsmw, librexgpu-xenos.dylib, lib -> ../Frameworks
  Contents/Frameworks/     the same dylibs as lib/
  Contents/Resources/      nfsmw.toml (template), README.txt,
                           vulkan/icd.d/MoltenVK_icd.json
  Contents/Info.plist
```

How the Vulkan stack stays inside the bundle (verified in the boot logs):
the runtime recognizes the bundle as its SDK root because
`Contents/MacOS/lib` is a symlink to `../Frameworks`, which puts the root
marker `lib/libvulkan.1.dylib` beside the executable, exactly like in the
folder; the Vulkan loader then finds `MoltenVK_icd.json` by its own scan of
the bundle's resources (`Contents/Resources/vulkan/icd.d/`), and the ICD's
`library_path` is relative to that json (`../../../Frameworks/libMoltenVK.dylib`).

Two rules for the bundle:

- **Keep it in a writable location** (`~/Applications`, Desktop, your home).
  The game writes its working `nfsmw.toml`, its saves and its logs into
  `Contents/MacOS/` on demand; from a read-only location like `/Applications`
  it cannot. If you want to preconfigure, copy
  `Contents/Resources/nfsmw.toml` into `Contents/MacOS/`.
- **No game data ships in it**: put your `game_root/` (a symlink to your
  extraction works) or your `.iso` inside `Contents/MacOS/`. Launched with no
  arguments — double-click in Finder or `open build/mac/NFSMW.app` — the
  game finds it beside the executable, same as on Windows.

## Running it

Folder, from a terminal:

```
cd build/mac
./nfsmw
```

or with flags (everything is overridable):

```
./nfsmw --game_data_root=/path/to/game_root --user_data_root="$PWD/saves" --fullscreen=false
```

Bundle: double-click `NFSMW.app` in Finder (or `open build/mac/NFSMW.app`),
or run the executable directly with flags:
`build/mac/NFSMW.app/Contents/MacOS/nfsmw --fullscreen=false`.

Quit with Cmd+Q or the window close button (verified: clean shutdown).

Logs land next to the executable in both cases: `build/mac/logs/` for the
folder, `NFSMW.app/Contents/MacOS/logs/` for the bundle — including when it
is launched via Finder/`open`. One `nfsmw_NNN.log` per run.

## Building

Needs, on an Apple Silicon Mac:

- Xcode Command Line Tools: `xcode-select --install`.
- `brew install cmake ninja python` — CMake 3.25+, Ninja, Python 3.10+. Apple's
  system `python3` (3.9) is rejected by the script with a clear message; if
  brew's python is newer than 3.10 it is picked up automatically (`brew
  install python@3.12` on the reference machine), or force it with
  `REX_PYTHON=python3.12`.
- The ReXGlue SDK checked out next to this repository (`../rexglue-sdk`). The
  script fetches its submodules on the first run — FFmpeg and MoltenVK are
  the heavy ones.

Then:

```
tools/build_mac.sh
```

The script runs everything in order and is idempotent:

1. checks the tools and anchors `SDKROOT` to the Xcode SDK (see
   Troubleshooting for why);
2. initializes the SDK's submodules if missing;
3. applies the ten patch scripts (refuses to touch anything if an anchor
   does not match; already-applied patches are skipped);
4. configures the SDK with `-DREXGLUE_USE_VULKAN=ON`, builds and installs it:
   `../rexglue-sdk/out/install/mac-arm64/` ends up with the `rexglue` CLI,
   the runtime dylibs and the whole Vulkan stack — `libvulkan.1.dylib`
   (loader), `libMoltenVK.dylib`, `share/vulkan/icd.d/MoltenVK_icd.json`;
5. runs the code generator first, then compiles the game in a second pass
   (the generated headers change between the passes, so one combined build
   would link against a stale PCH);
6. assembles `build/mac/` — relinks everything to `@rpath`, verifies the
   folder is self-contained (any file that looks like game data aborts the
   build), and finally
7. assembles and ad-hoc signs `NFSMW.app` (unsigned code does not launch on
   Apple Silicon).

The first run builds the SDK from source — MoltenVK's own build alone was
421 compile steps in one observed run — and the code generator took ~260 s;
expect a long first build. Warm re-runs are incremental and finish in about
a minute.

By hand, the essential steps are:

```sh
cmake --preset mac-arm64 -S ../rexglue-sdk -DREXGLUE_USE_VULKAN=ON
cmake --build ../rexglue-sdk/out/build/mac-arm64 --config Release --target install
cmake --preset mac-arm64-release -S app -DCMAKE_PREFIX_PATH="$(realpath ../rexglue-sdk/out/install/mac-arm64)"
cmake --build app/out/build/mac-arm64-release --target mac_dist   # the folder
cmake --build app/out/build/mac-arm64-release --target mac_app    # the bundle
```

Manual cmake invocations need `SDKROOT` exported (the script resolves it for
you when it runs everything):

```sh
export SDKROOT=$(xcode-select -p)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
```

## Controls

Keyboard and gamepads work the same way as on the PC builds — input goes
through SDL3, and the Xbox 360 layout the game expects maps to standard
controllers. The verification runs did not exercise a controller on this
platform yet. There is no launcher on macOS: every option is `nfsmw.toml` or
a command-line flag.

## Licensing

MoltenVK's own files are Apache-2.0, the ReXGlue SDK is BSD-3-Clause, and
this app is GPL-3.0 — all three are compatible in the same binary.

## Troubleshooting

- **Two `[error]` lines on the first boot** — `requested backend 'd3d12' is
  not compiled into this plugin` and `GPU plugin 'xenos' factory returned no
  graphics system (backend 'd3d12')`. By design: a fresh user data root
  defaults to `gpu_backend = "d3d12"` (the Windows default; macOS has no
  D3D12), and the SDK's backend patch falls back to Vulkan and logs
  `Arrancando con 'vulkan' en su lugar`. Set `gpu_backend = "vulkan"` in
  `nfsmw.toml` and the lines disappear.
- **Up to seven `[error]`/`[vigilante]` lines ~5 s into the first boot** —
  the hang watchdog snapshots a stall during the title load, before the
  guest threads start executing. It recovers and renders right after; warm
  boots do not repeat it.
- **Thousands of `mvk-warn: Metal does not support disabling primitive
  restart` lines** — MoltenVK per-pipeline feature warnings. Rendering
  continues through them; harmless log noise.
- **`Vulkan geometryShader is not supported by the device`** — one MoltenVK
  limitation warning on Apple GPUs; the backend switches to its primitive
  fallback paths and rendering continues. Watch rendering quality around
  geometry expansion, and report if something looks off.
- **The lines that should be in every log** — `Loaded Vulkan runtime from
  .../lib/libvulkan.1.dylib` (the folder's or the bundle's own path) and a
  `Vulkan device 'Apple M1'`-style line with your GPU's name and vendor
  0x106B (observed on an M1: `Vulkan device 'Apple M1': API 1.3.357, vendor
  0x106B`). If the runtime line points somewhere else (e.g.
  `/opt/homebrew/...` on a Homebrew machine), the build's own stack lost the
  detection contest — check that line first when reporting.
- **Black screen with `gpu_backend = "vulkan"`** — set
  `gpu_backend = "null"` in `nfsmw.toml` (no rendering, but the game runs)
  and send the log with the report.
- **Low fps on first boot** — MoltenVK compiles Metal pipelines on first
  use, and background load skews the meter. Steady-state numbers with the
  performance patches applied (`parche_ui_ticks`, `parche_pipeline_pintado`,
  `parche_cvar_plugin`, `parche_sleep0`; see
  [parches.md](parches.md)): 60 fps at `resolution_scale = 1`, ~30 fps at
  `resolution_scale = 2` on the reference M1. Without them the UI repaints
  unthrottled off Windows (~200 paints/s) and starves the guest present:
  4–15 fps, which is what earlier builds showed.
- **Re-signing a used bundle fails** — the first run creates
  `Contents/MacOS/logs/`, and codesign treats everything under
  `Contents/MacOS` as code, so signing then fails. Don't re-sign a used
  bundle; rebuild it (`tools/build_mac.sh` or the `mac_app` target, which
  re-assemble it from scratch).
- **Build fails with `ld: tapi error: malformed file ... MacOSX27.0.sdk`** —
  an Xcode/CLT version skew: Xcode 26.6's tapi cannot parse the newer
  Command Line Tools SDK. `tools/build_mac.sh` anchors `SDKROOT` to the
  Xcode SDK automatically; manual cmake runs need the `export SDKROOT=...`
  shown above.
