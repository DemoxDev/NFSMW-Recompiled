# NFS Most Wanted ARM64 AppImage

The AppImage contains the native launcher, recompiled game executable,
ReXGlue runtime/GPU libraries, Qt 6 and an ARM64 `extract-xiso`. It never
contains copyrighted game files.

## Build dependencies

- AArch64 Linux host
- CMake 3.25+, Clang and Qt 6.4 development packages
- `linuxdeploy`, `linuxdeploy-plugin-qt` and `appimagetool` for AArch64
- Git and an internet connection for the pinned `extract-xiso` source

Build the game (see project docs), then the launcher:

```bash
cd app
cmake --preset linux-arm64-release -DNFSMW_BUILD_LAUNCHER=ON
cmake --build --preset linux-arm64-release --target nfsmw nfsmw_launcher
```

Or, if you already configured into `app/build`:

```bash
cmake -S app -B app/build -DNFSMW_BUILD_LAUNCHER=ON
cmake --build app/build --parallel --target nfsmw_launcher
```

Create the AppImage from the repository root:

```bash
LINUXDEPLOY=/path/to/linuxdeploy-aarch64.AppImage \
APPIMAGETOOL=/path/to/appimagetool-aarch64.AppImage \
PATH="/path/to/linuxdeploy-plugin-qt:$PATH" \
packaging/appimage/build-appimage-arm64.sh
```

Artifact: `app/build/NFSMW-aarch64.AppImage`.

Override `NFSMW_BIN`, `LAUNCHER_BIN`, `RUNTIME_LIB`, `GPU_LIB` or
`EXTRACT_XISO_BIN` if the artifacts are in other locations.

## Runtime

On first launch, choose a writable root folder. The launcher creates:

```text
root/
  game/       # Imported Xbox 360 files, including default.xex
  config/     # Launcher settings
  saves/
  cache/
  logs/
```

The game can be imported from an original Xbox 360 ISO or pointed at an
already extracted directory containing `default.xex` (for example
`assets/game_root` from a local build).

If FUSE is unavailable:

```bash
APPIMAGE_EXTRACT_AND_RUN=1 ./NFSMW-aarch64.AppImage
```

The host must provide a working Vulkan driver. Turnip/Mesa is intentionally
not bundled.
