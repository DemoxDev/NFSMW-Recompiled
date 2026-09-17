#!/usr/bin/env python3
"""
Makes VSYNC and the FPS LIMIT actually exist.

    python tools/parche_presentador.py            aplicar
    python tools/parche_presentador.py --estado
    python tools/parche_presentador.py --revertir

Touches a single SDK file:  src/ui/d3d12/d3d12_presenter.cpp
Saves a .original the first time and is idempotent.


WHY THIS WAS NEEDED
========================

VSYNC
-----
The "vsync" cvar exists, but it's NOT vsync. It's read in exactly one place
in the whole SDK, in command_processor.cpp, inside
ExecutePacketType3_WAIT_REG_MEM:

    if (!REXCVAR_GET(vsync)) {
      // User wants it fast and dangerous.
      rex::thread::MaybeYield();
    } else {
      rex::thread::Sleep(std::chrono::milliseconds(wait / 0x100));
    }

In other words: it decides whether the command processor SLEEPS when the
game's command stream asks it to wait, or whether it just keeps spinning.
That's a "run wild" switch, not a sync with the display.

The real synchronization lives in the D3D12 presenter, and it was hardcoded:

    swap_chain->Present(0, DXGI_PRESENT_RESTART | ...);

That first 0 is the SyncInterval. With 0, it presents as soon as it possibly
can, no matter what the cvar says. The SDK's comment explains why it was
chosen that way -the monitor may run at 144 Hz, which isn't a multiple of
the guest's 30 or 60-, but the effect is that the vsync checkbox did nothing
visible.

The patch passes SyncInterval 1 when vsync is enabled.

  DETAIL THAT MATTERS: with a SyncInterval other than 0, DXGI REJECTS the
  ALLOW_TEARING flag and returns DXGI_ERROR_INVALID_CALL. They're mutually
  exclusive. And DXGI_PRESENT_RESTART drops queued frames, which is exactly
  the opposite of what you want with vsync. That's why with vsync enabled
  neither flag is passed, and without vsync everything is left exactly as it
  was.

  The cvar is read by NAME, with rex::cvar::Query<bool>("vsync"), instead of
  REXCVAR_GET. That's deliberate: "vsync" is defined in the GPU plugin
  (rexgpu-xenos.dll) and the presenter lives in rexruntime.dll. Linking
  against a symbol from the plugin wouldn't work; the cvar registry, on the
  other hand, is shared, and looking it up by name goes right through it. It's
  checked first with GetFlagInfo in case the plugin isn't loaded.

FPS LIMIT
-------------
There wasn't one at all. All the headers and the symbols in the compiled
DLLs were searched: only "vsync" turns up. So a new cvar, max_fps, is added,
defined right here in the presenter.

  0 = no limit (the same behavior as before).

It sleeps until the next frame is due. It doesn't sleep the whole way: it
leaves the last stretch spinning, because Sleep on Windows has a granularity
of between 1 and 15 ms, and without that final spin the limit falls short
and gets choppy.
"""

import argparse
import pathlib
import shutil
import sys

MARCA = "PARCHE LOCAL - vsync real y limitador de fps"

# ---------------------------------------------------------------------------
#  The exact spot, copied verbatim from the SDK source.
# ---------------------------------------------------------------------------
ANCLA = """  HRESULT present_result = paint_context_.swap_chain->Present(
      0, DXGI_PRESENT_RESTART |
             (paint_context_.swap_chain_allows_tearing ? DXGI_PRESENT_ALLOW_TEARING : 0));
"""

NUEVO = """  // ------------------------------------------------------------------
  //  PARCHE LOCAL - vsync real y limitador de fps
  //
  //  Aqui antes habia un Present(0, ...) con el SyncInterval clavado a 0,
  //  asi que la sincronizacion con la pantalla no ocurria nunca por mucho
  //  que se activara el cvar "vsync" -que en realidad solo decide si el
  //  procesador de comandos duerme en las esperas del guest-.
  // ------------------------------------------------------------------

  // Limitador. max_fps = 0 deja el comportamiento original.
  {
    const int32_t tope = REXCVAR_GET(max_fps);
    if (tope > 0) {
      using Reloj = std::chrono::steady_clock;
      // Estatica de funcion: PaintAndPresentImpl corre siempre en el hilo de
      // pintado, asi que no hace falta sincronizar nada.
      static Reloj::time_point siguiente{};
      const auto periodo = std::chrono::duration_cast<Reloj::duration>(
          std::chrono::duration<double>(1.0 / double(tope)));
      const auto ahora = Reloj::now();
      if (siguiente > ahora) {
        // Dormir casi todo y rematar girando: Sleep tiene una granularidad
        // de 1 a 15 ms y sin el remate el limite se queda corto.
        const auto margen = std::chrono::milliseconds(2);
        if (siguiente - ahora > margen) {
          std::this_thread::sleep_for((siguiente - ahora) - margen);
        }
        while (Reloj::now() < siguiente) {
          std::this_thread::yield();
        }
      }
      siguiente = std::max(Reloj::now(), siguiente) + periodo;
    }
  }

  // Vsync. Se busca por nombre porque el cvar lo define el plugin de GPU, que
  // es otro DLL: enlazar contra su simbolo no funcionaria, pero el registro de
  // cvars es comun.
  bool con_vsync = false;
  if (rex::cvar::GetFlagInfo("vsync") != nullptr) {
    con_vsync = rex::cvar::Query<bool>("vsync");
  }

  UINT sync_interval = 0;
  UINT present_flags = 0;
  if (con_vsync) {
    sync_interval = 1;
    // Ni ALLOW_TEARING ni RESTART: la primera es incompatible con
    // SyncInterval != 0 (DXGI devuelve DXGI_ERROR_INVALID_CALL) y la segunda
    // descarta los fotogramas encolados, que es lo contrario de lo que se
    // busca al sincronizar.
  } else {
    present_flags = DXGI_PRESENT_RESTART |
                    (paint_context_.swap_chain_allows_tearing ? DXGI_PRESENT_ALLOW_TEARING : 0);
  }

  HRESULT present_result = paint_context_.swap_chain->Present(sync_interval, present_flags);
"""

