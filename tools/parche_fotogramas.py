#!/usr/bin/env python3
"""
Publica el contador de fotogramas del guest que la app medía y el SDK puro
no tiene.

    python tools/parche_fotogramas.py            aplicar
    python tools/parche_fotogramas.py --estado
    python tools/parche_fotogramas.py --revertir

Touches two SDK files:  include/rex/ui/presenter.h  src/ui/presenter.cpp
Saves .original backups the first time and is idempotent.


WHY THIS WAS NEEDED
=======================

The app counts the guest's frames to print the [fps] log line and feed the
perf overlay. The meter -nfsmw_app.h, MideFotogramas- works the only way a
meter can here: it reads a counter the presenter bumps every time it accepts
a frame from the guest, and diffs it over the watchdog's one-second tick.

That counter, guest_frames_refreshed(), was a LOCAL PATCH in ui/presenter.h
of the user's SDK checkout: the app was written against it and it never
reached upstream v0.10.0. Building the app against the pristine SDK fails
with:

    error: no member named 'guest_frames_refreshed' in 'rex::ui::Presenter'

This patch is that local patch, properly scripted: an accessor on the
presenter plus a counter bumped in RefreshGuestOutput's is_active branch -
a refresh that succeeded with an active guest output IS one guest frame
accepted; blank refreshes (guest output disabled) don't count, and nor
should they, or the meter would read free-running UI paints again.

RefreshGuestOutput runs on any thread (its own header says the callback may
be called from multiple at the same time), so the counter is a std::atomic
bumped with relaxed ordering: the value only feeds a rate meter, nothing
depends on its ordering.
"""

import argparse
import pathlib
import shutil
import sys

MARCA = "PARCHE LOCAL - contador de fotogramas del guest"

# ---------------------------------------------------------------------------
#  The exact spots, copied verbatim from the SDK source.
# ---------------------------------------------------------------------------

# presenter.h: the accessor goes right after RefreshGuestOutput's declaration
# (public section), so callers can read the meter.
ANCLA_ACCESOR = """  bool RefreshGuestOutput(uint32_t frontbuffer_width, uint32_t frontbuffer_height,
                          uint32_t display_aspect_ratio_x, uint32_t display_aspect_ratio_y,
                          std::function<bool(GuestOutputRefreshContext& context)> refresher);
"""

NUEVO_ACCESOR = """  bool RefreshGuestOutput(uint32_t frontbuffer_width, uint32_t frontbuffer_height,
                          uint32_t display_aspect_ratio_x, uint32_t display_aspect_ratio_y,
                          std::function<bool(GuestOutputRefreshContext& context)> refresher);

  // ------------------------------------------------------------------
  //  PARCHE LOCAL - contador de fotogramas del guest
  //
  //  El medidor de fps de la app (nfsmw_app.h MideFotogramas) lee esto.
  // ------------------------------------------------------------------
  // Guest frames refreshed since process start: every successful refresh of
  // an active guest output, i.e. every guest frame the presenter accepted.
  // The app's fps meter reads this (nfsmw_app.h MideFotogramas).
  uint64_t guest_frames_refreshed() const {
    return guest_frames_refreshed_.load(std::memory_order_relaxed);
  }
"""

# presenter.h: the member goes next to the flag RefreshGuestOutput already
# maintains. <atomic> is already included in this header.
ANCLA_MIEMBRO = """  bool guest_output_active_last_refresh_ = false;
"""

NUEVO_MIEMBRO = """  bool guest_output_active_last_refresh_ = false;

  // PARCHE LOCAL - contador de fotogramas del guest
  // Count of successful active guest-output refreshes; see
  // guest_frames_refreshed(). RefreshGuestOutput runs on any thread.
  std::atomic<uint64_t> guest_frames_refreshed_{0};
"""

# presenter.cpp: the bump, in the is_active branch only.
ANCLA_CONTADOR = """    guest_output_active_last_refresh_ = true;
"""

