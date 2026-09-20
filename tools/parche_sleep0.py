#!/usr/bin/env python3
"""
Sueno real en los sondeos con Sleep(0) del guest (cvar guest_sleep0_us).

    python tools/parche_sleep0.py            aplicar
    python tools/parche_sleep0.py --estado
    python tools/parche_sleep0.py --revertir

Touches one SDK file:  src/system/xthread.cpp

It does not keep a .original: xthread.cpp ALREADY carries other patches of
this project, and a ".original" saved now would be the already-patched file.
Applies and undoes by exact text substitution, block by block.


WHY THIS WAS NEEDED
=======================

El hilo principal del juego sondea con Sleep(0) sin parar. En XThread::Delay,
un timeout de 0 con prioridad normal acaba en rex::thread::MaybeYield(), que
es sched_yield: el hilo se cede a si mismo y vuelve inmediatamente.

Medido en un M1 con el juego en el modo demostracion, instrumentando Delay
para el hilo principal:

    [sdk-delay] main sleeps/s=1542..2444 req_ms/s=0 act_ms/s=~1000

O sea: entre 1500 y 2450 sondeos por segundo que consumian ~1000 ms de cada
segundo -un nucleo entero- sin hacer nada. La app ya pide un sueno de 50 us
por sondeo (PonerSiNadieLoPidio("guest_sleep0_us", "50") en nfsmw_app.h),
pero ese cvar no existia en este SDK y el ajuste no hacia nada.

QUE HACE ESTE PARCHE
=======================

Anade el cvar guest_sleep0_us (microsegundos, 0 = comportamiento de antes) y
lo usa en XThread::Delay cuando el timeout del guest es 0. Con 50 us el coste
del sondeo baja de ~100% a ~9% de un nucleo; la latencia que anade por sondeo
es de decenas de microsegundos contra fotogramas de 16 ms.

El cvar solo sustituye al yield de las prioridades normales. El sueno de
100 us de las prioridades bajas se queda como estaba: esas ya dormian, y un
valor menor las haria sondear mas, no menos.
"""

import argparse
import pathlib
import sys

# ---------------------------------------------------------------------------
#  1) The cvar
# ---------------------------------------------------------------------------

CVAR_ANCLA = """REXCVAR_DEFINE_BOOL(ignore_thread_affinities, true, "Kernel",
                    "Ignores game-specified thread affinities");
"""

CVAR_NUEVO = """REXCVAR_DEFINE_BOOL(ignore_thread_affinities, true, "Kernel",
                    "Ignores game-specified thread affinities");

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
"""

# ---------------------------------------------------------------------------
#  2) The use, in Delay's zero-timeout branch
# ---------------------------------------------------------------------------

USO_ANCLA = """    if (timeout_ms == 0) {
      if (priority_ <= rex::thread::ThreadPriority::kBelowNormal) {
        rex::thread::Sleep(std::chrono::microseconds(100));
      } else {
        rex::thread::MaybeYield();
      }
    } else {
"""

USO_NUEVO = """    if (timeout_ms == 0) {
      // PARCHE LOCAL - sueno real en los sondeos con Sleep(0)
      const int32_t sleep0_us = REXCVAR_GET(guest_sleep0_us);
      if (priority_ <= rex::thread::ThreadPriority::kBelowNormal) {
        rex::thread::Sleep(std::chrono::microseconds(100));
      } else if (sleep0_us > 0) {
        rex::thread::Sleep(std::chrono::microseconds(sleep0_us));
      } else {
        rex::thread::MaybeYield();
      }
    } else {
"""

BLOQUES = [
    ("el cvar", CVAR_ANCLA, CVAR_NUEVO),
    ("el uso en Delay", USO_ANCLA, USO_NUEVO),
]


def localizar_sdk():
    raiz = pathlib.Path(__file__).resolve().parent.parent
    for cand in [raiz.parent / "rexglue-sdk", raiz / "sdk"]:
        if (cand / "src" / "system" / "xthread.cpp").exists():
            return cand
    sys.exit("[ERROR] No encuentro src/system/xthread.cpp del SDK.\n"
             "        Se busca en ..\\rexglue-sdk y en .\\sdk")


def main():
    p = argparse.ArgumentParser(add_help=True)
    p.add_argument("--estado", action="store_true")
    p.add_argument("--revertir", action="store_true")
    args = p.parse_args()

    f = localizar_sdk() / "src" / "system" / "xthread.cpp"
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
    print("  Ajuste nuevo en F4, categoria Kernel:  guest_sleep0_us")
    print("  (0 = yield; la app pide 50 us en nfsmw_app.h)")
    print()
    print("  HAY QUE RECOMPILAR EL SDK para que sirva de algo:")
    print("    cmake --build out/build/mac-arm64 --config Release --target install")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