# The new cvar and the headers the code above needs.
ANCLA_CVAR = """REXCVAR_DEFINE_BOOL(d3d12_allow_variable_refresh_rate_and_tearing, true, "UI/D3D12",
                    "Allow variable refresh rate and tearing");
"""

NUEVO_CVAR = """REXCVAR_DEFINE_BOOL(d3d12_allow_variable_refresh_rate_and_tearing, true, "UI/D3D12",
                    "Allow variable refresh rate and tearing");

// PARCHE LOCAL - vsync real y limitador de fps
// El SDK no traia ningun limitador: solo estaba "vsync", y ese ni siquiera
// tocaba el SyncInterval del Present. Este es nuevo.
REXCVAR_DEFINE_INT32(max_fps, 0, "UI/Present",
                     "Limite de fotogramas por segundo (0 = sin limite)")
    .range(0, 1000);
"""

ANCLA_INC = """#include <algorithm>
#include <climits>
#include <cmath>
#include <memory>
#include <utility>
"""

NUEVO_INC = """#include <algorithm>
#include <chrono>   // PARCHE LOCAL - limitador de fps
#include <climits>
#include <cmath>
#include <memory>
#include <thread>   // PARCHE LOCAL - limitador de fps
#include <utility>
"""


def localizar_sdk():
    raiz = pathlib.Path(__file__).resolve().parent.parent
    for cand in [raiz.parent / "rexglue-sdk", raiz / "sdk"]:
        f = cand / "src" / "ui" / "d3d12" / "d3d12_presenter.cpp"
        if f.exists():
            return f
    sys.exit("[ERROR] No encuentro src/ui/d3d12/d3d12_presenter.cpp del SDK.\n"
             "        Se busca en ..\\rexglue-sdk y en .\\sdk")


def main():
    p = argparse.ArgumentParser(add_help=True)
    p.add_argument("--estado", action="store_true")
    p.add_argument("--revertir", action="store_true")
    args = p.parse_args()

    f = localizar_sdk()
    original = f.with_suffix(".cpp.original")
    txt = f.read_text(encoding="utf-8")
    puesto = MARCA in txt

    if args.estado:
        print(f"  {f}")
        print("  Parche:", "APLICADO" if puesto else "sin aplicar")
        return 0

    if args.revertir:
        if original.exists():
            shutil.copy2(original, f)
            print("[ok] Restaurado desde .original")
        else:
            print("[aviso] No hay .original que restaurar.")
        return 0

    if puesto:
        print("[ok] Ya estaba aplicado. No toco nada.")
        return 0

    # Check all three anchors BEFORE writing anything. If the SDK changes
    # version and one of them doesn't match, better not leave the file half-done.
    for nombre, ancla in [("includes", ANCLA_INC),
                          ("definicion de cvars", ANCLA_CVAR),
                          ("llamada a Present", ANCLA)]:
        n = txt.count(ancla)
        if n != 1:
            sys.exit(f"[ERROR] El anclaje '{nombre}' aparece {n} veces, esperaba 1.\n"
                     f"        El SDK habra cambiado. No he tocado nada.")

    if not original.exists():
        shutil.copy2(f, original)
        print(f"[ok] Copia de seguridad: {original.name}")

    txt = txt.replace(ANCLA_INC, NUEVO_INC)
    txt = txt.replace(ANCLA_CVAR, NUEVO_CVAR)
    txt = txt.replace(ANCLA, NUEVO)
    f.write_text(txt, encoding="utf-8")

    print("[ok] Parche aplicado.")
    print()
    print("  vsync    ahora pasa SyncInterval 1 al Present")
    print("  max_fps  cvar nuevo, 0 = sin limite")
    print()
    print("  HAY QUE RECOMPILAR EL SDK para que sirva de algo:")
    print("    cmake --build out/build/win-amd64 --config Release --target install")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
