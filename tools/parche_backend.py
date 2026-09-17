#!/usr/bin/env python3
"""
Adds a graphics API selector: D3D12 or Vulkan, selectable from F4.

    python tools/parche_backend.py            apply
    python tools/parche_backend.py --estado
    python tools/parche_backend.py --revertir

Touches one SDK file:  src/ui/rex_app.cpp

Does not keep an .original: applies and undoes by exact text substitution,
block by block, like the other patches in this project.

NOTE: this only adds the SETTING. For the "vulkan" option to actually do
anything, the SDK has to be built with the Vulkan backend included:

    cmake --preset win-amd64 -DREXGLUE_USE_VULKAN=ON

DIST.bat and PARCHE_ARRANQUE.bat already do this. And if it isn't built,
picking vulkan doesn't leave the game unable to start: it falls back to the
other API, says so in the log, and carries on.


DIRECTX 11 IS NOT HERE, AND IT IS NOT AN OVERSIGHT
==================================================

The question behind this was whether DX11 could be used instead of DX12 to
gain performance. No: this SDK only has two backends, and its CMake says so.

    option(REXGLUE_USE_D3D12  "Enable D3D12 graphics backend" ON)
    option(REXGLUE_USE_VULKAN "Enable Vulkan graphics backend" OFF)

And it's not a coincidence. The Xenos emulation relies on DX12-generation
features: the rasterizer ordered views of the ROV path, unbounded
descriptors, typed writes from shaders for memexport. A DX11 backend isn't a
tweak, it's rewriting the GPU plugin.

Besides, it wouldn't have fixed anything: the bottleneck is in the GPU -100%
usage, with the CPU nowhere near saturated-, and the API doesn't change how
many pixels need shading. Where DX11 sometimes wins is when the bottleneck is
submitting draw calls from the CPU, which isn't the case here.


WHAT CAN ACTUALLY BE DONE, AND THAT'S THIS
===========================================

The plugin already knows how to pick a backend by name. It's in
src/graphics/plugin_main.cpp:

    std::string_view backend = info->backend ? info->backend : "any";
    if (backend == "any" || backend == "d3d12")  return new D3D12GraphicsSystem();
    if (backend == "any" || backend == "vulkan") return new VulkanGraphicsSystem();

And LoadGpuPlugin accepts that name as a second parameter. The only thing
missing was someone passing it: rex_app.cpp used to call it with a single
argument, so it always came out as "any", which in practice is D3D12 since
it's first.

The Vulkan backend is entirely present in the code -around a megabyte of
sources in src/graphics/vulkan- and everything it needs already ships with
the SDK: vulkan-headers, vulkan-loader, vulkan-memory-allocator, glslang, and
spirv-tools. Nothing extra needs to be installed.


WHAT TO EXPECT
==============

No idea, and I'm not going to sugarcoat it. On an Intel GPU of this
generation the Vulkan driver is a completely different path from D3D12, and
it can go better or worse. What is true is that this SDK's Vulkan backend is
less battle-tested than its D3D12 one: if it comes out with graphical
glitches or won't start, switch back to d3d12 and nothing is lost but the
time spent building.

A BUG IN THE FIRST VERSION, FOR THE RECORD
===========================================

v1 marked the setting as kInitOnly, copying what gpu_plugin did. In the menu
it showed up red and disabled: visible, but untouchable. Wrong.

kInitOnly means "the new value can't even be saved", and the SDK itself
refuses to write it once running. But here the value CAN be saved; what
can't be done is applying it while the game is open. That's kRequiresRestart,
which also makes the SDK note it in a pending-changes list that already
existed -GetPendingRestartFlags- and that nobody surfaced. The menu patch now
surfaces it, with a button to restart.

And along the way "any" was removed from the options: with any there was no
way to tell which one was actually set, which was exactly what needed to be
seen.
"""

import argparse
import pathlib
import sys

# ---------------------------------------------------------------------------
#  1) The cvar, next to gpu_plugin's
# ---------------------------------------------------------------------------

CVAR_ANCLA = """REXCVAR_DEFINE_STRING(gpu_plugin, "", "GPU",
                      "GPU emulation plugin to load at startup (e.g. 'xenos'); empty disables "
                      "GPU emulation")
    .lifecycle(rex::cvar::Lifecycle::kInitOnly);
"""

