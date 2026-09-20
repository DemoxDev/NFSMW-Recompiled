#!/usr/bin/env python3
"""
No perder los cvars del plugin de GPU al caer a otro backend.

    python tools/parche_cvar_plugin.py            aplicar
    python tools/parche_cvar_plugin.py --estado
    python tools/parche_cvar_plugin.py --revertir

Touches one SDK file:  src/system/gpu_plugin_loader.cpp

Applies and undoes by exact text substitution, block by block; no .original.


WHY THIS WAS NEEDED
=======================

En macOS (y en cualquier sitio donde el backend pedido no este compilado) la
app carga el plugin DOS veces: primero pide d3d12, la fabrica devuelve null,
y la app vuelve a llamar a LoadGpuPlugin con vulkan.

El problema esta en la salida temprana por fabrica fallida: la DynamicLibrary
es una variable local, asi que al salir se destruye -> dlclose -> los
destructores estaticos del plugin desregistran sus cvars. El segundo Load
vuelve a cargar la imagen, sus inicializadores estaticos registran los cvars
otra vez... pero los valores pendientes de nfsmw.toml y de la linea de
comandos ya se habian consumido en el primer registro (cvar.cpp los borra
tras aplicarlos) y no quedaba nada que reaplicar.

Resultado: TODOS los cvars del plugin se quedaban en su valor por defecto y
los del toml/CLI se perdian en silencio. Medido en un M1 con
resolution_scale=2 en el toml:

    [temp-cvar] late registration of 'resolution_scale': pending_found=true config=2 cmdline=2
    [temp-cvar] late registration of 'resolution_scale': pending_found=false config=<none> cmdline=<none>
    [temp-scale] resolution_scale=1 non_default=false ... effective=1x1

Lo mismo valia para anisotropic_override, render_target_path_d3d12 y los
vulkan_*. En Windows no se nota porque el plugin carga una sola vez.

QUE HACE ESTE PARCHE
=======================

En la salida por fabrica fallida, guarda la libreria en LoadedPlugins() antes
de devolver null. Los plugins ya viven toda la vida del proceso (es lo que
dice el comentario de LoadedPlugins), asi que no se cierra nada: el segundo
Load reutiliza la misma imagen ya cargada, sus estaticos no se vuelven a
ejecutar, no se desregistra ni se re-registra ningun cvar y los valores
puestos se conservan.
"""

import argparse
import pathlib
import sys

# ---------------------------------------------------------------------------
#  The exact spot, copied verbatim from the SDK source.
# ---------------------------------------------------------------------------

ANCLA = """  IGraphicsSystem* graphics_system = create_fn(kGpuPluginAbiVersion, &info);
  if (!graphics_system) {
    REXSYS_ERROR("GPU plugin '{}' factory returned no graphics system (backend '{}')", name,
                 backend_str);
    return nullptr;
  }
"""

NUEVO = """  IGraphicsSystem* graphics_system = create_fn(kGpuPluginAbiVersion, &info);
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
"""

BLOQUES = [
    ("conservar la libreria si la fabrica falla", ANCLA, NUEVO),
]


def localizar_sdk():
    raiz = pathlib.Path(__file__).resolve().parent.parent
    for cand in [raiz.parent / "rexglue-sdk", raiz / "sdk"]:
        if (cand / "src" / "system" / "gpu_plugin_loader.cpp").exists():
            return cand
    sys.exit("[ERROR] No encuentro src/system/gpu_plugin_loader.cpp del SDK.\n"
             "        Se busca en ..\\rexglue-sdk y en .\\sdk")


def main():
    p = argparse.ArgumentParser(add_help=True)
    p.add_argument("--estado", action="store_true")
    p.add_argument("--revertir", action="store_true")
    args = p.parse_args()

    f = localizar_sdk() / "src" / "system" / "gpu_plugin_loader.cpp"
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
    print("  Los cvars del plugin conservan los valores del toml y de la CLI")
    print("  aunque la app tenga que caer al otro backend.")
    print()
    print("  HAY QUE RECOMPILAR EL SDK para que sirva de algo:")
    print("    cmake --build out/build/mac-arm64 --config Release --target install")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
