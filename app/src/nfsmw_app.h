// nfsmw - ReXGlue Recompiled Project
//
// Customize your app by overriding virtual hooks from rex::ReXApp.

#pragma once

// Windows primero y reducido a proposito: las cabeceras de rex no esperan que
// windows.h haya dejado macros por medio.
#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <shellapi.h>
#endif

#include "nfsmw_menu.h"

#include <rex/cvar.h>
#include <rex/filesystem.h>
#include <rex/logging.h>
#include <rex/rex_app.h>
#include <rex/ui/imgui_dialog.h>  // PERF OVERLAY (--perf_overlay)
#include <rex/ui/overlay/debug_overlay.h>
#include <rex/ui/keybinds.h>   // RegisterBind/UnregisterBind (the menu's ESC key)
#include <rex/ui/presenter.h>  // FPS COUNTER - game frames
#include <rex/system/kernel_state.h>  // HANG WATCHDOG
#include <rex/system/xmemory.h>       // TranslateVirtual (Black Edition patch)
#include <rex/system/xthread.h>       // HANG WATCHDOG

#include <imgui.h>  // PERF OVERLAY

#if REX_PLATFORM_SWITCH
#include <malloc.h>
#include <switch.h>
#include <rex/graphics/null/graphics_system.h>  // frames counted without a presenter
#include <rex/runtime.h>
#include <rex/ui/windowed_app_context_switch.h>
#endif

REXCVAR_DEFINE_BOOL(perf_overlay, false, "UI",
                    "MangoHud-style performance overlay in the top-left corner: guest FPS, "
                    "frame time, process CPU and memory. Updates once per second.");

#include <algorithm>
#include <cstring>
#include <atomic>
#include <chrono>
#include <filesystem>
#include <map>  // HANG WATCHDOG - the signature is ordered by thread id
#include <cstdio>   // PERF OVERLAY - /proc/self/stat
#include <cstdlib>
#ifdef __linux__
#include <unistd.h>  // PERF OVERLAY - sysconf
#endif
#include <memory>
#include <string>
#include <thread>
#include <vector>

// Cvar "Contenido > black_edition", definido en nfsmw_menu.cpp.
REXCVAR_DECLARE(bool, black_edition);

class NfsmwApp : public rex::ReXApp {
 public:
  using rex::ReXApp::ReXApp;

  static std::unique_ptr<rex::ui::WindowedApp> Create(
      rex::ui::WindowedAppContext& ctx) {
    return std::unique_ptr<NfsmwApp>(new NfsmwApp(ctx, "nfsmw",
        PPCImageConfig));
  }

  // Available hooks that are unused:
  //   void OnPreSetup(rex::RuntimeConfig& config) override {}
  //   void OnLoadXexImage(std::string& xex_image) override {}
  //
  // The hooks in use: portable paths, mandatory settings, the fps counter,
  // the Black Edition patch (OnPostLoadXexImage), and OnCreateDialogs, which
  // carries both the ESC settings menu and the --perf_overlay HUD.

 protected:
  // ==========================================================================
  //  1. PORTABLE PATHS: find the ISO next to the .exe
  //
  //  Without this, starting without --game_data_root dies with
  //      "--game_data_root was not provided."
  //  because SetupEnvironment only looks at the cvar and, if it's empty,
  //  ConstructRuntime aborts.
  //
  //  OnConfigurePaths is called right after building the PathConfig and
  //  before anyone uses it, so it's the place to fill the gap.
  //
  //  ORDER MATTERS: this runs BEFORE nfsmw.toml is loaded -the SDK reads it
  //  a few lines below, in SetupEnvironment-. So the real priority is:
  //  --game_data_root from the command line, and if not, whatever is found
  //  here alongside it. Putting game_data_root in the toml does NOT work,
  //  and that's not our doing: it's how the SDK is ordered.
  //
  //  Searched for, in this order:
  //    1. an .iso whose name matches the executable's
  //    2. any other .iso in the folder, alphabetically
  //    3. a game_root\ folder, in case someone prefers to extract it
  //
  //  (1) exists so that a folder with NFS_Most_Wanted.exe and
  //  NFS_Most_Wanted.iso works unambiguously even if there are more images.
  // ==========================================================================
  void OnConfigurePaths(rex::PathConfig& paths) override {
#if REX_PLATFORM_SWITCH
    // Switch: everything lives next to the .nro on the SD card. The game is an
    // extracted folder (FAT32 cards can't hold the ISO, and ISOs aren't
    // mounted on this platform); saves go to saves/ like tools/run.sh does.
    {
      std::error_code ec;
      const auto carpeta = rex::filesystem::GetExecutableFolder();
      if (paths.game_data_root.empty()) {
        for (const char* nombre : {"game", "game_root"}) {
          if (std::filesystem::is_directory(carpeta / nombre, ec)) {
            paths.game_data_root = carpeta / nombre;
            break;
          }
        }
      }
      if (REXCVAR_GET(user_data_root).empty()) {
        paths.user_data_root = carpeta / "saves";
        if (REXCVAR_GET(cache_root).empty()) {
          paths.cache_root = paths.user_data_root / "cache";
        }
      }
      return;
    }
#endif
    if (!paths.game_data_root.empty()) {
      return;  // the user specified it on the command line; they take precedence.
    }

    std::error_code ec;
    const auto carpeta = rex::filesystem::GetExecutableFolder();
    if (carpeta.empty() || !std::filesystem::is_directory(carpeta, ec)) {
      return;
    }

    // The executable's name, for the preferred case.
    std::filesystem::path preferida;
    std::vector<std::filesystem::path> otras;

    std::string yo;
    {
      const auto exe = rex::filesystem::GetExecutablePath();
      if (!exe.empty()) {
        yo = exe.stem().string();
        std::transform(yo.begin(), yo.end(), yo.begin(),
                       [](unsigned char c) { return char(std::tolower(c)); });
      }
    }

    for (const auto& e : std::filesystem::directory_iterator(carpeta, ec)) {
      if (ec) break;
      if (!e.is_regular_file(ec)) continue;

      std::string ext = e.path().extension().string();
      std::transform(ext.begin(), ext.end(), ext.begin(),
                     [](unsigned char c) { return char(std::tolower(c)); });
      if (ext != ".iso") continue;

      std::string base = e.path().stem().string();
      std::transform(base.begin(), base.end(), base.begin(),
                     [](unsigned char c) { return char(std::tolower(c)); });

      if (!yo.empty() && base == yo) {
        preferida = e.path();
      } else {
        otras.push_back(e.path());
      }
    }

    if (!preferida.empty()) {
      paths.game_data_root = preferida;
    } else if (!otras.empty()) {
      std::sort(otras.begin(), otras.end());
      paths.game_data_root = otras.front();
    } else {
      // No ISO: an extracted folder alongside also works. The ISO patch
      // left --game_data_root accepting both.
      const auto extraida = carpeta / "game_root";
      if (std::filesystem::is_directory(extraida, ec)) {
        paths.game_data_root = extraida;
      }
    }
    // If nothing is found, it's left empty on purpose: the SDK will give its
    // own message, which is clearer than anything we'd put here.
  }