NUEVO_CONTADOR = """    guest_output_active_last_refresh_ = true;
    // PARCHE LOCAL - contador de fotogramas del guest
    // Guest frame accepted by the presenter (the app's fps meter counts
    // these; blank refreshes when the guest output is inactive do not count).
    guest_frames_refreshed_.fetch_add(1, std::memory_order_relaxed);
"""


def localizar_sdk():
    raiz = pathlib.Path(__file__).resolve().parent.parent
    for cand in [raiz.parent / "rexglue-sdk", raiz / "sdk"]:
        h = cand / "include" / "rex" / "ui" / "presenter.h"
        c = cand / "src" / "ui" / "presenter.cpp"
        if h.exists() and c.exists():
            return h, c
    sys.exit("[ERROR] No encuentro include/rex/ui/presenter.h y src/ui/presenter.cpp del SDK.\n"
             "        Se buscan en ../rexglue-sdk y en ./sdk")


def main():
    p = argparse.ArgumentParser(add_help=True)
    p.add_argument("--estado", action="store_true")
    p.add_argument("--revertir", action="store_true")
    args = p.parse_args()

    h, c = localizar_sdk()
    h_original = h.with_suffix(".h.original")
    c_original = c.with_suffix(".cpp.original")
    h_txt = h.read_text(encoding="utf-8")
    c_txt = c.read_text(encoding="utf-8")
    h_puesto = MARCA in h_txt
    c_puesto = MARCA in c_txt

    if args.estado:
        print(f"  {h}")
        print("  Parche (presenter.h):", "APLICADO" if h_puesto else "sin aplicar")
        print(f"  {c}")
        print("  Parche (presenter.cpp):", "APLICADO" if c_puesto else "sin aplicar")
        return 0

    if args.revertir:
        for f, orig in [(h, h_original), (c, c_original)]:
            if orig.exists():
                shutil.copy2(orig, f)
                print(f"[ok] Restaurado desde {orig.name}: {f.name}")
            else:
                print(f"[aviso] No hay {orig.name} que restaurar.")
        return 0

    if h_puesto or c_puesto:
        print("[ok] Ya estaba aplicado. No toco nada.")
        return 0

    # Check all three anchors BEFORE writing anything. If the SDK changes
    # version and one of them doesn't match, better not leave the files
    # half-done.
    for nombre, ancla, txt in [("accesor (presenter.h)", ANCLA_ACCESOR, h_txt),
                               ("miembro (presenter.h)", ANCLA_MIEMBRO, h_txt),
                               ("contador (presenter.cpp)", ANCLA_CONTADOR, c_txt)]:
        n = txt.count(ancla)
        if n != 1:
            sys.exit(f"[ERROR] El anclaje '{nombre}' aparece {n} veces, esperaba 1.\n"
                     f"        El SDK habra cambiado. No he tocado nada.")

    if not h_original.exists():
        shutil.copy2(h, h_original)
        print(f"[ok] Copia de seguridad: {h_original.name}")
    if not c_original.exists():
        shutil.copy2(c, c_original)
        print(f"[ok] Copia de seguridad: {c_original.name}")

    h_txt = h_txt.replace(ANCLA_ACCESOR, NUEVO_ACCESOR)
    h_txt = h_txt.replace(ANCLA_MIEMBRO, NUEVO_MIEMBRO)
    h.write_text(h_txt, encoding="utf-8")
    c_txt = c_txt.replace(ANCLA_CONTADOR, NUEVO_CONTADOR)
    c.write_text(c_txt, encoding="utf-8")

    print("[ok] Parche aplicado.")
    print()
    print("  guest_frames_refreshed()  accesor nuevo en Presenter")
    print("  guest_frames_refreshed_   contador, se incrementa por refresh activo")
    print()
    print("  HAY QUE RECOMPILAR EL SDK para que sirva de algo:")
    print("    cmake --build out/build/mac-arm64 --config Release --target install")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