CVAR_NUEVO = """REXCVAR_DEFINE_STRING(gpu_plugin, "", "GPU",
                      "GPU emulation plugin to load at startup (e.g. 'xenos'); empty disables "
                      "GPU emulation")
    .lifecycle(rex::cvar::Lifecycle::kInitOnly);

// PARCHE LOCAL - selector de API grafica
//
// El plugin ya sabia elegir entre D3D12 y Vulkan por nombre; lo que faltaba
// era que alguien se lo dijera. Ver plugin_main.cpp:
//
//     if (backend == "any" || backend == "d3d12")  -> D3D12GraphicsSystem
//     if (backend == "any" || backend == "vulkan") -> VulkanGraphicsSystem
//
// "any" coge el primero que este compilado, que es D3D12. Con esto se puede
// forzar uno concreto y comparar.
//
// PIDE REINICIO, PERO NO ES DE SOLO LECTURA. La primera version lo puse como
// kInitOnly, igual que gpu_plugin, y el menu de F4 lo pintaba en rojo y
// deshabilitado: se veia pero no se podia tocar. Es que kInitOnly significa
// "no se puede ni guardar el valor nuevo", y aqui si se puede: lo que no se
// puede es aplicarlo sin reiniciar. Eso es kRequiresRestart, que ademas hace
// que el SDK lo apunte en su lista de cambios pendientes -y el menu la
// ensena, con un boton para reiniciar-.
//
// Y ya no hay "any". Con any no se sabia cual estaba puesta de verdad, que era
// justo lo que habia que ensenar. Con dos opciones y ambas explicitas, el
// ajuste ES la respuesta a "cual se esta usando".
//
// El texto va en ingles porque es lo que sale en esa ventana, que es del SDK
// y esta entera en ingles.
REXCVAR_DEFINE_STRING(gpu_backend, "d3d12", "GPU",
                      "Graphics API: d3d12 or vulkan. Takes effect on restart. If the one "
                      "you pick was not built into this copy, the game falls back to the "
                      "other one and says so in the log.")
    .allowed({"d3d12", "vulkan"})
    .lifecycle(rex::cvar::Lifecycle::kRequiresRestart);

"""

# ---------------------------------------------------------------------------
#  2) Passing it to the loader
# ---------------------------------------------------------------------------

CARGA_ANCLA = """  if (!config_.graphics && !config_.gpu_plugin.empty()) {
    config_.graphics = rex::system::LoadGpuPlugin(config_.gpu_plugin);
"""

CARGA_NUEVO = """  if (!config_.graphics && !config_.gpu_plugin.empty()) {
    // PARCHE LOCAL - selector de API grafica
    //
    // Antes se llamaba con un solo argumento, asi que el backend quedaba en
    // "any" por defecto y siempre salia D3D12 por ser el primero del if. El
    // segundo parametro ya existia en LoadGpuPlugin; solo faltaba usarlo.
    const std::string backend_elegido = REXCVAR_GET(gpu_backend);
    REXLOG_INFO("API grafica pedida: {}", backend_elegido);
    config_.graphics = rex::system::LoadGpuPlugin(config_.gpu_plugin, backend_elegido);

    // Si la que se ha pedido no esta compilada en esta copia, el plugin
    // devuelve nada. Antes de eso significaba pantalla de error y a editar el
    // toml a mano; ahora se cae a la otra y se dice bien claro. Como solo hay
    // dos, "any" es exactamente la otra.
    if (!config_.graphics) {
      REXLOG_WARN("La API grafica '{}' no esta compilada en esta copia. Se prueba con la otra.",
                  backend_elegido);
      config_.graphics = rex::system::LoadGpuPlugin(config_.gpu_plugin, "any");
      if (config_.graphics) {
        // Solo hay dos, asi que "any" es exactamente la otra.
        const char* la_otra = (backend_elegido == "vulkan") ? "d3d12" : "vulkan";
        REXLOG_WARN("Arrancando con '{}' en su lugar. Cambia gpu_backend para quitar el aviso.",
                    la_otra);
      }
    }

    // Y aqui se borra la lista de "pendiente de reiniciar", que a estas alturas
    // solo puede tener mentiras.
    //
    // SetFlagFromSource apunta en esa lista cualquier cvar kRequiresRestart que
    // se toque, SIN MIRAR de donde viene el valor. Con lo cual un
    // --gpu_backend=vulkan en la linea de comandos, que se aplica en el
    // arranque y ya esta puesto cuando se lee aqui arriba, entraba igualmente
    // en la lista, y el menu de F4 abria diciendo "Restart needed to apply:
    // gpu_backend" desde el primer segundo. Un aviso que no se puede quitar
    // deja de leerse, y entonces tampoco se lee cuando es de verdad.
    //
    // Todo lo que hay en la lista en este punto viene del toml o de la linea de
    // comandos, o sea que ya esta aplicado por definicion. Lo que se cambie
    // luego desde F4 se vuelve a apuntar y ese aviso si es real.
    rex::cvar::ClearPendingRestartFlags();
"""