  // ==========================================================================
  //  2. MANDATORY SETTINGS
  //
  //  So that "NFS_Most_Wanted.exe" alone, without a single argument, starts
  //  up just as well as with the usual long command line.
  //
  //  Only the ones the user has NOT set are touched: HasNonDefaultValue
  //  distinguishes "this comes from the factory" from "someone requested
  //  this". This way the command line and nfsmw.toml still take precedence.
  //
  //  WHY IN TWO DIFFERENT PLACES
  //  The readback_resolve cvar doesn't exist yet when logging starts up: it's
  //  registered by the GPU plugin (rexgpu-xenos.dll), which loads later, in
  //  SetupPresentation. Setting it earlier would mean writing to a flag that
  //  doesn't exist yet. Hence:
  //
  //    OnPostInitLogging  -> gpu_plugin and mnk_mode, which belong to the
  //                          runtime and are already registered. And it has
  //                          to be HERE, because SetupPresentation reads
  //                          gpu_plugin right after.
  //    OnPostSetup        -> readback_resolve, once the plugin has loaded
  //                          and not a single frame has been drawn yet.
  // ==========================================================================
  void OnPostInitLogging() override {
    // Without a GPU plugin the screen stays black: the game runs, but the
    // runtime discards its graphics calls with "no GPU emulation loaded".
    PonerSiNadieLoPidio("gpu_plugin", "xenos");
#if !REX_PLATFORM_SWITCH  // no keyboard or mouse on the Switch
    // Keyboard and mouse in addition to the controller.
    PonerSiNadieLoPidio("mnk_mode", "true");
#endif
  }

  void OnPostSetup() override {
    // THIS IS NOT A PREFERENCE, IT'S A FIX. The game computes its exposure
    // by measuring the scene's average brightness and reading that value
    // back on the CPU. That readback is disabled by default ("none"), so
    // the game receives garbage, concludes the scene is pitch black, and
    // cranks exposure to the max: washed-out image and blown-out sun.
    PonerSiNadieLoPidio("readback_resolve", "fast");
    // ...but only for the small targets the game actually reads back. Sampled
    // in a race: ~25 resolves per frame from 16 KB to 10 MB, all memcpy'd to
    // guest memory, ~2.4 GB/s = 12-17% of the command processor thread. With
    // the cap only the 16 KB and 60 KB ones are copied; exposure still works
    // (checked against a screenshot) and the CP thread dropped from ~78% to
    // ~62% of a core at 60 fps. If the sun ever blows out again, raise this.
    PonerSiNadieLoPidio("readback_resolve_max_bytes", "65536");

    // Present from the UI thread, never inline on the GPU command processor
    // thread. The CP thread is the frame-rate bottleneck (the game's main
    // thread spins waiting for ring space behind it), and with no dialog
    // registered the presenter paints inline on it: measured 93% CP and
    // 57-59 fps in a scene that holds 60 with this at 85%. The overlay got
    // the same effect for free because any dialog forces the UI-thread path;
    // this makes it the default with the overlay off too.
    PonerSiNadieLoPidio("host_present_from_non_ui_thread", "false");

    // A guest thread polls with Sleep(0) all race long; as sched_yield that is
    // a whole core burnt (97%, a third of it in the kernel) and one more CPU
    // for every mprotect TLB shootdown the command processor issues. 50 us of
    // real sleep per poll: 97% -> 9% of a core, process 317% -> 226%, fps
    // unchanged at a locked 60 in the same scene. Latency added per poll is
    // ~60 us against a 16.7 ms frame. 0 restores the yield.
    PonerSiNadieLoPidio("guest_sleep0_us", "50");

    // Fps counter for the F3 overlay, see below. Returns whatever the
    // watchdog last measured; it doesn't measure here, so opening the
    // overlay doesn't change the number being read.
    SetGuestFrameStats([this] { return stats_; });

#if REX_PLATFORM_SWITCH
    // The Switch screen is a text console while nothing renders: show that the
    // game is alive (guest frames, memory) above the log.
    static_cast<rex::ui::SwitchWindowedAppContext&>(app_context())
        .SetStatusProvider([this] { return LineaDeEstadoSwitch(); });
#endif

    // Hang watchdog, see below.
    ArrancarVigilante();
  }

