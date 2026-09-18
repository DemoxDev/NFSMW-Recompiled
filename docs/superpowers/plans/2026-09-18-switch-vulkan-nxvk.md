# Switch Vulkan on NXVK — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the SDK's existing Vulkan GPU backend on the Nintendo Switch through the NXVK driver, so the Switch build draws the game instead of showing a text console.

**Architecture:** No new backend. Enable the Vulkan backend in the Switch build, bind the static NXVK entry point instead of a loader library, add a libnx `NWindow` surface type created with `vkCreateViSurfaceNN`, and paint through the presenter from the Switch app loop.

**Tech Stack:** C++23, CMake, clang (compile) + devkitA64 g++ (link), libnx, NXVK (`libnvk.a`, `libnvk_support.a`, `nxvk.pc`), vendored Vulkan headers / VMA / glslang.

**Spec:** `docs/superpowers/specs/2026-09-18-switch-vulkan-nxvk-design.md` (app repo). SDK repo: `/home/chris/Projects/rexglue-sdk`, branch `switch-vulkan`. App repo: `/home/chris/Projects/NFSMW-Recompiled`, branch `switch-vulkan`. Paths below without a repo prefix are in the SDK.

## Global Constraints

- Switch build: `DEVKITPRO=$HOME/.local/opt/devkitpro tools/build_switch.sh` from the app repo (configures `app/out/build/switch-release`, builds `switch_dist`, output `build/switch/nfsmw-recomp/nfsmw-recomp.nro`). Toolchain file `cmake/toolchains/switch-clang.cmake` already adds `-L${DEVKITPRO}/portlibs/switch/lib` and `-isystem .../portlibs/switch/include`.
- NXVK entry point is `extern "C" PFN_vkVoidFunction vk_icdGetInstanceProcAddr(VkInstance, const char*)`; `libnvk.a` must be linked `-Wl,--whole-archive`; also link `-lnvk_support -lz -lexpat -lstdc++ -pthread` (NXVK `switch/build/build-nro.sh:129-138`).
- `VK_NN_vi_surface`: define `VK_USE_PLATFORM_VI_NN` before the Vulkan headers; `VkViSurfaceCreateInfoNN{ VK_STRUCTURE_TYPE_VI_SURFACE_CREATE_INFO_NN, nullptr, 0, window }` with `window = NWindow*`.
- PC builds unchanged in behaviour: every Switch change sits under `REX_PLATFORM_SWITCH` / `NINTENDO_SWITCH`.
- Linux regression after each SDK task: `cmake --build out/build/linux-amd64 --config Release && cmake --install out/build/linux-amd64 --config Release`, rebuild the app (`cmake --build app/out/build/linux-amd64-release --target nfsmw`), then run the game once with `--gpu_backend=vulkan` from `app/out/build/linux-amd64-release/` (`--game_data_root=/home/chris/Projects/NFSMW-Recompiled/assets/game_root --user_data_root=<scratch> --fullscreen=false`) and confirm the log reaches `[fps]` lines with no `[error]`.
- Eden check: copy the .nro to `~/.local/share/eden/sdmc/switch/nfsmw-recomp/nfsmw-recomp.nro`, run `~/AppImages/eden_nightly.appimage -g <that path>` in the background, wait for `~/.local/share/eden/sdmc/switch/nfsmw-recomp/logs/nfsmw_NNN.log`, kill with `pkill -9 -f '[.]mount_eden'` in a separate shell command that does not contain the AppImage path.
- Commits: Conventional Commits, imperative, ≤72 chars, no attribution trailers.

---

### Task 1: Switch build compiles and links the Vulkan backend against NXVK

