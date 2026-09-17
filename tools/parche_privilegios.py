#!/usr/bin/env python3
"""
Allow Xbox Live privileges to be granted, so you can get into multiplayer.

    python tools/parche_privilegios.py            aplicar
    python tools/parche_privilegios.py --estado
    python tools/parche_privilegios.py --revertir

Touches one SDK file:  src/kernel/xam/xam_user.cpp

Doesn't save a .original: it applies and undoes itself by exact text
substitution, block by block, like the other patches in this project.


WHERE THIS COMES FROM
==================

When entering multiplayer, the game shows this message:

    ATTENTION
    Your Xbox Live account privileges do not allow you to access this
    feature.

It's not a bug or a hang: it's a clean NO, and it happens well before the
network is even touched. The game asks about its privileges and is told it
has none.

The answer lives in xam_user.cpp, and the original comment leaves no doubt:

    u32 XamUserCheckPrivilege_entry(u32 user_index, u32 mask, mapped_u32 out_value) {
      ...
      // If we deny everything, games should hopefully not try to do stuff.
      *out_value = 0;
      return X_ERROR_SUCCESS;
    }

It denies ALL privileges, always, no matter which one is being asked about.
It comes from Xenia, and for an emulator without Xbox Live it makes sense:
if the game believes it has no permissions, it won't even try, and you avoid
it hanging against servers that have been offline for years.

The odd part is that the rest of the SDK says exactly the opposite:

    XamUserIsOnlineEnabled   -> 1        (there is a connection)
    XamUserGetMembershipTier -> 6        (which is Gold)
    user_profile.signin_state -> 1       (there is a signed-in session)
    user_profile.type         -> 1 | 2   (local and online profile)

So this is the only piece saying no. The profile is set up, the session is
signed in, and the membership is Gold; only the permissions are missing.


WHAT THIS DOES NOT FIX, WHICH IS THE IMPORTANT PART
============================================

This opens the menu's DOOR. It does not make multiplayer work. Behind it,
half of the network layer is still missing, and it's worth knowing that
before testing so you don't get your hopes up for nothing:

  - Of the 158 network functions declared in the SDK's ordinal table, 114
    have no implementation. Among them are exactly the System Link ones:

        0x36  XNetCreateKey          0x41  XNetConnect
        0x37  XNetRegisterKey        0x42  XNetGetConnectStatus
        0x38  XNetUnregisterKey      0x53  XNetGetSystemLinkPort
        0x3F  XNetUnregisterInAddr   0x09  getsockname

    That CreateKey/RegisterKey/UnregisterKey trio is what associates the
    match's XNKID and XNKEY; XNetConnect and XNetGetConnectStatus are what
    establish the link with the other machine.

  - The session handlers in xam/apps/xgi_app.cpp are just for show: they
    read the parameters, write them to the log, and return X_E_SUCCESS
    without doing anything. XSessionSearch doesn't even touch the results
    buffer, so a client searching for matches will always find zero.

So the usefulness of this patch is FINDING OUT WHERE THE NEXT WALL IS. With
it applied, the menu should let you through, and whatever shows up in the
log from there on tells you what this particular game needs, which could be
considerably less than what's missing overall.


COMES OFF BY DEFAULT
=============

The new setting is  grant_user_privileges  and it defaults to false, so
behavior doesn't change until you turn it on. It's read on EVERY call, so it
can be turned on from the F4 menu without restarting the game: turn it on,
leave the multiplayer menu, and go back in.

If granting the privileges makes the game start attempting Xbox Live things
and it hangs, turn it back off and you're right back to how things were.
That's why it's a switch and not a permanent change.
"""

import argparse
import pathlib
import sys


# ---------------------------------------------------------------------------
#  Bloque 1: el ajuste
# ---------------------------------------------------------------------------

CVAR_ANCLA = '''REXCVAR_DEFINE_UINT32(user_language, 1, "Kernel", "User's language ID");
'''

CVAR_NUEVO = '''REXCVAR_DEFINE_UINT32(user_language, 1, "Kernel", "User's language ID");

// PARCHE LOCAL - privilegios de Xbox Live
//
// Apagado por defecto: encendido cambia lo que el juego cree poder hacer, y eso
// merece ser una decision y no una sorpresa.
//
// kHotReload y no kRequiresRestart porque XamUserCheckPrivilege lo lee en cada
// llamada. Se puede encender desde F4 con el juego abierto; basta con salir del
// menu que dio el aviso y volver a entrar.
//
// El texto va en ingles porque es lo que sale en la ventana de F4, que es del
// SDK y esta entera en ingles.
REXCVAR_DEFINE_BOOL(grant_user_privileges, false, "Kernel",
                    "Tell the game it has every Xbox Live privilege. Off by default, which "
                    "makes the game refuse to open its multiplayer menus. Turning it on only "
                    "opens the door: system link also needs the XNet layer, which is only "
                    "half implemented here.")
    .lifecycle(rex::cvar::Lifecycle::kHotReload);
'''