  // ==========================================================================
  //  2b. PARCHE BLACK EDITION (NATIVO)
  //
  //  En la edicion PAL (454107D9) hay una bandera en 0x82A2CE04 que decide si
  //  vender los coches de pago (edicion Black) como descargables o no. Xenia
  //  la activaba con  data_write(be32, 0x82a2ce04, 0x00000100); aqui se pisa
  //  directamente la memoria del guest.
  //
  //  La memoria del guest es big-endian y el juego lee esa palabra byte a
  //  byte: be32 0x00000100 son los bytes 00 00 01 00, o sea un 1 en
  //  0x82A2CE06. Se escriben los cuatro bytes tal cual, NUNCA un uint32 del
  //  host: en little-endian eso ponia el 1 en 0x82A2CE05, otra bandera que
  //  lee el cargador de ficheros, y toda partida nueva moria en su tabla de
  //  peticiones (lectura del guest 0x8 en el hilo 7, PC y Switch).
  //
  //  Se puede apagar desde el menu (Contenido > Black Edition), pero solo se
  //  aplica en la carga siguiente: esta funcion corre cada vez que se carga
  //  el XEX, sea al arrancar o al releer la imagen.
  // ==========================================================================
  void OnPostLoadXexImage() override { AplicarParcheBlackEdition(); }

  // ==========================================================================
  //  2c. SETTINGS MENU ON ESC
  //
  //  Just like F3 (debugging) and F4 (technical settings), a key is
  //  registered and the dialog is created and destroyed with it (the SDK's
  //  ImGui dialogs register themselves in the drawer when constructed and
  //  delete themselves when closed; all we have to do is keep the pointer
  //  and null it out from on_closed).
  //
  //  The key ended up bound to Escape. It can be rebound from F4 (the
  //  "Keybinds" section).
  //
  //  This hook also creates the --perf_overlay HUD, see section 6 below:
  //  OnCreateDialogs is called once, so both live here.
  // ==========================================================================
  void OnCreateDialogs(rex::ui::ImGuiDrawer* drawer) override {
    rex::ui::RegisterBind("bind_nfsmw_menu", "Escape",
                          "Abrir/cerrar menu de ajustes del juego",
                          [this] { AlternarMenu(); });

    if (REXCVAR_GET(perf_overlay)) {
      // Dialogs retain themselves; this one lives until shutdown.
      new HudRendimiento(drawer, this);
    }
  }

  void OnShutdown() override {
    PararVigilante();
    rex::ui::UnregisterBind("bind_nfsmw_menu");
    if (menu_ != nullptr) {
      menu_->RequestClose();
      menu_ = nullptr;
    }
  }

  // ==========================================================================
  //  PERFORMANCE OVERLAY (--perf_overlay)
  //
  //  A passive HUD in the top-left corner, MangoHud style. The numbers are
  //  the watchdog's: it already measures guest fps once per second, and now
  //  also process CPU and RSS in the same tick. The dialog only READS them.
  //
  //  It repaints continuously like any other dialog (the F3 overlay path,
  //  proven for years). An attempt to repaint only per guest frame froze
  //  the game: with no continuous pump, the guest-refresh paint request
  //  runs on the GPU thread under paint_mode_mutex_ and deadlocks against
  //  the UI thread. The pump is also self-throttled by the presenter's UI
  //  tick, so the cost is bounded anyway.
  //
  //  Side effect worth knowing: with any dialog registered the presenter
  //  paints from the UI thread instead of inline on the GPU command
  //  processor thread. That path is fine (it's the same one every overlay
  //  uses), it's just a different code path than overlay-off.
  // ==========================================================================
  class HudRendimiento : public rex::ui::ImGuiDialog {
   public:
    HudRendimiento(rex::ui::ImGuiDrawer* drawer, NfsmwApp* app)
        : rex::ui::ImGuiDialog(drawer), app_(app) {}

   protected:
    void OnDraw(ImGuiIO& io) override {
      (void)io;
      ImGui::SetNextWindowPos(ImVec2(8.0f, 8.0f), ImGuiCond_Always);
      ImGui::SetNextWindowBgAlpha(0.45f);
      ImGui::Begin("##perf_overlay", nullptr,
                   ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_AlwaysAutoResize |
                       ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoFocusOnAppearing |
                       ImGuiWindowFlags_NoNav | ImGuiWindowFlags_NoInputs |
                       ImGuiWindowFlags_NoMove);
      const float fps = app_->hud_fps_.load(std::memory_order_relaxed);
      const float ms = app_->hud_ms_.load(std::memory_order_relaxed);
      const float cpu = app_->hud_cpu_pct_.load(std::memory_order_relaxed);
      const float ram = app_->hud_ram_mb_.load(std::memory_order_relaxed);
      ImGui::TextColored(ImVec4(0.4f, 1.0f, 0.4f, 1.0f), "FPS %5.1f", fps);
      ImGui::Text("Frame %5.1f ms", ms);
      ImGui::Text("CPU   %5.0f %%", cpu);
      ImGui::Text("RAM   %5.0f MB", ram);
      ImGui::End();
    }