**Files:**
- Modify: `CMakeLists.txt:42-55` (backend gate: Switch → Vulkan ON, D3D12 OFF)
- Modify: `thirdparty/CMakeLists.txt` (vulkan stack under `REXGLUE_USE_VULKAN` must build on Switch; glslang/VMA/spirv-headers)
- Modify: `src/graphics/CMakeLists.txt:151-162`, `src/ui/CMakeLists.txt:99-101,151-157`, `src/system/CMakeLists.txt:119-129` (link NXVK on Switch)
- Create: `cmake/rexglue_nxvk.cmake` (imported target `nxvk::nxvk` from `pkg-config --libs --cflags nxvk`, whole-archive for `libnvk.a`)
- Precondition: NXVK installed: from `/home/chris/Projects/nxvk`, `DEVKITPRO=$HOME/.local/opt/devkitpro make install` (no sudo; portlibs is user-owned) after `make` finished; verify `ls $DEVKITPRO/portlibs/switch/lib/libnvk.a $DEVKITPRO/portlibs/switch/lib/pkgconfig/nxvk.pc`.

**Interfaces:**
- Produces: CMake target `nxvk::nxvk` (INTERFACE) carrying include dirs and the link line; `REX_HAS_VULKAN=1` on Switch (already emitted by `src/core` and `src/system` when `REXGLUE_USE_VULKAN`).

- [ ] **Step 1: Flip the gate**

In `CMakeLists.txt` replace the `if(NINTENDO_SWITCH)` branch of the backend gate with:

```cmake
if(NINTENDO_SWITCH)
    # Vulkan through NXVK (Mesa NVK on Horizon), linked statically.
    set(REXGLUE_USE_D3D12 OFF)
    set(REXGLUE_USE_VULKAN ON)
```

Remove Switch from the exemption in the "At least one graphics backend" check (it now has one). Keep `REXGLUE_ENABLE_TRACY OFF` on Switch.

- [ ] **Step 2: NXVK imported target**

`cmake/rexglue_nxvk.cmake`:

```cmake
# NXVK: Mesa NVK for Horizon, static and loaderless. Only meaningful on Switch.
if(NOT NINTENDO_SWITCH)
    return()
endif()
find_program(NX_PKG_CONFIG pkg-config REQUIRED)
set(ENV{PKG_CONFIG_LIBDIR} "${DEVKITPRO}/portlibs/switch/lib/pkgconfig:${DEVKITPRO}/libnx/lib/pkgconfig")
execute_process(COMMAND ${NX_PKG_CONFIG} --cflags nxvk OUTPUT_VARIABLE NXVK_CFLAGS OUTPUT_STRIP_TRAILING_WHITESPACE RESULT_VARIABLE _rc)
if(NOT _rc EQUAL 0)
    message(FATAL_ERROR "nxvk.pc not found under ${DEVKITPRO}/portlibs/switch; build and install NXVK first (see docs/switch.md)")
endif()
execute_process(COMMAND ${NX_PKG_CONFIG} --libs nxvk OUTPUT_VARIABLE NXVK_LIBS OUTPUT_STRIP_TRAILING_WHITESPACE)
separate_arguments(NXVK_CFLAGS)
separate_arguments(NXVK_LIBS)
add_library(nxvk INTERFACE)
add_library(nxvk::nxvk ALIAS nxvk)
target_compile_options(nxvk INTERFACE ${NXVK_CFLAGS})
# libnvk.a registers its ICD entry points through static constructors and
# must be whole-archived, as NXVK's own build-nro.sh does.
target_link_options(nxvk INTERFACE -Wl,--whole-archive -lnvk -Wl,--no-whole-archive)
list(REMOVE_ITEM NXVK_LIBS -lnvk)
target_link_libraries(nxvk INTERFACE ${NXVK_LIBS} -lz -lexpat -lstdc++ -pthread)
```

Include it from the top-level `CMakeLists.txt` right after the toolchain-dependent options (before `add_subdirectory(src/...)`). If `nxvk.pc` already carries `--whole-archive`, drop the manual `target_link_options` line and keep the `.pc` line verbatim (check with `pkg-config --libs nxvk` and say which in the report).

- [ ] **Step 3: Link it and make the stack build**

