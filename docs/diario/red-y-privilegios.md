# El multijugador: hasta dónde llega y dónde se para

Estado corto: **no funciona.** La puerta está abierta; detrás falta media capa de red.

Esta entrada documenta qué se probó y qué se midió, para que quien quiera intentarlo no
repita el camino.

## Muro 1: los privilegios — resuelto

**Síntoma:** al entrar al multijugador, el juego saca un cartel y no deja pasar.

> ATENCIÓN
> Los privilegios que tienes en Xbox Live no te permiten acceder a esta función.

No es un fallo ni un cuelgue: es un **no** limpio, y llega mucho antes de que se toque la
red.

Está en `src/kernel/xam/xam_user.cpp`, y el comentario original no deja dudas:

```cpp
u32 XamUserCheckPrivilege_entry(u32 user_index, u32 mask, mapped_u32 out_value) {
  ...
  // If we deny everything, games should hopefully not try to do stuff.
  *out_value = 0;
  return X_ERROR_SUCCESS;
}
```

Deniega **todos** los privilegios, siempre, sea cual sea el que pregunten. Viene de Xenia
y para un emulador sin Xbox Live tiene su lógica: si el juego se cree sin permisos, ni
lo intenta, y no se cuelga contra servidores apagados.

Lo llamativo es que el resto del SDK dice lo contrario:

| Función | Devuelve |
|---|---|
| `XamUserIsOnlineEnabled` | 1 — hay conexión |
| `XamUserGetMembershipTier` | 6 — que es Gold |
| `user_profile.signin_state` | 1 — sesión iniciada |
| `user_profile.type` | 1 \| 2 — perfil local y online |

O sea: perfil montado, sesión iniciada, membresía Gold, y cero permisos. La única pieza
que decía que no era esa.

`parche_privilegios.py` añade `grant_user_privileges`, apagado por defecto. Encendido, se
pasa el cartel. **Confirmado funcionando.**

## Muro 2: los servidores de EA — insalvable

Pasado el cartel, el juego se pone a buscar las partidas en los servidores oficiales de
EA y se queda en bucle.

Esto no tiene arreglo y no merece esfuerzo: esos servidores llevan años apagados. No hay
parche que los devuelva. **La única vía posible es System Link**, que no usa
infraestructura de EA para nada — dos máquinas hablando directamente.

Un descarte útil: **no se atasca resolviendo el nombre.** `XNetDnsLookup` en este SDK ya
falla rápido a propósito:

```cpp
dns->status = 1;  // non-zero = error
if (event_handle) ev->Set(0, false);
```

Devuelve error y despierta el evento en el acto. El bucle está más arriba, probablemente
en que el juego reintenta la búsqueda de sesiones indefinidamente (ver abajo).

## Muro 3: la capa XNet — el trabajo de verdad

Aquí está el fondo del asunto. Cruzando la tabla de ordinales del SDK
(`src/kernel/xam/export_table.inc`) con lo que `xam_net.cpp` implementa de verdad:

- **158** funciones de red declaradas
- **44** implementadas
- **114** sin implementar

Lo que hay funciona y no es poco: sockets de verdad (`socket`, `bind`, `connect`,
`send`/`recv`, `sendto`/`recvfrom`, `select`), `XNetGetTitleXnAddr` devolviendo la IP
local, `XNetSetSystemLinkPort`.

Lo que falta es justo el System Link:

| Ordinal | Función | Para qué |
|---|---|---|
| 0x36 | `XNetCreateKey` | crear la XNKID/XNKEY de la partida |
| 0x37 | `XNetRegisterKey` | asociarla en el otro extremo |
| 0x38 | `XNetUnregisterKey` | |
| 0x3F | `XNetUnregisterInAddr` | |
| 0x41 | `XNetConnect` | levantar el enlace con el par |
| 0x42 | `XNetGetConnectStatus` | saber si se levantó |
| 0x53 | `XNetGetSystemLinkPort` | solo existe el *setter* |
| 0x09 | `getsockname` | básico, y tampoco está |

Ese trío `CreateKey`/`RegisterKey`/`UnregisterKey` es el que asocia la clave de sesión.
Sin él el juego no llega ni a intentar hablar.

## Muro 4: las sesiones son de adorno

Y hay una segunda capa igual de vacía. Los manejadores de sesión de
`src/kernel/xam/apps/xgi_app.cpp` leen los parámetros, los escriben en el log y
devuelven `X_E_SUCCESS` **sin hacer nada**. Por ejemplo `XSessionSearch` (mensaje
`0x000B0016`):

```cpp
REXKRNL_DEBUG("XSessionSearch({}, {}, {}, ...)", ...);
return X_E_SUCCESS;
```

Ni siquiera toca el buffer de resultados. Un cliente buscando partidas siempre encontrará
cero — y como le contestan "correcto", no tiene motivo para rendirse. **Un stub que
miente es peor que uno que falla.** Es la explicación más probable del bucle del muro 2.

Igual con `XSessionCreate`, `XSessionJoinRemote`, `XSessionModify` y el resto.

## Qué haría falta

Por orden, y sin engañarse con el tamaño:

1. **Los stubs de XNet que faltan**, mapeando XNADDR ↔ IP directamente en vez de
   emular la asociación segura real. Es lo que hacen los forks de red de Xenia.
2. **Descubrimiento de partidas de verdad**: que `XSessionCreate` registre una sesión
   local y que `XSessionSearch` la anuncie y la encuentre por broadcast UDP.
3. Solo entonces, la interfaz.

## Un aviso de diseño sobre "pásame tu IP"

La idea natural —un panel con tu IP y tu puerto para que un amigo los pegue como
"Host"— **no es como funciona el System Link.** La 360 descubre partidas por *broadcast*
en la red local, y un broadcast no cruza internet.

Para jugar con alguien de fuera harían falta, o bien una VPN que os ponga en la misma LAN
virtual (ZeroTier, Radmin, Hamachi), o bien una capa de conexión directa que sustituya el
broadcast por una IP concreta. Eso último es lo que hacen XLink Kai y las builds de red de
Xenia, y es diseño nuevo, no un ajuste.

## El siguiente paso, si alguien lo retoma

`LOG_DETALLADO.bat` arranca con `--log_level=debug --log_noisy=true`, y los manejadores de
sesión ya escriben cada llamada. Así que entrar al multijugador con eso puesto y dejarlo
dar vueltas 30 segundos da la secuencia exacta —qué pide el juego, en qué orden y dónde se
repite— sin escribir una línea de código.

Ese log es lo primero que hay que mirar. Puede que Most Wanted use bastante menos de lo
que falta en total.
