# Arquitectura

Cómo encajan las piezas, y sobre todo **dónde vive cada cosa**, que es lo que más
cuesta entender al llegar al proyecto.

## Las tres capas

```
   TU ISO
     │  EXTRAER_XEX.bat
     ▼
   default.xex ──────────┐
                         │  rexglue codegen
                         ▼
                   app/generated/          131 ficheros de C++ generado
                   nfsmw_recomp.*.cpp      el código PowerPC del juego, traducido
                   nfsmw_register.cpp      tabla de direcciones → funciones
                         │
                         │  clang
                         ▼
                   ┌───────────────┐
                   │  nfsmw.exe    │  el juego. Aquí dentro está su código.
                   └───────┬───────┘
                           │  enlaza contra
                   ┌───────▼────────────────────────────┐
                   │  rexruntime.dll   (el SDK)         │  ← AQUÍ VIVEN LOS ARREGLOS
                   │  kernel, VFS, audio, input, ventana│
                   └───────┬────────────────────────────┘
                           │  carga en tiempo de ejecución (LoadLibrary)
                   ┌───────▼────────────────────────────┐
                   │  rexgpu-xenos.dll                  │
                   │  Xenos → Direct3D 12 / Vulkan      │
                   └────────────────────────────────────┘
```

## Lo que hay que entender antes de tocar nada

**Casi ningún arreglo de este proyecto está en este repositorio.**

El código del juego no se puede editar: sale del generador y se sobrescribe en cada
`codegen`. Y los fallos que hemos ido arreglando —el cuelgue del audio, el vsync que no
existía, el selector de API, la puerta de los privilegios— no son del juego: son del
SDK. Acaban compilados dentro de `rexruntime.dll`.

Por eso el build hace, en este orden:

1. Aplica los parches al **fuente del SDK**, que está en `..\rexglue-sdk`
2. Recompila el SDK
3. Genera el C++ del juego
4. Compila el juego
5. Arma la carpeta portable

Si te saltas el paso 1 y 2, compilas un juego perfecto contra un runtime sin arreglar,
y el audio se muere igual que el primer día.

## Qué hay en cada sitio

### `app/`

La aplicación. Es sorprendentemente pequeña, y eso es buena señal.

| Fichero | Qué es |
|---|---|
| `nfsmw_manifest.toml` | Lo que lee el generador: dónde está el XEX, dónde escribir, qué TOMLs incluir |
| `overrides.toml` | Correcciones al generador escritas a mano, cada una con su motivo |
| `huecos.toml` | 774 huecos de ≥8 bytes que el análisis automático no reconoció como código. Lo genera `HUECOS.bat` |
| `nfsmw.toml` | Configuración del juego que se copia a la carpeta portable |
| `src/main.cpp` | Cuatro líneas: arranca la app |
| `src/nfsmw_app.h` | La subclase de `ReXApp`. Aquí sí hay lógica propia del juego |

`nfsmw_app.h` merece una lectura. Hace dos cosas que no son obvias:

