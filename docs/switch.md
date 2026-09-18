# Nintendo Switch (homebrew .nro)

A native aarch64 build for Horizon OS, launched from the Homebrew Menu. It is
the same recompiled code as the PC builds, compiled for the Switch's Cortex-A57
and linked against libnx.

## Status

**Experimental. The game runs and renders through Vulkan.**

| Area | State |
|---|---|
| Boot, XEX load, guest threads | Working |
| Guest memory (512 MiB physical + virtual heaps) | Working |
| Controller | Working (Joy-Con / Pro Controller, player 1) |
| Audio | Working (audout, stereo downmix) |
| Saves | Written to `saves/` next to the .nro |
| **Graphics** | **Vulkan through NXVK, experimental.** |

Graphics: the PC builds translate the Xbox 360 GPU to Vulkan or D3D12; Switch
homebrew now runs the same Vulkan backend unmodified (`src/graphics/vulkan`,
`src/ui/vulkan` in the SDK), linked against NXVK
(<https://github.com/PalindromicBreadLoaf/nxvk>), Mesa's NVK Vulkan driver
ported to Horizon OS. No new GPU backend was written. NXVK is a very young
driver, so device creation or presentation may still fail on some setups;
`--gpu_backend=null` keeps the old status-console fallback (no rendering)
available for that case.

Performance expectations: the Linux build uses about 2.3 Zen 4 cores at 60 fps.
The Switch has three usable Cortex-A57 cores at 1 GHz, roughly 8-10 times slower
each, so even with a renderer this will not reach full speed.

## What goes on the SD card

Everything lives in one folder:

```
sdmc:/switch/nfsmw-recomp/
├── nfsmw-recomp.nro     the game (from build/switch/nfsmw-recomp/)
├── README.txt           short version of this page
├── game/                YOUR game files, extracted from your own disc image
│   ├── default.xex
│   ├── NFS/
│   └── Movies/
├── saves/               created on first run: profile and save games
├── logs/                created on first run: nfsmw_NNN.log, one per run
└── nfsmw.toml           optional settings, same format as on PC
```

1. Build it (below), or take `build/switch/nfsmw-recomp/` from someone who
   built it. The folder contains **no game data**.
2. Copy the whole `nfsmw-recomp` folder to `/switch/` on the SD card, so the
   .nro ends up at `sdmc:/switch/nfsmw-recomp/nfsmw-recomp.nro`.
3. Extract your own copy of the game into `game/`, so that
   `sdmc:/switch/nfsmw-recomp/game/default.xex` exists. The same extraction
   the Linux launcher does works here, for example:

   ```sh
   extract-xiso -x "Need for Speed Most Wanted.iso" -d game
   ```

   ISO files are not read on this platform (a FAT32 card can't hold one, and
   there is no disc image mount); only the extracted folder works. The largest
   file in it is about 620 MB, so FAT32 cards are fine.

`game/` and `saves/` are the only folders you need to care about. Back up
`saves/` if you care about your progress.

With Vulkan rendering, `game/` now shares the same VRAM budget concerns as
the PC builds: the Tegra X1 has no dedicated video memory, so textures and
render targets are carved out of the same system RAM as guest memory and
NXVK's own allocations (see Building below). Watch the RAM figure in the
perf overlay (`--perf_overlay`) if a texture pack or higher-resolution asset
swap starts pushing that budget.

## Launching it

The game needs about 1.5 GB of RAM, so it must run with **full memory**:

- Hold **R** while starting any installed game (title takeover), then pick
  *NFS Most Wanted Recompiled* in the Homebrew Menu.
- Starting the Homebrew Menu from the Album gives an applet with ~440 MB. The
  game will fail to reserve memory and show the error on screen.

Requires a Switch running Atmosphère.

To quit: HOME, then close the software. On a startup error the log stays on
screen; press **+** to exit.

## Controls

Xbox 360 buttons are mapped by position:

| Xbox 360 | Switch |
|---|---|
| A / B / X / Y | B / A / Y / X |
| LB / RB | L / R |
| LT / RT | ZL / ZR (digital) |
| Start / Back | + / − |
| Sticks, stick clicks, D-pad | same |

Rumble goes to the Joy-Con / Pro Controller.

## Building

Needs, on a Linux PC:

- devkitPro with devkitA64 and libnx, in `DEVKITPRO` (default `/opt/devkitpro`).
  Either install the `switch-dev` group with devkitPro's pacman, or copy it out
  of the official container:

  ```sh
  podman create --name dkp docker.io/devkitpro/devkita64
  podman cp dkp:/opt/devkitpro ~/devkitpro && podman rm dkp
  export DEVKITPRO=~/devkitpro
  ```
- clang 18+, CMake 3.28+, Ninja, Python 3 (same as the Linux build).
- The ReXGlue SDK checked out next to this repository, and
  `assets/default.xex` extracted as for the PC build.
- NXVK installed into that same `DEVKITPRO` prefix (below) — the Vulkan
  backend links against it.

### Installing NXVK

The SDK's Vulkan backend links against NXVK
(<https://github.com/PalindromicBreadLoaf/nxvk>), Mesa's NVK driver for
Horizon OS. It is not part of devkitPro and has to be built and installed
once, before `tools/build_switch.sh` can link:

```sh
git clone https://github.com/PalindromicBreadLoaf/nxvk
cd nxvk
make image   # builds the aarch64/newlib cross build image; needs podman or docker
make
DEVKITPRO=<your devkitpro> make install   # e.g. DEVKITPRO=~/devkitpro; no sudo needed if you own that directory
```

Licensing: NXVK's own files are GPL-2.0-or-later, this app is GPL-3.0, and
the ReXGlue SDK is BSD-3-Clause — all three are compatible in the same
binary.

Then:

```sh
tools/build_switch.sh
```

The first run builds the host SDK once (the code generator runs on the PC),
then cross-compiles the SDK and the game for the Switch and assembles
`build/switch/nfsmw-recomp/`. By hand, the steps are:

```sh
cmake --preset switch-release -S app
cmake --build app/out/build/switch-release --target switch_dist
```

`app/out/build/switch-release/nfsmw-recomp.elf` is kept next to the .nro, with
symbols: crash addresses in `crash.txt` (`elf+0x...`) resolve with
`aarch64-none-elf-addr2line -e nfsmw-recomp.elf 0x...`.

## Trying it in an emulator

Eden (and other yuzu descendants) load the .nro directly:

1. Put the folder at `~/.local/share/eden/sdmc/switch/nfsmw-recomp/`, with the
   game in `game/` (a symlink to the extracted folder works).
2. `eden -g ~/.local/share/eden/sdmc/switch/nfsmw-recomp/nfsmw-recomp.nro`

Emulators don't pass argv to a directly loaded .nro; the build falls back to
`sdmc:/switch/nfsmw-recomp/`, so keep that exact path.

## How the port works

For whoever picks up the renderer. Everything platform-specific is in the SDK
under `REX_PLATFORM_SWITCH`:

| Piece | Where | Notes |
|---|---|---|
| Toolchain | `cmake/toolchains/switch-clang.cmake` | clang compiles against devkitA64's newlib/libstdc++, devkitA64's g++ links with `switch.specs` |
| Thread pointer | `src/core/platform/switch_crt.cpp` | libnx keeps TLS at TLS+0x1F8 (GCC `-mtp=soft`); clang reads TPIDR_EL0, so every thread copies it there (`userAppInit`, `--wrap=threadCreate`) |
| Guest memory | `src/core/memory_switch.cpp` | one reserved window; commits move heap pages in with `svcMapProcessCodeMemory` |
| Aliased views | `GuestHostFold` in `xmemory.h`, `REX_PHYS_HOST_OFFSET` in the codegen PCH | the 0xA0/0xC0/0xE0 physical windows and 0x9xxxxxxx are folded onto one copy in software, because neither `svcMapProcessMemory` nor shared memory objects are available everywhere |
| Faults | `src/core/exception_handler_switch.cpp`, `platform/switch_exception_entry.S` | resumable user-exception entry, for the MMIO fallback |
| Threads | `src/core/threading_posix.cpp` | libnx pthreads; suspend with `svcSetThreadActivity`, priority/affinity with svcs; guest threads at 0x3B (the time-sliced priority) |
| Fibers | `src/core/fiber_switch.cpp` | hand-written context switch |
| UI loop | `src/ui/windowed_app_context_switch.cpp` | applet loop; paints through the presenter with `gpu_backend=vulkan`, falls back to the status console with `gpu_backend=null` |
| Input / audio | `src/input/nx/`, `src/audio/nx/` | libnx pad and audout |
| GPU | `src/graphics/vulkan/`, `src/ui/vulkan/` | the existing Vulkan backend, linked against NXVK; `src/graphics/null/` remains as the no-rendering fallback |

Not done: CPU write-watch for GPU caches (memory protection is only recorded,
see `memory_switch.cpp`), and guest SEH scopes (a fault
inside one is fatal; NFSMW has none).
