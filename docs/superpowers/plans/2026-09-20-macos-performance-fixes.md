# macOS Performance Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the four root causes of the macOS build's 4–7 fps slowdown, as patch scripts applied to the SDK the same way the existing ten are, wired into both build scripts and documented.

**Architecture:** All fixes live in the SDK source tree and are applied by `tools/parche_*.py` scripts (the project's convention: the SDK repo receives no hand edits, only these scripts). Each script applies and reverts by exact text substitution, block by block, refuses to write when an anchor does not match exactly once, and is idempotent. The app repo gets the scripts, the build wiring, and the docs; the app's `nfsmw_app.h` already requests `guest_sleep0_us` so no app code changes are needed.

**Tech Stack:** Python 3.10+ (patch scripts), C++23 SDK (ReXGlue v0.10.0 checkout at `../rexglue-sdk`), CMake/Ninja, macOS Apple Silicon + MoltenVK.

**Spec:** the investigation in this session. Root causes, with measurements:

1. **UI repaint has no rate limit off Windows.** `ImGuiDrawer::Draw` requests a repaint every frame while any dialog is registered (`src/ui/imgui_drawer.cpp:439`), and `ReXApp::LaunchModule` always creates the achievement-toast dialog (`src/ui/rex_app.cpp:507`). `Presenter::WaitForUITickFromUIThread` limits UI painting to the monitor vblank only on Windows (`src/ui/presenter.cpp:1583`, body under `#if REX_PLATFORM_WIN32`); off Windows it is an empty function. Measured: 197–205 UI paints/s at 4.8 ms each (UI thread ~100% busy), guest `RefreshGuestOutput` 30–43 ms/swap, game ~15 fps. Throttling the UI to 60 Hz: refresh 7–14 ms, game ~24 fps.
2. **The final guest-output paint pipeline is recreated on every paint.** `GuestOutputPaintPipeline::swapchain_format` (`include/rex/ui/vulkan/presenter.h:310`) is never assigned, so the mismatch check at `src/ui/vulkan/vulkan_presenter.cpp:1828` always fires, destroys the pipeline, and recreates it with a null `VkPipelineCache` (`:1839`). On MoltenVK that re-runs SPIRV-Cross and Metal pipeline compilation. Host sample: 150/569 UI-thread samples in `CreateGuestOutputPaintPipeline` → `vkCreateGraphicsPipelines`.
3. **GPU-plugin cvars from `nfsmw.toml`/CLI are silently lost when the backend falls back.** `LoadGpuPlugin` (`src/system/gpu_plugin_loader.cpp:57`) loads the plugin, the factory returns null for `d3d12`, and the local `DynamicLibrary` is destroyed → `dlclose` → the plugin's cvars are unregistered. The app then loads the plugin again for `vulkan` (`src/ui/rex_app.cpp:354-366`); the pending config/CLI cvar values were consumed by the first registration and are gone, so the plugin keeps its defaults. Measured: `resolution_scale` late registration #1 `pending config=2 cmdline=2`, #2 `pending_found=false`, effective `1x1`. The same applies to `anisotropic_override`, `render_target_path_d3d12`, `vulkan_*`.
4. **The guest main thread busy-polls `Sleep(0)`.** `XThread::Delay` maps a zero timeout to `MaybeYield()` (`src/system/xthread.cpp:1076-1081`). Measured: 1500–2450 zero-timeout waits/s consuming ~1000 ms of every second (~1 core). The app already sets `guest_sleep0_us = 50` (`app/src/nfsmw_app.h:288`) but that cvar does not exist in this SDK, so the setting is a no-op.

**Non-fixes (deliberately):** `readback_resolve=fast` showed no fps impact at scale 1 and is a visual-correctness fix in the app; the remaining ~25 fps ceiling at 1080p matches the 25–35 fps the docs recorded on this M1 and is the emulation path's normal cost.

## Global Constraints

- SDK repo gets **no source changes** other than what the patch scripts apply. Every script follows the `tools/parche_velocidad.py` pattern: text substitution, block by block, anchor count must be exactly 1 before writing anything, `--estado` and `--revertir`, idempotent, no `.original` files (presenter.cpp already carries `parche_fotogramas`; a `.original` would take it down on revert).
- Comments in the patch scripts and in the patched SDK code are Spanish, matching the existing patches. User-facing cvar descriptions are English (they show up in the F4 menu).
- Patch names: `parche_ui_ticks`, `parche_pipeline_pintado`, `parche_cvar_plugin`, `parche_sleep0`.
- Commits: Conventional Commits, imperative, ≤72 chars, no attribution trailers, one commit per task.
- Application order is free except that all four are independent of the existing ten. In `tools/build_mac.sh` they go after `parche_fotogramas`; in `CONSTRUIR.bat` after `parche_privilegios`.
- Verification of the performance fix: rebuild the SDK, the app and `build/mac`, run the attract mode, and compare against the recorded baseline (baseline with the shipped config: 2.5–6.5 fps; ~15 fps at 1080p with the churn).

## Review Focus

- **The UI limiter must never add latency to guest frames.** The guest's present sets the force flag; the wait polls it every 1 ms. If a guest frame ever waits a full UI tick, the fix has regressed.
- **The UI limiter must not deadlock or spin when the window is minimized/occluded.** `InSurfaceOnMonitorFromUIThread` returns early before the wait; when it does not, the wait is bounded by one tick.
- **Applying fix 3 changes what the shipped config does.** `app/nfsmw.toml` ships `resolution_scale = 2` (4K internal at 1080p). Until now it was ignored on macOS. After fix 3 it will be honored; measure both scale 1 and scale 2 and report, and adjust the mac dist config only if scale 2 is unplayable.
- **The plugin must stay loaded after a failed factory call.** Keeping it loaded is what preserves the cvars; the second load must still succeed with the other backend.
- **`guest_sleep0_us = 0` must be byte-for-byte the old behavior** (yield / 100 µs for below-normal priority), so the patch is inert unless the app asks for a sleep.

---

### Task 1: `tools/parche_ui_ticks.py` — rate-limit UI painting off Windows

**Files:**
- Create: `tools/parche_ui_ticks.py`
- Modify (via the script only): `../rexglue-sdk/src/ui/presenter.cpp`

**Interfaces:**
- Produces: `parche_ui_ticks.py` with `--estado` / `--revertir`, four blocks: `cabeceras`, `estado del limite`, `espera del tick`, `peticion de tick inmediato`.

- [ ] **Step 1: Write the script**

Anchors and replacements (verbatim from the clean SDK):

Includes anchor:
```cpp
#include <algorithm>
#include <atomic>
#include <cctype>
#include <utility>
```
Replacement adds `<chrono>` and `<thread>` after `<cctype>`.

Statics anchor (inserted before the function):
```cpp
void Presenter::WaitForUITickFromUIThread() {
```
Replacement:
```cpp
// PARCHE LOCAL - limite de ritmo de la UI fuera de Windows
//
// En Windows esto espera al vblank de DXGI y el present del guest lo
// interrumpe con ForceUIThreadPaintTick. Fuera de Windows no habia nada: la
// funcion era un no-op, asi que un dialogo que pida repintado cada fotograma
// -y el toast de logros se registra siempre- pintaba a la velocidad que le
// dejara el sistema. Medido en un M1: ~200 pintados por segundo de 4.8 ms
// cada uno, el hilo de UI al 100%, el refresh del guest esperando 30-43 ms
// por swap y el juego a ~15 fps con la GPU al 60-70%.
static std::atomic<bool> g_ui_tick_force_requested{false};
static std::atomic<int64_t> g_ui_tick_last_us{0};

void Presenter::WaitForUITickFromUIThread() {
```

Wait body anchor (the tail of the Win32 wait plus the whole Win32 ForceUIThreadPaintTick):
```cpp
    dxgi_ui_tick_signal_condition_.wait(dxgi_ui_tick_lock);
  }
#endif  // XE_PLATFORM
}

void Presenter::ForceUIThreadPaintTick() {
#if REX_PLATFORM_WIN32
  std::scoped_lock<std::mutex> dxgi_ui_tick_lock(dxgi_ui_tick_mutex_);
  dxgi_ui_tick_force_requested_ = true;
#endif  // XE_PLATFORM
}
```
Replacement inserts an `#else` branch in both functions. The wait branch:
```cpp
#else
  // Limite al ritmo del modo de video del guest (60 Hz por defecto, el mismo
  // valor que usa el hilo del vblank). El present del guest no espera: su
  // peticion pone el aviso de salto y la espera lo consulta cada milisegundo,
  // igual que el vblank interrumpe la espera en Windows.
  if (g_ui_tick_force_requested.exchange(false, std::memory_order_acq_rel)) {
    return;
  }
  double refresh_rate_hz = std::clamp(REXCVAR_GET(video_mode_refresh_rate), 24.0, 240.0);
  int64_t interval_us = int64_t(1000000.0 / refresh_rate_hz);
  auto now_us = std::chrono::duration_cast<std::chrono::microseconds>(
                    std::chrono::steady_clock::now().time_since_epoch())
                    .count();
  int64_t last_us = g_ui_tick_last_us.load(std::memory_order_relaxed);
  if (last_us != 0) {
    int64_t next_us = last_us + interval_us;
    while (next_us > now_us) {
      if (g_ui_tick_force_requested.load(std::memory_order_acquire)) {
        break;
      }
      std::this_thread::sleep_for(
          std::chrono::microseconds(std::min<int64_t>(1000, next_us - now_us)));
      now_us = std::chrono::duration_cast<std::chrono::microseconds>(
                   std::chrono::steady_clock::now().time_since_epoch())
                   .count();
    }
  }
  g_ui_tick_last_us.store(now_us, std::memory_order_relaxed);
#endif  // XE_PLATFORM
```
The force-tick branch:
```cpp
#else
  g_ui_tick_force_requested.store(true, std::memory_order_release);
#endif  // XE_PLATFORM
```
Script structure copies `parche_velocidad.py` (BLOQUES list, `quitar_version_vieja` not needed — no previous versions; apply/estado/revertir with the block-by-block loops).

- [ ] **Step 2: Verify apply / estado / idempotency / revert on the real SDK**

Run:
```bash
python3.12 tools/parche_ui_ticks.py --estado
python3.12 tools/parche_ui_ticks.py
python3.12 tools/parche_ui_ticks.py
python3.12 tools/parche_ui_ticks.py --estado
python3.12 tools/parche_ui_ticks.py --revertir
git -C ../rexglue-sdk diff --stat -- src/ui/presenter.cpp
```
Expected: first `--estado` reports 0/4; first apply applies 4 blocks; second says already applied; `--estado` reports 4/4; revert leaves only the `parche_fotogramas` hunk (4 added lines) in the diff.

- [ ] **Step 3: Re-apply and commit**

```bash
python3.12 tools/parche_ui_ticks.py
git add tools/parche_ui_ticks.py
git commit -m "fix(sdk): rate-limit UI painting off Windows"
```

---

### Task 2: `tools/parche_pipeline_pintado.py` — cache the swapchain paint pipeline

**Files:**
- Create: `tools/parche_pipeline_pintado.py`
- Modify (via the script only): `../rexglue-sdk/src/ui/vulkan/vulkan_presenter.cpp`

- [ ] **Step 1: Write the script**

Anchor:
```cpp
            swapchain_effect_pipeline.swapchain_pipeline = CreateGuestOutputPaintPipeline(
                swapchain_effect, paint_context_.swapchain_render_pass);
            if (swapchain_effect_pipeline.swapchain_pipeline == VK_NULL_HANDLE) {
              guest_output_flow.effect_count = 0;
            }
```
Replacement:
```cpp
            swapchain_effect_pipeline.swapchain_pipeline = CreateGuestOutputPaintPipeline(
                swapchain_effect, paint_context_.swapchain_render_pass);
            if (swapchain_effect_pipeline.swapchain_pipeline == VK_NULL_HANDLE) {
              guest_output_flow.effect_count = 0;
            } else {
              // PARCHE LOCAL - no recrear el pipeline del presentador cada vez
              //
              // swapchain_format se queda en VK_FORMAT_UNDEFINED para siempre
              // (nadie lo asigna), asi que la comprobacion de arriba veia
              // "formato cambiado" en CADA pintado, destruia el pipeline y lo
              // volvia a crear con VK_NULL_HANDLE de cache. En MoltenVK eso
              // significa recompilar el SPIR-V a MSL y crear el pipeline de
              // Metal en cada fotograma (medido: 150 de 569 muestras del hilo
              // de UI dentro de vkCreateGraphicsPipelines). Con el campo puesto
              // el pipeline se crea una vez por formato de swapchain.
              swapchain_effect_pipeline.swapchain_format =
                  paint_context_.swapchain_render_pass_format;
            }
```
One block; same script structure as Task 1.

- [ ] **Step 2: Verify apply / idempotency / revert**

Run the four `--estado`/apply/revert steps; after revert `git -C ../rexglue-sdk diff --stat -- src/ui/vulkan/vulkan_presenter.cpp` must show nothing.

- [ ] **Step 3: Re-apply and commit**

```bash
python3.12 tools/parche_pipeline_pintado.py
git add tools/parche_pipeline_pintado.py
git commit -m "fix(sdk): stop recreating the presenter pipeline every paint"
```

---

### Task 3: `tools/parche_cvar_plugin.py` — keep the plugin loaded when the factory fails

**Files:**
- Create: `tools/parche_cvar_plugin.py`
- Modify (via the script only): `../rexglue-sdk/src/system/gpu_plugin_loader.cpp`

- [ ] **Step 1: Write the script**

Anchor:
```cpp
  IGraphicsSystem* graphics_system = create_fn(kGpuPluginAbiVersion, &info);
  if (!graphics_system) {
    REXSYS_ERROR("GPU plugin '{}' factory returned no graphics system (backend '{}')", name,
                 backend_str);
    return nullptr;
  }
```
Replacement:
```cpp
  IGraphicsSystem* graphics_system = create_fn(kGpuPluginAbiVersion, &info);
  if (!graphics_system) {
    REXSYS_ERROR("GPU plugin '{}' factory returned no graphics system (backend '{}')", name,
                 backend_str);
    // PARCHE LOCAL - no perder los cvars del plugin al caer a otro backend
    //
    // El fallo de fabrica no significa que la libreria este rota: la app pide
    // d3d12, el plugin no lo lleva compilado, y la app vuelve a llamar aqui
    // con vulkan. Pero al salir por aqui la DynamicLibrary local se destruia
    // (dlclose), sus destructores estaticos desregistraban los cvars del
    // plugin y el segundo Load los volvia a registrar con los valores por
    // defecto: los valores de nfsmw.toml y de la linea de comandos se habian
    // consumido en el primer registro y se perdian en silencio (medido:
    // resolution_scale=2 en el toml y efectivo 1x1; lo mismo con
    // anisotropic_override y los vulkan_*). Manteniendo la libreria cargada
    // -los plugins ya viven toda la vida del proceso, ver LoadedPlugins- el
    // segundo Load reutiliza la misma imagen, no se re-registra nada y los
    // valores puestos se conservan.
    LoadedPlugins().push_back(std::move(library));
    return nullptr;
  }
```
One block.

- [ ] **Step 2: Verify apply / idempotency / revert**

Same four-step check; after revert the file's diff must be empty.

- [ ] **Step 3: Re-apply and commit**

```bash
python3.12 tools/parche_cvar_plugin.py
git add tools/parche_cvar_plugin.py
git commit -m "fix(sdk): keep plugin cvars when the backend falls back"
```

---

### Task 4: `tools/parche_sleep0.py` — `guest_sleep0_us`

**Files:**
- Create: `tools/parche_sleep0.py`
- Modify (via the script only): `../rexglue-sdk/src/system/xthread.cpp`

- [ ] **Step 1: Write the script**

Cvar anchor:
```cpp
REXCVAR_DEFINE_BOOL(ignore_thread_affinities, true, "Kernel",
                    "Ignores game-specified thread affinities");
```
Replacement adds:
```cpp

// PARCHE LOCAL - sueno real en los sondeos con Sleep(0)
//
// El juego sondea con Sleep(0) sin parar: medido, 1500-2450 llamadas por
// segundo que consumian ~1000 ms de cada segundo (un nucleo entero) porque
// Sleep(0) acaba en sched_yield. Con un sueno real de 50 us por sondeo el
// coste baja a ~9% de un nucleo; la latencia que anade por sondeo es de
// decenas de microsegundos contra fotogramas de 16 ms. 0 deja el yield de
// antes.
REXCVAR_DEFINE_INT32(guest_sleep0_us, 0, "Kernel",
                     "Microseconds to sleep instead of yielding when the guest calls Sleep(0). "
                     "0 restores the yield.")
    .range(0, 1000000)
    .lifecycle(rex::cvar::Lifecycle::kHotReload);
```
Delay anchor:
```cpp
    if (timeout_ms == 0) {
      if (priority_ <= rex::thread::ThreadPriority::kBelowNormal) {
        rex::thread::Sleep(std::chrono::microseconds(100));
      } else {
        rex::thread::MaybeYield();
      }
    } else {
```
Replacement:
```cpp
    if (timeout_ms == 0) {
      // PARCHE LOCAL - sueno real en los sondeos con Sleep(0)
      const int32_t sleep0_us = REXCVAR_GET(guest_sleep0_us);
      if (sleep0_us > 0) {
        rex::thread::Sleep(std::chrono::microseconds(sleep0_us));
      } else if (priority_ <= rex::thread::ThreadPriority::kBelowNormal) {
        rex::thread::Sleep(std::chrono::microseconds(100));
      } else {
        rex::thread::MaybeYield();
      }
    } else {
```
Two blocks.

- [ ] **Step 2: Verify apply / idempotency / revert**

Same four-step check. Note xthread.cpp already carries the project's diagnostics patches; the diff after revert must show only those.

- [ ] **Step 3: Re-apply and commit**

```bash
python3.12 tools/parche_sleep0.py
git add tools/parche_sleep0.py
git commit -m "fix(sdk): add guest_sleep0_us to stop Sleep(0) busy-polling"
```

---

### Task 5: Wire the four patches into both build scripts

**Files:**
- Modify: `tools/build_mac.sh:104-110`
- Modify: `CONSTRUIR.bat:150-215`

- [ ] **Step 1: `tools/build_mac.sh`**

Append the four names to the `parches` list (after `parche_fotogramas`) and update the comment above the phase if it states a count.

- [ ] **Step 2: `CONSTRUIR.bat`**

Add four `%PY% "%~dp0tools\parche_*.py"` invocations after `parche_privilegios.py`, with a short Spanish comment per patch in the style of the existing ones (what it fixes, one or two lines).

- [ ] **Step 3: Verify both scripts parse**

Run: `bash -n tools/build_mac.sh`
Expected: exit 0.
Run: `grep -c parche_ tools/build_mac.sh CONSTRUIR.bat`
Expected: the new names are present in both.

- [ ] **Step 4: Commit**

```bash
git add tools/build_mac.sh CONSTRUIR.bat
git commit -m "build: apply the four new SDK patches in both build scripts"
```

---

### Task 6: Document the patches

**Files:**
- Modify: `docs/parches.md` (new sections in the catalogue, after `parche_fotogramas`)
- Modify: `CHANGELOG.md` (Unreleased section)

- [ ] **Step 1: `docs/parches.md`**

One section per patch, in the file's tone (Spanish, "why it was needed / what it does / how it was verified"), with the measured numbers from the spec above.

- [ ] **Step 2: `CHANGELOG.md`**

Add a `### Corregido` block under `[Sin publicar]` listing the four fixes in one or two lines each.

- [ ] **Step 3: Commit**

```bash
git add docs/parches.md CHANGELOG.md
git commit -m "docs: document the four performance patches"
```

---

### Task 7: Rebuild and verify end to end

**Files:**
- Rebuild: SDK install, app, `build/mac` (no source changes)

- [ ] **Step 1: Confirm all patches are applied**

Run: `for p in tools/parche_*.py; do python3.12 "$p" --estado; done | grep -c APLICADO`
Expected: every patch reports applied (the four new ones included).

- [ ] **Step 2: Rebuild the SDK and the dist**

```bash
tools/build_mac.sh
```
Expected: phases 0–6 pass; `build/mac` and `NFSMW.app` rebuilt.

- [ ] **Step 3: Boot and measure**

Run `build/mac/nfsmw` with `--resolution_scale=1` for 100 s and with the shipped config (no flag, `resolution_scale = 2` from the toml) for 100 s; record `[fps]`, the guest frame time, and `git -C ../rexglue-sdk diff` (must show only the project's patches).
Expected: with `--resolution_scale=1`, steady state ≥ 25 fps (baseline with churn: ~15 fps); the log line `Vulkan draw resolution scaling is experimental` must appear when scale 2 is honored, proving fix 3 works.

- [ ] **Step 4: Decide the mac dist config**

If scale 2 is unplayable on the M1, change the mac dist's config (a mac-specific copy) to `resolution_scale = 1` and document it in `docs/macos.md`; otherwise leave it.

- [ ] **Step 5: Commit whatever the verification required**

```bash
git add -A
git commit -m "test(macos): verify the performance fixes end to end"
```

---

## Self-review

- Spec coverage: cause 1 → Task 1, cause 2 → Task 2, cause 3 → Task 3, cause 4 → Task 4; wiring → Task 5; docs → Task 6; verification → Task 7.
- Placeholders: none; every anchor and replacement is verbatim from the clean SDK tree.
- Names: `parche_ui_ticks`, `parche_pipeline_pintado`, `parche_cvar_plugin`, `parche_sleep0` consistent across tasks and build scripts.
- Review Focus: the limiter's guest bypass is in Task 1's 1 ms polling loop; the minimized-window early return is untouched; the scale-2 measurement is Task 7 Step 3/4; plugin-stays-loaded is Task 3; `guest_sleep0_us=0` inertness is Task 4's branch order.
