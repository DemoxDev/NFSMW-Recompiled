#!/usr/bin/env python3
"""
Limita el ritmo de pintado de la UI fuera de Windows.

    python tools/parche_ui_ticks.py            aplicar
    python tools/parche_ui_ticks.py --estado
    python tools/parche_ui_ticks.py --revertir

Touches one SDK file:  src/ui/presenter.cpp

It does not keep a .original: presenter.cpp ALREADY carries parche_fotogramas,
and saving a ".original" now would save the already-patched file as if it were
clean - a --revertir would take the other patch down with it. Applies and
undoes by exact text substitution, block by block.


WHY THIS WAS NEEDED
=======================

Windows limita el ritmo de pintado de la UI al vblank del monitor, en
Presenter::WaitForUITickFromUIThread, con senales de DXGI. Fuera de Windows
esa funcion es un no-op (todo el cuerpo esta bajo #if REX_PLATFORM_WIN32), y
nadie limita nada.

Eso solo es un problema porque hay algo que pide repintados sin parar:
ImGuiDrawer::Draw llama a RequestUIPaintFromUIThread en cada fotograma
mientras haya cualquier dialogo registrado, y ReXApp::LaunchModule registra
siempre el toast de logros -aunque no haya logros que mostrar-. Resultado
medido en un M1, con el juego en el modo demostracion:

  - ~200 pintados de UI por segundo, 4.8 ms cada uno: el hilo de UI al 100%.
  - El refresh del guest (RefreshGuestOutput, el swap del juego) esperaba
    30-43 ms por fotograma.
  - El juego a ~15 fps con la GPU al 60-70% -no estaba limitado por la GPU,
    estaba limitado por la presentacion-.

Con el limite puesto a 60 Hz: refresh 7-14 ms, juego ~24 fps. Es decir, el
trabajo de pintado de la UI no es gratis: se come el hilo que presenta los
fotogramas del guest.

QUE HACE ESTE PARCHE
=====================

Implementa la rama no-Windows de WaitForUITickFromUIThread con un limite por
reloj (std::chrono) al ritmo del modo de video del guest -video_mode_refresh_rate,
60 Hz por defecto, el mismo valor que usa el hilo del vblank- y la rama
no-Windows de ForceUIThreadPaintTick.

El present del guest no espera: su peticion de pintado llama a
ForceUIThreadPaintTick, que pone un aviso; la espera lo consulta cada
milisegundo mientras duerme, asi que un fotograma del guest entra como mucho
1 ms tarde. Es el mismo contrato que en Windows, donde el vblank interrumpe
la espera.

Nota: el limite es por reloj y no por vblank real porque el SDK no tiene
fuente de vblank fuera de DXGI; 60 Hz es ademas el ritmo al que el juego
genera fotogramas.
"""

import argparse
import pathlib
import sys

# ---------------------------------------------------------------------------
#  1) Headers
# ---------------------------------------------------------------------------

CAB_ANCLA = """#include <algorithm>
#include <atomic>
#include <cctype>
#include <utility>
"""

CAB_NUEVO = """#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>  // PARCHE LOCAL - limite de ritmo de la UI fuera de Windows
#include <thread>  // PARCHE LOCAL - limite de ritmo de la UI fuera de Windows
#include <utility>
"""

# ---------------------------------------------------------------------------
#  2) The state of the limiter, before the function that uses it
# ---------------------------------------------------------------------------

ESTADO_ANCLA = """void Presenter::WaitForUITickFromUIThread() {
"""

ESTADO_NUEVO = """// PARCHE LOCAL - limite de ritmo de la UI fuera de Windows
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
"""

# ---------------------------------------------------------------------------
#  3) The wait and the immediate-tick request, both with a non-Windows branch
# ---------------------------------------------------------------------------

ESPERA_ANCLA = """    dxgi_ui_tick_signal_condition_.wait(dxgi_ui_tick_lock);
  }
#endif  // XE_PLATFORM
}

void Presenter::ForceUIThreadPaintTick() {
#if REX_PLATFORM_WIN32
  std::scoped_lock<std::mutex> dxgi_ui_tick_lock(dxgi_ui_tick_mutex_);
  dxgi_ui_tick_force_requested_ = true;
#endif  // XE_PLATFORM
}
"""