   private:
    NfsmwApp* app_;
  };

 private:
  static void PonerSiNadieLoPidio(const char* nombre, const char* valor) {
    if (rex::cvar::GetFlagInfo(nombre) == nullptr) {
      REXLOG_DEBUG("Ajuste '{}' no registrado todavia; no lo toco.", nombre);
      return;
    }
    if (rex::cvar::HasNonDefaultValue(nombre)) {
      return;  // the user set it: don't second-guess them.
    }
    if (rex::cvar::SetFlagByName(nombre, valor)) {
      REXLOG_DEBUG("Ajuste por defecto de la build portable: {} = {}", nombre, valor);
    }
  }

  // ==========================================================================
  //  3. FPS COUNTER FOR THE F3 OVERLAY
  //
  //  In a RELEASE build, F3 opens an empty box that just says "Debug". These
  //  are two separate things and both were closed off:
  //
  //    1. Almost the entire panel lives inside #ifdef REXGLUE_ENABLE_PERF_COUNTERS,
  //       and the SDK's CMakeLists says
  //         add_compile_definitions($<$<NOT:$<CONFIG:Release>>:REXGLUE_ENABLE_PERF_COUNTERS>)
  //       meaning the define doesn't apply in Release. That's intentional:
  //       "compiled out in Release", its comment says.
  //
  //    2. The "Guest: X FPS" line is NOT inside that #ifdef. It only requires
  //       someone to register a provider with SetGuestFrameStats, and nothing
  //       in the SDK calls it: it's an API the app has to use.
  //
  //  (2) is the door that CAN be opened without touching the SDK.
  //
  //  WHERE THE NUMBER COMES FROM, AND WHY NOT FROM A CLOCK HERE.
  //  The first version checked the clock every time something asked and took
  //  the gap between two asks as if it were one frame. With the overlay
  //  closed -every automated run- the only one asking was the watchdog, once
  //  a second: dt came out to ~1000 ms, the filter threw it out, and the log
  //  wrote 0.0 fps forever. It wasn't slowness, it was the meter.
  //
  //  The next attempt -an ImGui dialog counting in its OnDraw- did give a
  //  number, but the WRONG one: it counted UI repaints, which run free and
  //  reach 1770 per second while the game does 17-30.
  //
  //  A game frame only exists in one place: when the presenter accepts a new
  //  image from the guest. That's what the SDK's counter -LOCAL PATCH in
  //  ui/presenter.h- counts, and what's read here. It's computed as a diff
  //  over the watchdog's one-second tick, so no per-frame hook or moving
  //  average is needed: the interval is real.
  // ==========================================================================
  rex::ui::FrameStats MideFotogramas(double dt_s) {
    const auto* presentador =
        runtime() && runtime()->graphics_system() ? runtime()->graphics_system()->presenter() : nullptr;
    if (!presentador || dt_s <= 0.0) {
      return stats_;
    }
    const uint64_t ahora = presentador->guest_frames_refreshed();
    const uint64_t nuevos = ahora - fotogramas_previos_;
    fotogramas_previos_ = ahora;

    stats_.fps = double(nuevos) / dt_s;
    stats_.frame_time_ms = stats_.fps > 0.0 ? 1000.0 / stats_.fps : 0.0;
    stats_.frame_count = ahora;  // the overlay doesn't draw if this is 0
    return stats_;
  }

  // ==========================================================================
  //  4. HANG WATCHDOG
  //
  //  THE PROBLEM IT SOLVES
  //  On returning to the menu the game freezes, and absolutely nothing
  //  appears in the log: no error, no kernel call, no graphics command.
  //  Total silence until you close the window. That rules out an exception
  //  or an unregistered function -those are visible- and leaves only one
  //  explanation: ALL of the game's threads are stopped at once, waiting for
  //  something that never arrives.
  //
  //  And you can't get out of a deadlock by looking at the log, because the
  //  very thing that defines it is that nothing gets written anymore. You
  //  have to go ask the threads directly.
  //
  //  HOW IT WORKS, AND WHY IT NEEDS NO COOPERATION FROM ANYONE
  //  A separate thread checks ALL of the guest's threads once a second and
  //  records two registers from each:
  //
  //    lr  where the function it's in would return to. Changes constantly
  //        in code that's progressing.
  //    r1  the stack pointer. Same idea.
  //
  //  If for several seconds in a row NO thread has moved either one, the
  //  game isn't slow: it's stopped. Then the table gets dumped.
  //
  //  The nice thing about measuring it this way is that it depends on
  //  nothing else: not the frame counter -which only runs with the overlay
  //  open-, not the game calling the kernel, not the graphics thread staying
  //  alive. If everything stops, it shows up precisely because everything
  //  stops.
  //
  //  WHAT THE DUMP GIVES YOU
  //  For each thread: its entry address -which says WHICH thread it is-, lr,
  //  r1, and r13. That distinguishes the one that's waiting -lr stuck in a
  //  kernel wait function- from the one that's spinning -lr bouncing between
  //  two or three addresses-. And since it dumps every 15 seconds for as
  //  long as it lasts, you can see if something is moving very slowly or not
  //  moving at all.
  //
  //  COST WHEN NOTHING IS HAPPENING
  //  One pass per second reading two integers per thread. Nothing.
  //
  //  It lives in the app and not the SDK on purpose: that way it can be
  //  changed without recompiling the whole SDK, and it doesn't force a
  //  watchdog thread on anyone else.
  // ==========================================================================