BLOQUES = [
    ("el cvar gpu_backend", CVAR_ANCLA, CVAR_NUEVO),
    ("pasarselo al cargador", CARGA_ANCLA, CARGA_NUEVO),
]

# ---------------------------------------------------------------------------
#  Previous version of THIS patch, to allow migration
#
#  v1 left gpu_backend as kInitOnly -which is why it showed up red and
#  couldn't be touched in the menu-, with "any" among the options and no
#  fallback if the chosen API wasn't built in. Text taken verbatim from the
#  already-patched file, not typed by hand, so the substitution is exact.
# ---------------------------------------------------------------------------

VIEJO_CVAR = 'REXCVAR_DEFINE_STRING(gpu_plugin, "", "GPU",\n                      "GPU emulation plugin to load at startup (e.g. \'xenos\'); empty disables "\n                      "GPU emulation")\n    .lifecycle(rex::cvar::Lifecycle::kInitOnly);\n\n// PARCHE LOCAL - selector de API grafica\n//\n// El plugin ya sabia elegir entre D3D12 y Vulkan por nombre; lo que faltaba\n// era que alguien se lo dijera. Ver plugin_main.cpp:\n//\n//     if (backend == "any" || backend == "d3d12")  -> D3D12GraphicsSystem\n//     if (backend == "any" || backend == "vulkan") -> VulkanGraphicsSystem\n//\n// "any" coge el primero que este compilado, que es D3D12. Con esto se puede\n// forzar uno concreto y comparar.\n//\n// De solo lectura en marcha: el sistema grafico se crea una vez al arrancar y\n// no se puede cambiar con el juego abierto. En F4 se ve, se cambia, y hace\n// falta reiniciar; igual que gpu_plugin, que esta justo encima.\n//\n// El texto va en ingles porque es lo que sale en esa ventana, que es del SDK\n// y esta entera en ingles.\nREXCVAR_DEFINE_STRING(gpu_backend, "any", "GPU",\n                      "Graphics API to use: any (first one available), d3d12 or vulkan. "\n                      "Vulkan only works if the SDK was built with REXGLUE_USE_VULKAN=ON. "\n                      "Takes effect on restart.")\n    .allowed({"any", "d3d12", "vulkan"})\n    .lifecycle(rex::cvar::Lifecycle::kInitOnly);\n'

VIEJA_CARGA = '  if (!config_.graphics && !config_.gpu_plugin.empty()) {\n    // PARCHE LOCAL - selector de API grafica\n    //\n    // Antes se llamaba con un solo argumento, asi que el backend quedaba en\n    // "any" por defecto y siempre salia D3D12 por ser el primero del if. El\n    // segundo parametro ya existia en LoadGpuPlugin; solo faltaba usarlo.\n    const std::string backend_elegido = REXCVAR_GET(gpu_backend);\n    REXLOG_INFO("API grafica pedida: {}", backend_elegido);\n    config_.graphics = rex::system::LoadGpuPlugin(config_.gpu_plugin, backend_elegido);\n'