ESPERA_NUEVO = """    dxgi_ui_tick_signal_condition_.wait(dxgi_ui_tick_lock);
  }
#else
  // PARCHE LOCAL - limite de ritmo de la UI fuera de Windows
  //
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
}

void Presenter::ForceUIThreadPaintTick() {
#if REX_PLATFORM_WIN32
  std::scoped_lock<std::mutex> dxgi_ui_tick_lock(dxgi_ui_tick_mutex_);
  dxgi_ui_tick_force_requested_ = true;
#else
  // PARCHE LOCAL - limite de ritmo de la UI fuera de Windows
  g_ui_tick_force_requested.store(true, std::memory_order_release);
#endif  // XE_PLATFORM
}
"""

BLOQUES = [
    ("cabeceras", CAB_ANCLA, CAB_NUEVO),
    ("estado del limite", ESTADO_ANCLA, ESTADO_NUEVO),
    ("espera y peticion de tick", ESPERA_ANCLA, ESPERA_NUEVO),
]


def localizar_sdk():
    raiz = pathlib.Path(__file__).resolve().parent.parent
    for cand in [raiz.parent / "rexglue-sdk", raiz / "sdk"]:
        if (cand / "src" / "ui" / "presenter.cpp").exists():
            return cand
    sys.exit("[ERROR] No encuentro src/ui/presenter.cpp del SDK.\n"
             "        Se busca en ..\\rexglue-sdk y en .\\sdk")


def main():
    p = argparse.ArgumentParser(add_help=True)
    p.add_argument("--estado", action="store_true")
    p.add_argument("--revertir", action="store_true")
    args = p.parse_args()

    f = localizar_sdk() / "src" / "ui" / "presenter.cpp"
    txt = f.read_text(encoding="utf-8")

    if args.estado:
        puestos = sum(1 for _, _, nuevo in BLOQUES if nuevo in txt)
        print(f"  {f.name:26s} {puestos} de {len(BLOQUES)} bloques aplicados")
        for nombre, _, nuevo in BLOQUES:
            print(f"      {'si' if nuevo in txt else 'NO':>2}  {nombre}")
        return 0

    if args.revertir:
        quitados = 0
        for nombre, ancla, nuevo in BLOQUES:
            if nuevo not in txt:
                continue
            if txt.count(nuevo) != 1:
                sys.exit(f"[ERROR] El bloque '{nombre}' aparece {txt.count(nuevo)} veces.\n"
                         f"        No lo toco, quitalo tu.")
            txt = txt.replace(nuevo, ancla)
            quitados += 1
        if not quitados:
            print(f"[ok] {f.name}: no habia nada puesto")
            return 0
        f.write_text(txt, encoding="utf-8")
        print(f"[ok] Quitados {quitados} bloques de {f.name}")
        print()
        print("  HAY QUE RECOMPILAR EL SDK.")
        return 0

    faltan = [(n, a, v) for n, a, v in BLOQUES if v not in txt]
    if not faltan:
        print(f"[ok] {f.name}: los {len(BLOQUES)} bloques ya estaban")
        return 0

    for nombre, ancla, _ in faltan:
        n = txt.count(ancla)
        if n != 1:
            sys.exit(f"[ERROR] El anclaje de '{nombre}' aparece {n} veces, esperaba 1.\n"
                     f"        El SDK habra cambiado. No he tocado nada.")

    for nombre, ancla, nuevo in faltan:
        txt = txt.replace(ancla, nuevo)
        print(f"[ok] Aplicado: {nombre}")
    f.write_text(txt, encoding="utf-8")
    print()
    print("  La UI deja de pintar sin limite fuera de Windows; el present del")
    print("  guest salta el limite igual que con el vblank de DXGI.")
    print()
    print("  HAY QUE RECOMPILAR EL SDK para que sirva de algo:")
    print("    cmake --build out/build/mac-arm64 --config Release --target install")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