  void ArrancarVigilante() {
    vigilante_activo_ = true;
    vigilante_ = std::thread([this] { VigilanteMain(); });
  }

  void PararVigilante() {
    vigilante_activo_ = false;
    if (vigilante_.joinable()) {
      vigilante_.join();
    }
  }

  // Dump of the thread table. 'grave' decides whether it comes out as error
  // -when it's a real alarm- or as debug -routine snapshots-.
  template <typename Lista>
  static void VolcarHilos(const Lista& hilos, bool grave) {
    for (auto& h : hilos) {
      const auto* cp = h->creation_params();
      auto* estado = h->thread_state();
      if (estado && estado->context()) {
        const auto& c = *estado->context();
        if (grave) {
          REXLOG_ERROR("[vigilante]   hilo id=0x{:X} entrada=0x{:08X} principal={} corriendo={} | "
                       "lr=0x{:08X} r1=0x{:08X} r13=0x{:08X} r3=0x{:08X} ctr=0x{:08X} "
                       "ultimo_indirecto=0x{:08X}",
                       h->thread_id(), cp->start_address, h->main_thread(), h->is_running(),
                       static_cast<uint32_t>(c.lr), c.r1.u32, c.r13.u32, c.r3.u32, c.ctr.u32,
                       c.last_indirect_target);
        } else {
          REXLOG_DEBUG("[vigilante]   hilo id=0x{:X} entrada=0x{:08X} principal={} corriendo={} | "
                       "lr=0x{:08X} r1=0x{:08X} r13=0x{:08X} r3=0x{:08X} ctr=0x{:08X} "
                       "ultimo_indirecto=0x{:08X}",
                       h->thread_id(), cp->start_address, h->main_thread(), h->is_running(),
                       static_cast<uint32_t>(c.lr), c.r1.u32, c.r13.u32, c.r3.u32, c.ctr.u32,
                       c.last_indirect_target);
        }
      } else {
        REXLOG_DEBUG("[vigilante]   hilo id=0x{:X} entrada=0x{:08X} sin contexto", h->thread_id(),
                     cp->start_address);
      }
    }
  }

  // ==========================================================================
  //  GAME CODE PROFILER
  //
  //  THE PROBLEM. The game runs at 15 fps -66 ms per frame- with the main
  //  thread at 90% of one core and fifteen cores doing nothing. Meaning the
  //  bottleneck is a single thread executing game code. What's missing is
  //  WHICH code, and no external tool can tell you: perf isn't installed,
  //  ptrace_scope=1 stops a sibling profiler from attaching, and Tracy
  //  requires recompiling all 272 files of the recompilation plus a separate
  //  viewer.
  //
  //  HOW IT'S MEASURED WITHOUT ANY OF THAT. The generated code writes
  //  ctx.lr = <return site> right before EVERY call. So lr, read frequently,
  //  is a call-granularity program counter: it tells you where in the game
  //  the thread is. And each thread's context is already accessible from
  //  here; the watchdog below has been reading it from the start.
  //
  //  A thousand samples per second cost reading one integer a thousand
  //  times: nothing measurable.
  //
  //  WHAT IT ISN'T. The addresses come out at call-site resolution, not
  //  instruction resolution, and reading lr while the other thread runs is
  //  a benign race -aligned 8-byte read on x86-64-. That's plenty for
  //  deciding WHERE to look; not enough for micro-optimizing one specific
  //  function.
  //
  //  HOW TO READ THE DUMP. Each address is looked up as-is in
  //  generated/default/: it shows up as "// bl 0x8...." at the call site,
  //  inside the sub_XXXXXXXX function that's eating the time.
  // ==========================================================================
  void MuestreaLr() {
    auto* kernel = rex::system::kernel_state();
    if (!kernel) return;
    if (!principal_) {
      for (auto& h : kernel->object_table()->GetObjectsByType<rex::system::XThread>()) {
        if (h->main_thread()) {
          principal_ = h;
          break;
        }
      }
      if (!principal_) return;
    }
    auto* estado = principal_->thread_state();
    if (!estado || !estado->context()) return;
    const auto& c = *estado->context();
    const uint32_t lr = static_cast<uint32_t>(c.lr);
    const uint32_t r1 = c.r1.u32;
    ++muestras_;
    ++perfil_[lr];

    // PERFIL_TODOS=1: samples ALL of the game's threads, not just the main
    // one. Needed when the one doing the work isn't the main thread -during
    // cutscenes the main thread is blocked and another thread decodes-.
    if (todos_los_hilos_) {
      for (auto& h : kernel->object_table()->GetObjectsByType<rex::system::XThread>()) {
        auto* e2 = h->thread_state();
        if (!e2 || !e2->context()) continue;
        const auto& c2 = *e2->context();
        const uint64_t huella = uint64_t(uint32_t(c2.lr)) | (uint64_t(c2.r1.u32) << 32);
        auto& anterior = huella_por_hilo_[h->thread_id()];
        // Only counts if the thread HAS MOVED since the previous sample.
        // Without this filter the histogram gets dominated by threads
        // asleep in their wait function, which are the majority and use
        // nothing.
        if (anterior != huella) {
          anterior = huella;
          ++perfil_otros_[static_cast<uint32_t>(c2.lr)];
          ++muestras_otros_;
        }
      }
    }

    // STUCK OR WORKING: the question that decides everything. A forty
    // instruction function with no loops can't eat 45 ms per frame just by
    // executing; either it's called millions of times, or the thread is
    // STUCK there. If lr AND the stack pointer repeat their value from one
    // sample to the next, it hasn't moved: it's waiting, not computing.
    if (lr == lr_anterior_ && r1 == r1_anterior_) {
      ++repetidas_;
    }
    lr_anterior_ = lr;
    r1_anterior_ = r1;
  }