# v2 added a global variable shared between rex_app.cpp and the settings
# menu. IT COULD NOT WORK, and the linker said so loud and clear:
#
#   lld-link: error: undefined symbol: rex::ui::g_gpu_backend_en_uso
#   >>> referenced by settings_overlay.cpp.obj
#
# I had assumed both files ended up in the same library. They don't:
# rex_app.cpp is NOT compiled inside the SDK, it gets INSTALLED as source in
# share/rexglue/ and each application compiles it. So the definition ended up
# inside nfsmw.exe and the reference inside rexruntime.dll. You can see it by
# looking at where the error itself places the .obj files.
VIEJO_CVAR_V2 = 'REXCVAR_DEFINE_STRING(gpu_plugin, "", "GPU",\n                      "GPU emulation plugin to load at startup (e.g. \'xenos\'); empty disables "\n                      "GPU emulation")\n    .lifecycle(rex::cvar::Lifecycle::kInitOnly);\n\n// PARCHE LOCAL - selector de API grafica\n//\n// El plugin ya sabia elegir entre D3D12 y Vulkan por nombre; lo que faltaba\n// era que alguien se lo dijera. Ver plugin_main.cpp:\n//\n//     if (backend == "any" || backend == "d3d12")  -> D3D12GraphicsSystem\n//     if (backend == "any" || backend == "vulkan") -> VulkanGraphicsSystem\n//\n// "any" coge el primero que este compilado, que es D3D12. Con esto se puede\n// forzar uno concreto y comparar.\n//\n// PIDE REINICIO, PERO NO ES DE SOLO LECTURA. La primera version lo puse como\n// kInitOnly, igual que gpu_plugin, y el menu de F4 lo pintaba en rojo y\n// deshabilitado: se veia pero no se podia tocar. Es que kInitOnly significa\n// "no se puede ni guardar el valor nuevo", y aqui si se puede: lo que no se\n// puede es aplicarlo sin reiniciar. Eso es kRequiresRestart, que ademas hace\n// que el SDK lo apunte en su lista de cambios pendientes -y el menu la\n// ensena, con un boton para reiniciar-.\n//\n// Y ya no hay "any". Con any no se sabia cual estaba puesta de verdad, que era\n// justo lo que habia que ensenar. Con dos opciones y ambas explicitas, el\n// ajuste ES la respuesta a "cual se esta usando".\n//\n// El texto va en ingles porque es lo que sale en esa ventana, que es del SDK\n// y esta entera en ingles.\nREXCVAR_DEFINE_STRING(gpu_backend, "d3d12", "GPU",\n                      "Graphics API: d3d12 or vulkan. Takes effect on restart. If the one "\n                      "you pick was not built into this copy, the game falls back to the "\n                      "other one and says so in the log.")\n    .allowed({"d3d12", "vulkan"})\n    .lifecycle(rex::cvar::Lifecycle::kRequiresRestart);\n\n// PARCHE LOCAL - selector de API grafica\n//\n// La API que se acabo usando de verdad, para que el menu de F4 la pueda\n// ensenar. Casi siempre es la que dice el cvar, pero si esa no estaba\n// compilada se arranca con la otra, y entonces el cvar miente.\n//\n// Vive aqui y no en un sitio mas elegante porque rex_app.cpp y el menu de\n// ajustes se compilan en la misma biblioteca; una variable suelta y una\n// declaracion extern bastan, sin cabeceras nuevas ni ABI que mantener.\nnamespace rex::ui {\nstd::string g_gpu_backend_en_uso = "?";\n}  // namespace rex::ui\n'

