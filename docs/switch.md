# Nintendo Switch (homebrew .nro)

A native aarch64 build for Horizon OS, launched from the Homebrew Menu. It is
the same recompiled code as the PC builds, compiled for the Switch's Cortex-A57
and linked against libnx.

## Status

**Experimental. The game runs, but nothing is drawn yet.**

| Area | State |
|---|---|
| Boot, XEX load, guest threads | Working |
| Guest memory (512 MiB physical + virtual heaps) | Working |
| Controller | Working (Joy-Con / Pro Controller, player 1) |
| Audio | Working (audout, stereo downmix) |
| Saves | Written to `saves/` next to the .nro |
| **Graphics** | **Not yet.** The GPU is emulated by the *null* backend: the command processor runs, vblank and GPU interrupts fire, so the game logic runs, but no frame is rendered. The screen shows a status console instead: guest fps, frames, RAM, and the log tail. |

Why no graphics: the PC builds translate the Xbox 360 GPU to Vulkan or D3D12,
and Switch homebrew has neither. A deko3d or OpenGL (Mesa) backend is the next
piece of work; it is a port of the whole Xenos backend, not a small patch.

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
| UI loop | `src/ui/windowed_app_context_switch.cpp` | applet loop and the status console |
| Input / audio | `src/input/nx/`, `src/audio/nx/` | libnx pad and audout |
| GPU | `src/graphics/null/` | the null backend, linked statically |

Not done: CPU write-watch for GPU caches (memory protection is only recorded,
see `memory_switch.cpp`), a real GPU backend, and guest SEH scopes (a fault
inside one is fatal; NFSMW has none).