# ---------------------------------------------------------------------------
#  Bloque 2: la respuesta
# ---------------------------------------------------------------------------

CHEQUEO_ANCLA = '''  // If we deny everything, games should hopefully not try to do stuff.
  *out_value = 0;
  return X_ERROR_SUCCESS;
}
'''

CHEQUEO_NUEVO = '''  // PARCHE LOCAL - privilegios de Xbox Live
  //
  // Aqui decia esto, y hacia exactamente lo que dice:
  //
  //     // If we deny everything, games should hopefully not try to do stuff.
  //     *out_value = 0;
  //
  // Deniega todos los privilegios, siempre, sea cual sea el que pregunten. Es
  // de Xenia y para un emulador sin Xbox Live se entiende: si el juego se cree
  // sin permisos ni lo intenta, y no se cuelga contra servidores apagados.
  //
  // En Most Wanted el efecto es el cartel "Los privilegios que tienes en Xbox
  // Live no te permiten acceder a esta funcion" nada mas tocar el multijugador.
  // Que ademas se contradice con el resto del SDK: XamUserIsOnlineEnabled
  // devuelve 1, XamUserGetMembershipTier devuelve 6 -que es Gold- y el perfil
  // dice signin_state 1 y type local|online. El unico que decia que no era este.
  //
  // OJO CON LO QUE ESTO NO HACE. Abre la puerta del menu y nada mas. El System
  // Link de detras necesita la capa XNet, y en este SDK faltan XNetCreateKey,
  // XNetRegisterKey, XNetUnregisterKey, XNetConnect y XNetGetConnectStatus,
  // ademas de que los manejadores de sesion de xgi_app.cpp devuelven exito sin
  // hacer nada. Esto sirve para ver donde esta el siguiente muro, no para
  // jugar en red.
  *out_value = REXCVAR_GET(grant_user_privileges) ? 1 : 0;
  return X_ERROR_SUCCESS;
}
'''


BLOQUES = [
    ("el ajuste grant_user_privileges", CVAR_ANCLA, CVAR_NUEVO),
    ("la respuesta de XamUserCheckPrivilege", CHEQUEO_ANCLA, CHEQUEO_NUEVO),
]


# There hasn't been a previous version of this patch yet. The list exists so
# that the migration machinery is the same as in the other scripts: the day
# there's a v2, it gets added here and it just works.
VIEJOS = []


def localizar_sdk():
    raiz = pathlib.Path(__file__).resolve().parent.parent
    for cand in [raiz.parent / "rexglue-sdk", raiz / "sdk"]:
        if (cand / "src" / "kernel" / "xam" / "xam_user.cpp").exists():
            return cand
    sys.exit("[ERROR] No encuentro src/kernel/xam/xam_user.cpp del SDK.\n"
             "        Se busca en ..\\rexglue-sdk y en .\\sdk")


def quitar_version_vieja(txt):
    """Removes leftovers from a previous version of this same patch.

    Same rule as in the other patches in this project: finding the old block
    only counts if it can NOT be the good one seen halfway applied.

        es_de_verdad_vieja = (viejo in txt) and
                             (viejo not in nuevo or nuevo not in txt)

    See parche_backend.py, where this is explained in full and where it took
    three tries to get right.
    """
    ahora = {ancla: nuevo for _, ancla, nuevo in BLOQUES}
    quitados = 0
    anclajes_hechos = set()
    for nombre, huella, viejo, ancla in VIEJOS:
        if ancla in anclajes_hechos:
            continue
        nuevo = ahora[ancla]
        if viejo not in txt:
            if huella in txt and nuevo not in txt:
                print(f"[aviso] Veo restos de '{nombre}' pero no en la forma que esperaba.")
                print(f"        Lo dejo estar; miralo a mano si algo va raro.")
            continue
        if viejo in nuevo and nuevo in txt:
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

    f = localizar_sdk() / "src" / "kernel" / "xam" / "xam_user.cpp"
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
    print("  En F4, categoria Kernel, ajuste  grant_user_privileges")
    print("  Viene APAGADO. Encendido, el juego se cree con todos los permisos.")
    print()
    print("  HAY QUE RECOMPILAR EL SDK:")
    print("    cmake --build out/build/win-amd64 --config Release --target install")
    return 0


if __name__ == "__main__":
    sys.exit(main())