VIEJA_CARGA_V2 = '  if (!config_.graphics && !config_.gpu_plugin.empty()) {\n    // PARCHE LOCAL - selector de API grafica\n    //\n    // Antes se llamaba con un solo argumento, asi que el backend quedaba en\n    // "any" por defecto y siempre salia D3D12 por ser el primero del if. El\n    // segundo parametro ya existia en LoadGpuPlugin; solo faltaba usarlo.\n    const std::string backend_elegido = REXCVAR_GET(gpu_backend);\n    REXLOG_INFO("API grafica pedida: {}", backend_elegido);\n    config_.graphics = rex::system::LoadGpuPlugin(config_.gpu_plugin, backend_elegido);\n    rex::ui::g_gpu_backend_en_uso = backend_elegido;\n\n    // Si la que se ha pedido no esta compilada en esta copia, el plugin\n    // devuelve nada. Antes de eso significaba pantalla de error y a editar el\n    // toml a mano; ahora se cae a la otra y se dice bien claro. Como solo hay\n    // dos, "any" es exactamente la otra.\n    if (!config_.graphics) {\n      REXLOG_WARN("La API grafica \'{}\' no esta compilada en esta copia. Se prueba con la otra.",\n                  backend_elegido);\n      config_.graphics = rex::system::LoadGpuPlugin(config_.gpu_plugin, "any");\n      if (config_.graphics) {\n        rex::ui::g_gpu_backend_en_uso = (backend_elegido == "vulkan") ? "d3d12" : "vulkan";\n        REXLOG_WARN("Arrancando con \'{}\' en su lugar. Para quitar el aviso, cambia gpu_backend.",\n                    rex::ui::g_gpu_backend_en_uso);\n      }\n    }\n'

# v3 was already the good one -no shared variable, with a fallback-, but it
# was missing the cleanup of the pending-restart list, so the F4 menu would
# open with a false warning as soon as the launcher passed --gpu_backend. It
# is v4 without that last line, i.e. an EXACT PREFIX of v4: the case that
# forced a change to the quitar_version_vieja rule.
#
# It's sliced out of the current block instead of being copied by hand,
# which is where typos creep in. The cut happens RIGHT BEFORE the newline
# that opens the blank separator line, so what's left ends in "    }\n",
# which is exactly how v3 ended. One extra "\n" here and the block would
# never be found, because in the file, right after that brace comes
# "    if (!config_.graphics) {", with no blank line.
VIEJA_CARGA_V3 = CARGA_NUEVO[:CARGA_NUEVO.index(
    "\n\n    // Y aqui se borra la lista") + 1]

# NEWEST TO OLDEST. v2 is v1 with things added, so checking v1 first would
# only remove its part and leave v2's tail dangling.
VIEJOS = [
    # (name, fingerprint that ONLY appears in that version, whole block, anchor)
    ("carga de la v3 (sin limpiar los reinicios pendientes)",
     'const char* la_otra = (backend_elegido == "vulkan") ? "d3d12" : "vulkan";',
     VIEJA_CARGA_V3, CARGA_ANCLA),
    ("cvar de la v2 (variable compartida)",
     'std::string g_gpu_backend_en_uso = "?";', VIEJO_CVAR_V2, CVAR_ANCLA),
    ("carga de la v2 (variable compartida)",
     'rex::ui::g_gpu_backend_en_uso = backend_elegido;', VIEJA_CARGA_V2, CARGA_ANCLA),
    ("cvar de la v1 (any / solo lectura)",
     '.allowed({"any", "d3d12", "vulkan"})', VIEJO_CVAR, CVAR_ANCLA),
    ("carga de la v1 (sin reserva)",
     'REXLOG_INFO("API grafica pedida: {}", backend_elegido);', VIEJA_CARGA, CARGA_ANCLA),
]


def localizar_sdk():
    raiz = pathlib.Path(__file__).resolve().parent.parent
    for cand in [raiz.parent / "rexglue-sdk", raiz / "sdk"]:
        if (cand / "src" / "ui" / "rex_app.cpp").exists():
            return cand
    sys.exit("[ERROR] No encuentro src/ui/rex_app.cpp del SDK.\n"
             "        Se busca en ..\\rexglue-sdk y en .\\sdk")