- `src/graphics/CMakeLists.txt` Vulkan link block: add `$<$<BOOL:${NINTENDO_SWITCH}>:nxvk::nxvk>` to `rexgpu-xenos`'s link libraries.
- `src/ui/CMakeLists.txt`: same for `rexui`; the Vulkan sources list already excludes platform surfaces on Switch (`REXUI_PLATFORM_SOURCES` empty). `vulkan_moltenvk.cpp` is Apple-only; confirm it is guarded or excluded.
- `src/system/CMakeLists.txt`: `rexruntime` on Switch is STATIC; it links `Vulkan::Headers` and VMA already under `REXGLUE_USE_VULKAN`.
- `thirdparty/CMakeLists.txt`: the `REXGLUE_USE_VULKAN` blocks (vulkan-headers, VMA, spirv-headers, spirv-tools-headers, glslang) must not be skipped on Switch; glslang needs `-DENABLE_HLSL=OFF -DENABLE_OPT=OFF -DBUILD_EXTERNAL=OFF` style options if they are not already set, and its `OSDependent/Unix` uses pthreads only (fine on libnx). Add `SPIRV-Tools` is headers-only here.
- The `ui/vulkan/vulkan_instance.cpp` loader path still compiles on Switch (DynamicLibrary stub); the runtime failure is fixed in Task 2.

Run: `cd /home/chris/Projects/NFSMW-Recompiled && DEVKITPRO=$HOME/.local/opt/devkitpro tools/build_switch.sh`
Expected: `nfsmw-recomp.nro` packed. Link errors to expect and fix: missing `vk_icd*` symbols (whole-archive missing), Rust runtime symbols (`-lstdc++ -pthread`), `expat`/`z` (portlibs present: `libz.a`, `libexpat.a`).

- [ ] **Step 4: Linux regression**

Run the Linux regression from Global Constraints (Vulkan backend). Expected: unchanged behaviour, `[fps]` lines, no `[error]`.

- [ ] **Step 5: Commit**

```bash
git add CMakeLists.txt cmake/rexglue_nxvk.cmake thirdparty/CMakeLists.txt src/graphics/CMakeLists.txt src/ui/CMakeLists.txt src/system/CMakeLists.txt
git commit -m "build(switch): Vulkan backend linked against NXVK"
```

---

### Task 2: Static NXVK entry point and `VK_NN_vi_surface` in the instance