- **Busca la ISO sola**, para que abrir el ejecutable sin argumentos funcione. Prefiere
  la que se llame igual que el ejecutable, si no la primera por orden alfabético, y si
  no una carpeta `game_root\`. Esto corre **antes** de que se lea `nfsmw.toml`, así que
  poner `game_data_root` en el toml no sirve de nada: manda la línea de comandos y, si
  no hay, esto.
- **Pone ajustes obligatorios** que sin ellos el juego no se ve o no se controla:
  `gpu_plugin`, `mnk_mode` y `readback_resolve`. Solo los pone si nadie los pidió, así
  que la línea de comandos y el toml siguen mandando. Y están en dos sitios distintos a
  propósito: `readback_resolve` lo registra el plugin de GPU, que se carga después, así
  que ponerlo antes sería escribir sobre un flag que aún no existe.

### `tools/parche_*.py`

Los parches. Cada uno es un script que aplica y deshace por sustitución de texto exacta
sobre el fuente del SDK. Ver [parches.md](parches.md) para el catálogo y el porqué del
diseño.

### `tools/lanzador/`

El lanzador, en C# con WinForms. Se compila con el `csc.exe` que ya trae Windows, sin
instalar nada. Ver [lanzador.md](lanzador.md).

### `tools/diagnostico/`

Instrumentación. No entra en un build normal. Se aplica a mano cuando hace falta
investigar algo y se revierte después.

## El sistema de cvars, que es cómo se configura todo

El SDK tiene un registro de variables de configuración. Entender sus dos ejes ahorra
horas.

**Prioridad de origen**, de menos a más:

```
kDefault  <  kConfig  <  kEnvironment  <  kCommandLine  <  kRuntime
```

Un valor puesto por la línea de comandos gana al del `nfsmw.toml`. Eso no es un detalle:
es lo que hace que el lanzador sea una salida de emergencia. Si eliges una API gráfica
que en tu equipo da pantalla negra y se guarda en el toml, el lanzador puede sacarte de
ahí porque pasa `--gpu_backend` siempre.

**Ciclo de vida**, que decide cuándo se puede cambiar:

| Ciclo | Significa |
|---|---|
| `kHotReload` | Se puede cambiar en caliente y tiene efecto ya |
| `kRequiresRestart` | Se puede cambiar y se guarda, pero no se aplica hasta reiniciar |
| `kInitOnly` | **Ni siquiera se puede guardar** después del arranque |

La diferencia entre los dos últimos costó un rato. `kInitOnly` hace que el menú de F4
pinte el ajuste en rojo y deshabilitado: se ve pero no se toca. Si lo que quieres es
"se puede cambiar, pero hace falta reiniciar", es `kRequiresRestart`, que además hace
que el SDK lo apunte en su lista de cambios pendientes.

Un aviso sobre esa lista: `SetFlagFromSource` apunta ahí cualquier `kRequiresRestart`
que se toque, **sin mirar de dónde viene el valor**. Así que un `--gpu_backend` en la
línea de comandos, que ya está aplicado desde el arranque, entraba igualmente y el menú
abría diciendo "hace falta reiniciar" desde el primer segundo. Por eso
`parche_backend.py` limpia la lista una vez terminado el arranque.

## El reloj del guest

`Clock::set_guest_time_scalar()` escala el reloj del guest **entero**: el contador de
ticks, la hora del sistema, los temporizadores y las esperas. Por eso vale como mando
de velocidad del juego sin tocar nada más — el hilo que genera el parpadeo vertical
compara ticks del guest, así que se ajusta solo.

Con un cuidado: `RecomputeGuestTickScalar` hace `frac.second *= uint64_t(10.0 / escala)`
cuando la escala es ≤ 1.0. Con la escala a cero eso es `10.0/0.0` = infinito, y
convertir infinito a `uint64_t` es comportamiento indefinido. Por eso el 0% de la barra
del lanzador se queda en una milésima de la velocidad normal en vez de en cero.

## Dos resoluciones que no son la misma

Esto confunde a todo el mundo, incluido a quien escribe esto.

- `--resolution` cambia el **modo de vídeo del guest** y el tamaño de la ventana. No le
  pide al juego que dibuje más fino. Most Wanted dibuja en sus propios render targets de
  tamaño fijo y deja que el escalador estire el resultado. Subir esto agranda la imagen.
- `--resolution_scale` multiplica el tamaño de esos render targets y de la EDRAM
  emulada. **Este** es el "x2" de los emuladores. Cuesta cara y crece con el cuadrado.

Ver [rendimiento.md](rendimiento.md) para los números medidos.

## La EDRAM, que es de donde sale la mitad del rendimiento

La Xbox 360 no tiene render targets normales: tiene 10 MB de memoria embebida donde el
hardware fijo hace la mezcla y el test de profundidad. Emular eso tiene dos caminos:

| Camino | Cómo | Coste |
|---|---|---|
| ROV | Rasterizer ordered views. Exacto | Lento |
| RTV | Render targets del host. Aproximado | Rápido |

En la Iris 540 medida, pasar de ROV a RTV llevó el juego de ~10 a ~18 fps. El SDK elige
ROV en Intel por defecto, que es la decisión conservadora; `render_target_path_d3d12`
permite saltársela.