  void VuelcaPerfil() {
    if (muestras_ < 100) return;
    std::vector<std::pair<uint32_t, uint64_t>> orden(perfil_.begin(), perfil_.end());
    std::partial_sort(orden.begin(), orden.begin() + std::min<size_t>(15, orden.size()),
                      orden.end(),
                      [](const auto& a, const auto& b) { return a.second > b.second; });
    REXLOG_INFO("[perfil] {} muestras del hilo principal, {} sitios distintos, "
                "{:.1f}% sin moverse respecto a la anterior (lr y r1 iguales). "
                "Los que mas salen:",
                muestras_, perfil_.size(), 100.0 * double(repetidas_) / double(muestras_));
    for (size_t i = 0; i < std::min<size_t>(15, orden.size()); ++i) {
      REXLOG_INFO("[perfil]   {:5.1f}%  lr=0x{:08X}  ({} muestras)",
                  100.0 * double(orden[i].second) / double(muestras_), orden[i].first,
                  orden[i].second);
    }
    if (todos_los_hilos_ && muestras_otros_ > 100) {
      std::vector<std::pair<uint32_t, uint64_t>> o2(perfil_otros_.begin(), perfil_otros_.end());
      const size_t n2 = std::min<size_t>(8, o2.size());
      std::partial_sort(o2.begin(), o2.begin() + n2, o2.end(),
                        [](const auto& a, const auto& b) { return a.second > b.second; });
      REXLOG_INFO("[perfil] TODOS los hilos: {} muestras, {} sitios", muestras_otros_,
                  perfil_otros_.size());
      for (size_t i = 0; i < n2; ++i) {
        REXLOG_INFO("[perfil]   {:5.1f}%  lr=0x{:08X}",
                    100.0 * double(o2[i].second) / double(muestras_otros_), o2[i].first);
      }
      perfil_otros_.clear();
      muestras_otros_ = 0;
    }
    perfil_.clear();
    muestras_ = 0;
    repetidas_ = 0;
  }


