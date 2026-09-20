#!/usr/bin/env python3
"""
Deja de recrear el pipeline del presentador en cada pintado.

    python tools/parche_pipeline_pintado.py            aplicar
    python tools/parche_pipeline_pintado.py --estado
    python tools/parche_pipeline_pintado.py --revertir

Touches one SDK file:  src/ui/vulkan/vulkan_presenter.cpp

Applies and undoes by exact text substitution, block by block; no .original.


WHY THIS WAS NEEDED
=======================

El presentador guarda el pipeline con el que pinta la salida del guest a la
swapchain en PaintContext::GuestOutputPaintPipeline. Ese pipeline depende del
formato de la swapchain, y por eso hay una comprobacion que lo destruye y lo
vuelve a crear cuando el formato cambia:

    if (swapchain_pipeline != VK_NULL_HANDLE &&
        swapchain_format != swapchain_render_pass_format) {
      ...destruir...
    }
    if (swapchain_pipeline == VK_NULL_HANDLE) {
      swapchain_pipeline = CreateGuestOutputPaintPipeline(...);
    }

El problema: swapchain_format se queda en su valor por defecto
(VK_FORMAT_UNDEFINED) PARA SIEMPRE. Nadie lo asigna. Asi que la comprobacion
ve "el formato ha cambiado" en cada pintado, destruye el pipeline bueno y lo
crea otra vez con VK_NULL_HANDLE de cache.

En un driver nativo eso es caro; en MoltenVK es mucho peor, porque cada
vkCreateGraphicsPipelines vuelve a traducir el SPIR-V a MSL y a crear el
pipeline de Metal. Medido con el muestreador del sistema (sample) en un M1:
150 de 569 muestras del hilo de UI estaban dentro de
CreateGuestOutputPaintPipeline -> vkCreateGraphicsPipelines ->
MVKGraphicsPipeline::initMTLRenderPipelineState.

Este parche asigna swapchain_format justo despues de crear el pipeline. A
partir de ahi se crea una vez por formato de swapchain, como estaba pensado.
"""

import argparse
import pathlib
import sys

# ---------------------------------------------------------------------------
#  The exact spot, copied verbatim from the SDK source.
# ---------------------------------------------------------------------------

ANCLA = """            swapchain_effect_pipeline.swapchain_pipeline = CreateGuestOutputPaintPipeline(
                swapchain_effect, paint_context_.swapchain_render_pass);
            if (swapchain_effect_pipeline.swapchain_pipeline == VK_NULL_HANDLE) {
              guest_output_flow.effect_count = 0;
            }
"""

NUEVO = """            swapchain_effect_pipeline.swapchain_pipeline = CreateGuestOutputPaintPipeline(
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
"""

BLOQUES = [
    ("cache del pipeline de la swapchain", ANCLA, NUEVO),
]


def localizar_sdk():
    raiz = pathlib.Path(__file__).resolve().parent.parent
    for cand in [raiz.parent / "rexglue-sdk", raiz / "sdk"]:
        if (cand / "src" / "ui" / "vulkan" / "vulkan_presenter.cpp").exists():
            return cand
    sys.exit("[ERROR] No encuentro src/ui/vulkan/vulkan_presenter.cpp del SDK.\n"
             "        Se busca en ..\\rexglue-sdk y en .\\sdk")


def main():
    p = argparse.ArgumentParser(add_help=True)
    p.add_argument("--estado", action="store_true")
    p.add_argument("--revertir", action="store_true")
    args = p.parse_args()

    f = localizar_sdk() / "src" / "ui" / "vulkan" / "vulkan_presenter.cpp"
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
    print("  El pipeline del presentador se crea una vez por formato de")
    print("  swapchain, no en cada pintado.")
    print()
    print("  HAY QUE RECOMPILAR EL SDK para que sirva de algo:")
    print("    cmake --build out/build/mac-arm64 --config Release --target install")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
