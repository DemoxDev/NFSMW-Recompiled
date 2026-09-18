# Switch renderer: the existing Vulkan backend on NXVK

Date: 2026-09-18. Status: approved (replaces the OpenGL design on branch
`switch`; this work is on `switch-vulkan` in both repos).

## Goal

Draw the game on the Nintendo Switch by running the SDK's existing Vulkan
backend (`src/graphics/vulkan`, `src/ui/vulkan`) on NXVK, the Mesa 26.2 NVK
Vulkan driver ported to Horizon (https://github.com/PalindromicBreadLoaf/nxvk).
No new GPU backend. Target rate: whatever the CPU allows (~30 fps measured
CPU-only); 60 is a later CPU-side project.

## Why NXVK

- Vulkan 1.3 on the Tegra X1 with `VK_KHR_swapchain`, `VK_NN_vi_surface`
  (libnx `NWindow` presentation), `fragmentStoresAndAtomics`,
  `vertexPipelineStoresAndAtomics`, `VK_EXT_shader_demote_to_helper_invocation`,
  `VK_EXT_non_seamless_cube_map`, robustness2: everything the backend
  requires. No fragment shader interlock on Maxwell, so the EDRAM path is
  host render targets (already the default on such devices).
- Loaderless static library (`libnvk.a` + `libnvk_support.a`, `nxvk.pc` in
  `$DEVKITPRO/portlibs/switch`), entry point `vk_icdGetInstanceProcAddr`.
- Licensing: NXVK's own files are GPL-2.0-or-later; the app is GPL-3.0, the
  SDK BSD-3-Clause. Compatible.

## What changes (SDK unless noted)

1. Build: `REXGLUE_USE_VULKAN` ON for `NINTENDO_SWITCH`; the vendored Vulkan
   stack (vulkan-headers, VMA, spirv-headers, glslang) builds for
   aarch64/newlib; `rexgpu-xenos` and `rexui` link NXVK from `nxvk.pc`
   (`libnvk.a` whole-archived, as NXVK's own link line does).
2. Instance: on Switch, bind `vkGetInstanceProcAddr` to
   `vk_icdGetInstanceProcAddr` instead of loading a loader library;
   request `VK_NN_vi_surface`; `VK_USE_PLATFORM_VI_NN` in `ui/vulkan/api.h`.
3. Surface: `Surface::kTypeIndex_LibnxNWindow` + `LibnxNWindowSurface`
   (wraps `nwindowGetDefault()`), created by `WindowSwitch::CreateSurfaceImpl`;
   the presenter creates it with `vkCreateViSurfaceNN`.
4. App loop: `SwitchWindowedAppContext` paints through the presenter
   (`PaintFromUIThread` per iteration) instead of the text console; the
   console stays for the fatal screen.
5. Defaults: `gpu_backend` on Switch = `vulkan`, allowed `{vulkan, null}`;
   app `nfsmw_app.h` drops its Switch-only fps/status branches (presenter
   path applies).
6. SPIR-V validation (`SpirvToolsContext`, dlopen) is unavailable on Switch:
   already returns "not loaded", nothing to do. RenderDoc: same.

## Risks and how they are handled

- Driver maturity: experimental, 3-day-old commits. First run may fail in
  `vkCreateDevice`, pipeline creation, or present. Each task ends with the
  .nro run in Eden and the log read; unknown Eden compatibility means the
  user runs hardware checks per task.
- Memory: guest 1.5 GB + VMA pools + shared memory buffer 512 MiB (the
  Vulkan backend's `kBufferSizeLog2 = 29`) + render targets. Watch
  `mallinfo` in the status line; NXVK allocates from the same heap.
- Toolchain: the SDK compiles with clang and links with devkitA64 g++; NXVK
  archives contain Rust (NAK) objects and need `-lstdc++ -pthread -lz
  -lexpat` (NXVK's `build-nro.sh:129-138`).
- Perf: Mesa's NVK on an A57 adds CPU overhead on the command-processor
  thread; measured after bring-up, tuned with the existing cvars
  (`vulkan_submit_on_primary_buffer_end`, `readback_resolve_max_bytes`,
  `guest_sleep0_us`).

## Testing

- Linux regression: the unattended new-career harness with the Vulkan
  backend (unchanged code paths) after each SDK task.
- Eden: `.nro` boot, log lines `Loaded Vulkan runtime` / instance / device
  creation, presenter connected, `[fps]`, no faults; screenshot.
- Hardware: the user runs `build/switch/nfsmw-recomp/` and sends
  `logs/nfsmw_NNN.log` (+ `crash.txt`).

## Milestones

1. Compiles and links: Switch build with the Vulkan backend and NXVK.
2. Instance + device + surface: presenter connected in Eden/hardware, black
   frame + ImGui overlay through Vulkan.
3. Game draws: main menu visible; then in-world.
4. Tuning: memory and frame time.