def quitar_version_vieja(txt):
    """Removes the leftovers of an earlier version of this same patch.

    THE PROBLEM, WHICH TOOK ME THREE TRIES
    --------------------------------------
    An old block and the current one can overlap in two ways, and each one
    breaks the other's obvious fix:

      * THE OLD ONE IS A PIECE OF THE CURRENT ONE (code was added to the
        block). Searching for the old one finds it INSIDE the good one, and
        replacing it with the anchor chops the head off the block that was
        just applied. Running it again then leaves the tail DUPLICATED. The
        file grew on every pass.

      * THE CURRENT ONE IS A PIECE OF THE OLD ONE (code was removed from the
        block). Then "the good block is there" comes back true even though
        what's actually there is still the whole old one, and the script
        considers itself applied while leaving dead code inside.

    I tried to solve it with a FINGERPRINT per version -a piece that only
    existed in that version-. It doesn't always exist: when the old one is
    an exact prefix of the new one, EVERYTHING in the old one is also in the
    new one.

    THE RULE THAT ACTUALLY WORKS, AND NEEDS NO FINGERPRINTS
    ---------------------------------------------------------
    Finding the old block only counts if it CAN'T be the good one seen
    halfway:

        es_de_verdad_vieja = (viejo in txt) and
                             (viejo not in nuevo or nuevo not in txt)

    Both cases above come out right with that, and it's checked using only
    the texts themselves, without me having to hand-pick any fingerprint.

    VIEJOS still goes NEWEST TO OLDEST, and as soon as one version matches
    for a given anchor, the other versions for that anchor are skipped: if
    v2 is v1 with things added, checking v1 first would leave v2's tail
    orphaned. That happened too.

    And this is tested by running the patch TWICE in a row on the real file
    and comparing. The duplication bug doesn't show up on the first pass,
    which is the only one people usually look at.
    """
    ahora = {ancla: nuevo for _, ancla, nuevo in BLOQUES}
    quitados = 0
    anclajes_hechos = set()
    for nombre, huella, viejo, ancla in VIEJOS:
        if ancla in anclajes_hechos:
            continue
        nuevo = ahora[ancla]
        if viejo not in txt:
            # The fingerprint is only used to warn: if a piece of that
            # version shows up but the whole block doesn't match, someone has
            # edited it by hand and I'd rather not guess.
            if huella in txt and nuevo not in txt:
                print(f"[aviso] Veo restos de '{nombre}' pero no en la forma que esperaba.")
                print(f"        Lo dejo estar; miralo a mano si algo va raro.")
            continue
        if viejo in nuevo and nuevo in txt:
            # It's not an old version: it's the current block, which
            # contains the old one inside it. This anchor is already up to
            # date.
            anclajes_hechos.add(ancla)
            continue
        txt = txt.replace(viejo, ancla)
        anclajes_hechos.add(ancla)
        print(f"[ok] Quitada la version anterior: {nombre}")
        quitados += 1
    return txt, quitados


def main():
    p = argparse.ArgumentParser(add_help=True)
    p.add_argument("--estado", action="store_true")
    p.add_argument("--revertir", action="store_true")
    args = p.parse_args()

    f = localizar_sdk() / "src" / "ui" / "rex_app.cpp"
    txt = f.read_text(encoding="utf-8")

    if args.estado:
        puestos = sum(1 for _, _, nuevo in BLOQUES if nuevo in txt)
        print(f"  {f.name:26s} {puestos} de {len(BLOQUES)} bloques aplicados")
        for nombre, _, nuevo in BLOQUES:
            print(f"      {'si' if nuevo in txt else 'NO':>2}  {nombre}")
        # Uses the same rule the migration uses, so that --estado doesn't
        # warn about leftovers that are actually just pieces of the good
        # block.
        ahora = {ancla: nuevo for _, ancla, nuevo in BLOQUES}
        viejos = sum(1 for _, _, viejo, ancla in VIEJOS
                     if viejo in txt
                     and (viejo not in ahora[ancla] or ahora[ancla] not in txt))
        if viejos:
            print(f"      -- quedan {viejos} bloques de la version anterior")
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
        txt, viejos = quitar_version_vieja(txt)
        quitados += viejos
        if not quitados:
            print(f"[ok] {f.name}: no habia nada puesto")
            return 0
        f.write_text(txt, encoding="utf-8")
        print(f"[ok] Quitados {quitados} bloques de {f.name}")
        print()
        print("  HAY QUE RECOMPILAR EL SDK.")
        return 0

    txt, _ = quitar_version_vieja(txt)

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
    print("  En F4, categoria GPU, ajuste  gpu_backend  (d3d12 / vulkan)")
    print("  Pide reiniciar el juego para que valga.")
    print()
    print("  HAY QUE RECOMPILAR EL SDK, y con Vulkan encendido:")
    print("    cmake --preset win-amd64 -DREXGLUE_USE_VULKAN=ON")
    print("    cmake --build out/build/win-amd64 --config Release --target install")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