  void VigilanteMain() {
    using Reloj = std::chrono::steady_clock;

    // How many seconds in a row with NOTHING moving before raising the
    // alarm. Five is generous: this game at 10 fps still moves registers a
    // hundred times a second, so five quiet seconds isn't slowness.
    constexpr int kSegundosParaSospechar = 5;
    constexpr int kSegundosEntreVolcados = 15;

    uint64_t firma_anterior = 0;
    int quietos = 0;
    int desde_ultimo_volcado = 0;
    int desde_instantanea = 0;
    bool avisado = false;
    auto tic_anterior = Reloj::now();

    while (vigilante_activo_) {
      // The one-second wait is spent sampling, not sleeping all at once.
      // See MuestreaLr: a thousand samples per second of the main thread.
      for (int ms = 0; ms < 1000 && vigilante_activo_; ++ms) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
        MuestreaLr();
      }
      if (!vigilante_activo_) break;

      // The "second" above is a thousand sleep(1) calls PLUS the sampling
      // cost: measured, ~1.06 s. Assuming 1.0 inflated every fps figure by
      // ~6% — menus read a flat "63" when they actually ran at 60. Measure
      // the real interval instead.
      const auto ahora = Reloj::now();
      const double dt_s = std::chrono::duration<double>(ahora - tic_anterior).count();
      tic_anterior = ahora;

      if (++desde_perfil_ >= kSegundosEntrePerfiles) {
        desde_perfil_ = 0;
        VuelcaPerfil();
      }

      // LOCAL PATCH - fps counter in the log, without opening F3.
      //
      // This loop's tick is one second and is itself the measurement
      // interval: new game frames divided by the time that's actually
      // passed. Printed every five ticks.
      const auto s = MideFotogramas(dt_s);
      if (++desde_log_fps_ >= 5) {
        desde_log_fps_ = 0;
        REXLOG_INFO("[fps] {:5.1f} ({:5.1f} ms, {} fotogramas)", s.fps, s.frame_time_ms,
                    s.frame_count);
      }

      // PERF OVERLAY - same tick feeds the HUD. CPU is the whole process as
      // top shows it (200% = two cores); RAM is resident set.
      hud_fps_.store(float(s.fps), std::memory_order_relaxed);
      hud_ms_.store(float(s.frame_time_ms), std::memory_order_relaxed);
#ifdef __linux__
      {
        if (FILE* f = std::fopen("/proc/self/stat", "r")) {
          long utime = 0, stime = 0;
          // Everything up to the closing paren of comm, then fields 3..15.
          if (std::fscanf(f,
                          "%*d (%*[^)]) %*c %*d %*d %*d %*d %*d %*u %*u %*u %*u %*u %ld %ld",
                          &utime, &stime) == 2) {
            const double total = double(utime + stime) / double(sysconf(_SC_CLK_TCK));
            if (hud_cpu_previa_ > 0.0 && dt_s > 0.0) {
              hud_cpu_pct_.store(float(100.0 * (total - hud_cpu_previa_) / dt_s),
                                 std::memory_order_relaxed);
            }
            hud_cpu_previa_ = total;
          }
          std::fclose(f);
        }
        if (FILE* f = std::fopen("/proc/self/statm", "r")) {
          long paginas_total = 0, paginas_rss = 0;
          if (std::fscanf(f, "%ld %ld", &paginas_total, &paginas_rss) == 2) {
            hud_ram_mb_.store(float(double(paginas_rss) * double(sysconf(_SC_PAGESIZE)) /
                                    (1024.0 * 1024.0)),
                              std::memory_order_relaxed);
          }
          std::fclose(f);
        }
      }
#endif
#if REX_PLATFORM_SWITCH
      {
        // libnx hands malloc the whole heap at startup, so the kernel's "used"
        // figure is always the total; malloc's own count (guest memory
        // included, it is carved from the heap) is the real one.
        const struct mallinfo mi = mallinfo();
        hud_ram_mb_.store(float(double(mi.uordblks) / (1024.0 * 1024.0)),
                          std::memory_order_relaxed);
      }
#endif

      auto* kernel = rex::system::kernel_state();
      if (!kernel) continue;

      auto hilos = kernel->object_table()->GetObjectsByType<rex::system::XThread>();
      if (hilos.empty()) continue;

      // A signature for "where everything is at". It doesn't need to be a
      // good hash: it just needs to change if any register changes.
      //
      // WATCH THE ORDER. The first version of this multiplied and mixed on
      // the fly, walking the list as it came. And GetObjectsByType does NOT
      // guarantee order: in real dumps the threads came out shuffled from
      // one pass to the next, and even duplicated -0x6 showed up twice-. So
      // the signature changed on its own even when nothing had moved, and
      // the alarm NEVER fired on the real hang. The only thing that helped
      // at all were the periodic snapshots below.
      //
      // Fixed by putting each thread into a map keyed by its id: the map
      // sorts on its own, so the shuffling stops mattering, and a repeated
      // id gets overwritten instead of counted twice. Only then does it get
      // mixed.
      std::map<uint32_t, uint64_t> por_hilo;
      for (auto& h : hilos) {
        auto* estado = h->thread_state();
        if (!estado || !estado->context()) continue;
        const auto& c = *estado->context();
        por_hilo[h->thread_id()] =
            static_cast<uint64_t>(c.lr) ^ (static_cast<uint64_t>(c.r1.u32) << 20) ^
            (static_cast<uint64_t>(c.r3.u32) << 40);
      }

      uint64_t firma = 1469598103934665603ull;
      for (const auto& [id_hilo, huella] : por_hilo) {
        firma = (firma ^ id_hilo) * 1099511628211ull;
        firma = (firma ^ huella) * 1099511628211ull;
      }

      // PERIODIC SNAPSHOT, NO MATTER WHAT.
      //
      // The alarm above only fires if NOTHING moves, and it turns out the
      // hang we're chasing isn't of that kind: the registers kept changing,
      // meaning the game executes code but doesn't progress. A tight loop
      // waiting for something that never arrives looks just as stopped from
      // the outside, yet the alarm doesn't catch it.
      //
      // That's what this is for: every ten seconds it records where each
      // thread is, problem or not. When the game freezes, two or three
      // snapshots of the bad stretch remain, and if lr is bouncing between
      // the same two or three addresses, there's the loop.
      //
      // Logged at debug level -doesn't get in the way during normal use- and
      // it's a handful of lines every ten seconds.
      if (++desde_instantanea >= 10) {
        desde_instantanea = 0;
        REXLOG_DEBUG("[vigilante] instantanea: {} hilos del juego", hilos.size());
        VolcarHilos(hilos, false);
      }

      if (firma != firma_anterior) {
        if (avisado) {
          REXLOG_WARN("[vigilante] el juego ha vuelto a moverse despues de {} s parado.", quietos);
          avisado = false;
        }
        firma_anterior = firma;
        quietos = 0;
        desde_ultimo_volcado = 0;
        continue;
      }

      ++quietos;
      ++desde_ultimo_volcado;
      if (quietos < kSegundosParaSospechar) continue;
      if (avisado && desde_ultimo_volcado < kSegundosEntreVolcados) continue;
      desde_ultimo_volcado = 0;

      REXLOG_ERROR("[vigilante] {} s sin que se mueva ni un registro en ninguno de los {} hilos "
                   "del juego. Esto no es lentitud: esta parado.",
                   quietos, hilos.size());
      VolcarHilos(hilos, true);
      avisado = true;
    }
  }

  // ==========================================================================
  //  5. BLACK EDITION PATCH + THE SETTINGS MENU (ESC)
  // ==========================================================================

#if REX_PLATFORM_SWITCH
  // Top line of the Switch status screen. Read on the UI thread.
  std::string LineaDeEstadoSwitch() const {
    u64 total = 0;
    svcGetInfo(&total, InfoType_TotalMemorySize, CUR_PROCESS_HANDLE, 0);
    return fmt::format("NFSMW Recompiled (Switch, no renderer) | guest {:4.1f} fps | "
                       "frames {} | RAM {:.0f}/{} MB",
                       hud_fps_.load(std::memory_order_relaxed),
                       rex::graphics::null::NullGraphicsSystem::swap_count(),
                       hud_ram_mb_.load(std::memory_order_relaxed), total >> 20);
  }