**Files:**
- Modify: `include/rex/ui/vulkan/api.h:30-60` (add `VK_USE_PLATFORM_VI_NN` under `REX_PLATFORM_SWITCH`)
- Modify: `src/ui/vulkan/vulkan_instance.cpp:44-90` (loader binding), `:140-160` (surface extension request)
- Modify: `include/rex/ui/vulkan/instance.h` (extension flag `ext_NN_vi_surface`; instance function `vkCreateViSurfaceNN` in the function table — find the macro list that declares `vkCreateXcbSurfaceKHR` and add the NN entry under `#if VK_USE_PLATFORM_VI_NN`)
- Reference: NXVK `switch/smoke/nvk_harness.h:26,113,148-183,258` (how NXVK's own apps use `vk_icdGetInstanceProcAddr`)

**Interfaces:**
- Produces: on Switch, `VulkanInstance::Create` succeeds without any loader library; `instance->extensions().ext_NN_vi_surface` true when NXVK exposes it; `ifn.vkCreateViSurfaceNN` loaded.

- [ ] **Step 1: Platform define**

In `api.h`, beside the XCB/Wayland blocks:

```cpp
#if REX_PLATFORM_SWITCH
#ifndef VK_USE_PLATFORM_VI_NN
#define VK_USE_PLATFORM_VI_NN
#endif
#endif
```

`vulkan.h` then includes `vulkan_vi.h` (needs `<switch.h>`'s `NWindow`? No: `VkViSurfaceCreateInfoNN::window` is `void*`).

- [ ] **Step 2: Bind the static entry point**

In `vulkan_instance.cpp`, wrap the loader-library block (the `#if REX_PLATFORM_MAC ... #else ... #endif` that ends with `#undef XE_VULKAN_LOAD_LOADER_FUNCTION`) so that on Switch it becomes:

```cpp
#if REX_PLATFORM_SWITCH
  // NXVK is linked statically and has no loader: its ICD entry point is the
  // instance proc address function.
  extern "C" PFN_vkVoidFunction vk_icdGetInstanceProcAddr(VkInstance instance, const char* name);
  ifn.vkGetInstanceProcAddr = PFN_vkGetInstanceProcAddr(vk_icdGetInstanceProcAddr);
  // vkDestroyInstance is an instance-level command in the ICD interface; it is
  // resolved after vkCreateInstance below.
  ifn.vkDestroyInstance = nullptr;
#else
  ... existing loader code ...
#endif
```

(Declare the extern at file scope, not inside the function.) After the instance is created (`ifn.vkCreateInstance(...)` succeeds), add:

```cpp
#if REX_PLATFORM_SWITCH
  ifn.vkDestroyInstance = PFN_vkDestroyInstance(ifn.vkGetInstanceProcAddr(vulkan_instance->instance_, "vkDestroyInstance"));
  if (!ifn.vkDestroyInstance) { REXLOG_ERROR("NXVK: vkDestroyInstance not resolvable"); return nullptr; }
#endif
```

and skip any early check that required `vkDestroyInstance` non-null before creation on Switch.

- [ ] **Step 3: Request the VI surface extension**

In the `if (with_surface)` block:

```cpp
#ifdef VK_USE_PLATFORM_VI_NN
    requested_extensions.emplace("VK_NN_vi_surface", &vulkan_instance->extensions_.ext_NN_vi_surface);
#endif
```

Add `bool ext_NN_vi_surface = false;` to the extensions struct in `instance.h`, and `vkCreateViSurfaceNN` to the instance-level function table under `#ifdef VK_USE_PLATFORM_VI_NN` in the same macro list that has `vkCreateXcbSurfaceKHR` (the loader that resolves extension functions must treat it as optional, like the other platform surface functions).

- [ ] **Step 4: Build both targets**

Linux regression (Global Constraints) and the Switch build. Expected: both build; Linux game runs as before.

- [ ] **Step 5: Commit**

```bash
git add include/rex/ui/vulkan/api.h include/rex/ui/vulkan/instance.h src/ui/vulkan/vulkan_instance.cpp
git commit -m "feat(vulkan): static NXVK entry point and VK_NN_vi_surface on Switch"
```

---

### Task 3: libnx NWindow surface, created with `vkCreateViSurfaceNN`

**Files:**
- Modify: `include/rex/ui/surface.h:36-46` (`kTypeIndex_LibnxNWindow`, `kTypeFlag_LibnxNWindow`)
- Create: `include/rex/ui/surface_switch.h`
- Modify: `src/ui/window_switch.cpp:64-67` (`CreateSurfaceImpl`)
- Modify: `src/ui/vulkan/vulkan_presenter.cpp:420-450` (supported types), `:800-845` (creation switch)

**Interfaces:**
- Consumes: `extensions().ext_NN_vi_surface`, `ifn.vkCreateViSurfaceNN` (Task 2).
- Produces: `class LibnxNWindowSurface final : public Surface { NWindow* nwindow() const; }`.

- [ ] **Step 1: Surface type and class**

`surface.h`: add `kTypeIndex_LibnxNWindow` after `kTypeIndex_CAMetalLayer` and `kTypeFlag_LibnxNWindow = TypeFlags(1) << kTypeIndex_LibnxNWindow`.

`include/rex/ui/surface_switch.h`:

```cpp
#pragma once
#include <switch.h>
#include <rex/ui/surface.h>
namespace rex::ui {
class LibnxNWindowSurface final : public Surface {
 public:
  explicit LibnxNWindowSurface(NWindow* nwindow) : nwindow_(nwindow) {}
  TypeIndex GetType() const override { return kTypeIndex_LibnxNWindow; }
  NWindow* nwindow() const { return nwindow_; }
 protected:
  bool GetSizeImpl(uint32_t& width_out, uint32_t& height_out) const override {
    u32 w = 1280, h = 720;
    nwindowGetDimensions(nwindow_, &w, &h);
    width_out = w; height_out = h;
    return true;
  }
 private:
  NWindow* nwindow_;
};
}  // namespace rex::ui
```

`window_switch.cpp` `CreateSurfaceImpl(allowed_types)`: return `std::make_unique<LibnxNWindowSurface>(nwindowGetDefault())` when `allowed_types & Surface::kTypeFlag_LibnxNWindow`, else `nullptr`.

- [ ] **Step 2: Presenter**

In `GetSupportedSurfaceTypes` (the block with `#if REX_PLATFORM_GNU_LINUX ... #endif`):

```cpp
#if REX_PLATFORM_SWITCH
  if (instance_extensions.ext_NN_vi_surface) {
    type_flags |= Surface::kTypeFlag_LibnxNWindow;
  }
#endif
```

In the surface creation `switch` (beside the XCB case):

```cpp
#if REX_PLATFORM_SWITCH
      case Surface::kTypeIndex_LibnxNWindow: {
        auto& nwindow_surface = static_cast<const LibnxNWindowSurface&>(new_surface);
        VkViSurfaceCreateInfoNN surface_create_info;
        surface_create_info.sType = VK_STRUCTURE_TYPE_VI_SURFACE_CREATE_INFO_NN;
        surface_create_info.pNext = nullptr;
        surface_create_info.flags = 0;
        surface_create_info.window = nwindow_surface.nwindow();
        vulkan_surface_create_result = ifn.vkCreateViSurfaceNN(
            instance, &surface_create_info, nullptr, &vulkan_surface);
      } break;
#endif
```

(Use the same variable names as the neighbouring cases.)

- [ ] **Step 3: Build both, commit**

Switch build + Linux regression. Then:

```bash
git add include/rex/ui/surface.h include/rex/ui/surface_switch.h src/ui/window_switch.cpp src/ui/vulkan/vulkan_presenter.cpp
git commit -m "feat(switch): libnx NWindow surface for the Vulkan presenter"
```

---

### Task 4: Paint through the presenter; Vulkan as the Switch default; Eden bring-up

**Files:**
- Modify: `src/ui/windowed_app_context_switch.cpp:71-137`, `include/rex/ui/windowed_app_context_switch.h`
- Modify: `src/ui/window_switch.cpp` (expose the presenter set via `SetPresenter` if `Window` does not already)
- Modify: `src/ui/rex_app.cpp:83-89` (Switch `gpu_backend` cvar: default `"vulkan"`, allowed `{"vulkan", "null"}`)
- Modify (app repo): `app/src/nfsmw_app.h` (remove the `#if REX_PLATFORM_SWITCH` branch in `MideFotogramas`; keep `LineaDeEstadoSwitch` but only for the console fallback), `docs/switch.md` (status table, NXVK build/install steps, licensing note)

**Interfaces:**
- Consumes: `Window::SetPresenter` (`include/rex/ui/window.h:354`), `Presenter::PaintFromUIThread` (`presenter.h:347`).

- [ ] **Step 1: Loop**

`RunMainMessageLoop`: if the window has a presenter after `OnInitialize`, do not `consoleInit`; each iteration: `appletMainLoop()`, pad update (`+` exits), `presenter->PaintFromUIThread()`. Keep the console path when no presenter (null backend) and for `RunFatalScreen`. Remove the 500 ms redraw timer in the presenter path (vsync is in the swapchain, `VK_PRESENT_MODE_FIFO_KHR`).

- [ ] **Step 2: Defaults and app**

`rex_app.cpp` Switch block: `REXCVAR_DEFINE_STRING(gpu_backend, "vulkan", "GPU", "Graphics API: vulkan (NXVK) or null (no rendering).").allowed({"vulkan", "null"})`. App: `MideFotogramas` uses the presenter's `guest_frames_refreshed()` on every platform; `nfsmw_app.h` Switch includes drop `<rex/graphics/null/graphics_system.h>` unless still used by the console status line.

- [ ] **Step 3: Eden bring-up**

Build the .nro, run in Eden per Global Constraints, wait 60 s, read the log. Expected sequence: `Vulkan` instance created (API 1.3), physical device `NV120`/`GM20B` name, device created with the required features, presenter connected to the NWindow surface, `[fps]` lines, no `Unhandled guest access violation`. Screenshot the Eden window (`spectacle -b -n -f -o /tmp/eden-vk.png`). If device creation fails in Eden but not obviously in the driver (e.g. nvservices ioctl unsupported in the emulator), record the exact error and hand the .nro to the user for hardware; that is not a task failure.

- [ ] **Step 4: Commit (both repos) and hand to hardware**

```bash
git -C /home/chris/Projects/rexglue-sdk add src/ui/windowed_app_context_switch.cpp include/rex/ui/windowed_app_context_switch.h src/ui/window_switch.cpp src/ui/rex_app.cpp
git -C /home/chris/Projects/rexglue-sdk commit -m "feat(switch): present through the Vulkan presenter, vulkan default"
git -C /home/chris/Projects/NFSMW-Recompiled add app/src/nfsmw_app.h docs/switch.md
git -C /home/chris/Projects/NFSMW-Recompiled commit -m "docs(switch): NXVK renderer setup and status"
```

Deliver `build/switch/nfsmw-recomp/` for the hardware check.

---

### Task 5: Draws on hardware — first-failure loop and tuning

**Files:**
- Modify as found: `src/graphics/vulkan/*`, `src/ui/vulkan/*` (guards for missing optional features), app `nfsmw.toml` defaults for Switch (`resolution_scale = 1`, `readback_resolve_max_bytes`, `guest_sleep0_us`)
- Reference: the user's hardware `logs/nfsmw_NNN.log` and `crash.txt` (`aarch64-none-elf-addr2line -e app/out/build/switch-release/nfsmw-recomp.elf 0x...`)

This task is a loop, not a fixed change: each round takes the newest hardware/Eden log, finds the first `[error]`/fault, fixes the smallest thing in the SDK or driver usage, rebuilds, re-runs. Concrete first checks:

- [ ] Device features the backend requests but NXVK lacks on Maxwell → confirm each is optional in `vulkan_device.cpp` (fragment shader interlock already is).
- [ ] Memory: log `mallinfo` after `SetupGuestGpu`; if the 512 MiB shared-memory buffer allocation fails, lower it via the existing cvar/constant and note it.
- [ ] Present mode: FIFO at 60 Hz with a 30 fps guest is fine; if the presenter spins, set the swapchain image count to 2.
- [ ] Frame time on hardware: `[fps]` lines in the log; profile the command-processor thread share with the watchdog snapshots already in the app.
- [ ] Commit each fix separately with a message naming the log line it addresses.

Done when the main menu renders on hardware; in-world rendering and tuning continue in the same loop.

## Self-review

- Spec coverage: build/link (T1), entry point + extension (T2), surface (T3), app loop + defaults + docs (T4), bring-up/tuning (T5). Validation (SpirvTools/RenderDoc) needs no change (spec §6).
- Placeholders: T5 is a loop by nature with concrete first checks; T1's `.pc` uncertainty is resolved by an explicit either/or instruction.
- Names: `LibnxNWindowSurface`, `kTypeFlag_LibnxNWindow`, `ext_NN_vi_surface`, `vkCreateViSurfaceNN`, `nxvk::nxvk` consistent across T1–T4.