#endif

  void AplicarParcheBlackEdition() {
    constexpr uint32_t kBlackEditionAddr = 0x82A2CE04u;  // edicion PAL (454107D9)
    auto* kernel = rex::system::kernel_state();
    if (kernel == nullptr || kernel->memory() == nullptr) {
      REXLOG_WARN("[black-edition] sin kernel de memoria; no se puede parchear.");
      return;
    }
    if (!REXCVAR_GET(black_edition)) {
      REXLOG_INFO("[black-edition] desactivado (black_edition=false).");
      return;
    }
    auto* bandera = kernel->memory()->TranslateVirtual<uint8_t*>(kBlackEditionAddr);
    if (bandera == nullptr) {
      REXLOG_WARN("[black-edition] no se pudo traducir 0x{:08X}; el contenido "
                  "Black Edition seguira oculto.", kBlackEditionAddr);
      return;
    }
    // be32 0x00000100, byte a byte: el juego lee esta palabra como cuatro
    // banderas de un byte (ver la cabecera de 2b).
    static constexpr uint8_t kBe32Cien[4] = {0x00, 0x00, 0x01, 0x00};
    std::memcpy(bandera, kBe32Cien, sizeof(kBe32Cien));
    REXLOG_INFO("[black-edition] bandera 0x{:08X} = be32 0x00000100 (contenido desbloqueado).",
                kBlackEditionAddr);
  }

  void AlternarMenu() {
    if (menu_ == nullptr) {
      auto* drawer = imgui_drawer();
      if (drawer == nullptr) {
        return;  // pulsacion prematura: todavia no hay UI
      }
      menu_ = new NfsmwMenuDialog(drawer, NfsmwMenuDialog::Callbacks{
          [this] { GuardarConfigDetras(); },
          [this] { RelanzarJuego(); },
          [this] {
            if (window() != nullptr) {
              window()->RequestClose();
            }
          },
          [this] { menu_ = nullptr; },
          // Upstream sampled the frame time here, once per overlay draw. We
          // publish stats_ from the watchdog thread instead, off a measured
          // interval, so the menu just reads the last value.
          [this] { return stats_; },
      });
    } else {
      menu_->RequestClose();  // el dialogo se cierra y se borra solo
    }
  }

  void GuardarConfigDetras() {
    auto carpeta = rex::filesystem::GetExecutableFolder();
    if (carpeta.empty()) {
      carpeta = std::filesystem::current_path();
    }
    rex::cvar::SaveConfig(carpeta / "nfsmw.toml");
  }

  void RelanzarJuego() {
    GuardarConfigDetras();
#if defined(_WIN32)
    const auto exe = rex::filesystem::GetExecutablePath();
    if (!exe.empty()) {
      const std::wstring ruta = exe.wstring();
      const std::wstring carpeta = exe.parent_path().wstring();
      const INT_PTR resultado = reinterpret_cast<INT_PTR>(ShellExecuteW(
          nullptr, L"open", ruta.c_str(), nullptr, carpeta.c_str(), SW_SHOWNORMAL));
      if (resultado > 32) {
        // El proceso nuevo arranca con el toml recien guardado; este se cierra.
        if (window() != nullptr) {
          window()->RequestClose();
        }
        return;
      }
      REXLOG_ERROR("[menu] no se pudo relanzar el juego (ShellExecuteW = {}); sigue con "
                   "lo aplicado y reinicia a mano.", int32_t(resultado));
    } else {
      REXLOG_ERROR("[menu] sin ruta del ejecutable; reinicia el juego a mano.");
    }
#else
    REXLOG_WARN("[menu] reinicia el juego a mano para aplicar los cambios.");
#endif
  }

  // Only touched by the watchdog thread, which is the only one measuring.
  rex::ui::FrameStats stats_{};

  // PERF OVERLAY - written by the watchdog tick, read by HudRendimiento on
  // the UI thread.
  std::atomic<float> hud_fps_{0.0f};
  std::atomic<float> hud_ms_{0.0f};
  std::atomic<float> hud_cpu_pct_{0.0f};
  std::atomic<float> hud_ram_mb_{0.0f};
  double hud_cpu_previa_ = 0.0;  // watchdog thread only
  uint64_t fotogramas_previos_ = 0;
  int desde_log_fps_ = 0;

  // Profiler, also only touched by the watchdog thread.
  static constexpr int kSegundosEntrePerfiles = 20;
  rex::system::object_ref<rex::system::XThread> principal_;
  std::map<uint32_t, uint64_t> perfil_;
  const bool todos_los_hilos_ = std::getenv("PERFIL_TODOS") != nullptr;
  std::map<uint32_t, uint64_t> perfil_otros_;
  uint64_t muestras_otros_ = 0;
  std::map<uint32_t, uint64_t> huella_por_hilo_;
  uint64_t muestras_ = 0;
  uint64_t repetidas_ = 0;
  uint32_t lr_anterior_ = 0;
  uint32_t r1_anterior_ = 0;
  uint64_t fotogramas_perfil_ = 0;
  int desde_perfil_ = 0;

  std::thread vigilante_;
  std::atomic<bool> vigilante_activo_{false};

  NfsmwMenuDialog* menu_ = nullptr;  // los dialogos ImGui se borran solos al cerrarse
};
