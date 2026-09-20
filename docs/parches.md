# Los parches

Catálogo de lo que este proyecto cambia en el SDK, por qué, y cómo se comprobó.

Todos se aplican sobre el fuente de `..\rexglue-sdk` antes de compilarlo. Ninguno toca
el código del juego.

## Cómo se usan

```bat
python tools\parche_velocidad.py              aplicar
python tools\parche_velocidad.py --estado     ver qué hay puesto
python tools\parche_velocidad.py --revertir   deshacer
```

`CONSTRUIR.bat` los aplica todos en el orden correcto. El orden importa en un caso:
`parche_anillo.py` va antes que `parche_desatasco.py`, porque el segundo se apoya en las
cabeceras (`<atomic>`, `<chrono>`) que mete el primero. El script de desatasco se niega
a aplicarse si el otro no ha pasado.

## El catálogo

### `parche_desatasco.py` — el cuelgue del audio

**El importante.** Sin él, después del prólogo, al salir del garaje el audio se muere y
al volver al menú el juego se congela.

Toca `xboxkrnl_audio_xma.cpp`. Cuando un contexto XMA lleva más de 250 ms girando sin
entrada y con la lectura pegada a la escritura, le da la señal de "buffer terminado" que
el propio juego sabe interpretar.

Es un apaño deliberado: rompe el atasco en vez de evitarlo, y puede costar un tropiezo
de audio en esa voz. La historia completa —y por qué el arreglo "obvio" era el
equivocado— está en [diario/audio-cuelgue.md](diario/audio-cuelgue.md).

**Comprobado:** el usuario jugó la zona que lo reproducía sin que se colgara.

### `parche_anillo.py` — instrumentación del XMA

Prerrequisito del anterior. Añade trazas a las funciones del kernel del XMA. Con el
nivel de log normal no imprime nada.

Un detalle que costó una tarde: los *getters* van limitados a una traza por segundo,
pero los *setters* no. Limitar los dos por igual escondía justo lo que había que ver
—las entregas de entrada— y el diagnóstico se fue por el camino equivocado.

### `parche_presentador.py` — vsync y límite de fps

De fábrica **ninguno de los dos funciona**:

- `vsync` existe como cvar pero no sincroniza nada. Se lee en un solo sitio y solo
  decide si el procesador de comandos duerme o gira en las esperas del guest. El
  `Present` del presentador de D3D12 llevaba el `SyncInterval` clavado a 0.
- No había ningún limitador de fps. Ninguno.

Este parche arregla las dos cosas. El lanzador avisa en rojo si no está aplicado.

### `parche_gpu_fallback.py` — no morir sin GPU

Si el dispositivo D3D12 no se puede crear, cae a WARP en vez de dar una pantalla de
error. Útil en máquinas sin drivers decentes.

### `parche_backend.py` — selector de API gráfica

Añade el cvar `gpu_backend` (`d3d12` / `vulkan`) y se lo pasa al cargador del plugin.

El plugin ya sabía elegir por nombre; lo único que faltaba era que alguien se lo dijera.
`rex_app.cpp` llamaba a `LoadGpuPlugin` con un solo argumento, así que siempre salía
`any`, que en la práctica es D3D12 por ser el primero del `if`.

Tres cosas que este parche aprendió por las malas:

- Es `kRequiresRestart`, no `kInitOnly`. Con `kInitOnly` el menú lo pintaba en rojo y
  no se podía tocar.
- **No hay opción `any`.** Con `any` no se sabía cuál estaba puesta de verdad, que era
  justo lo que había que enseñar.
- Limpia la lista de reinicios pendientes al terminar el arranque, porque si no el menú
  abría con un aviso falso permanente. Ver [arquitectura.md](arquitectura.md).

Si la API elegida no está compilada, cae a la otra y lo dice en el log en vez de no
arrancar.

**Comprobado:** tres pasadas seguidas idénticas, revertir y volver a aplicar devuelve el
mismo resultado, sin restos de versiones anteriores.

### `parche_restaurar.py` — el menú de F4

Cinco bloques en `settings_overlay.cpp`:

- Aviso de reinicio pendiente, con botón para guardar y reiniciar. El SDK ya llevaba la
  cuenta (`GetPendingRestartFlags`) pero no la enseñaba en ninguna parte, así que
  cambiar la API gráfica parecía no hacer nada.
- Foto de la configuración de arranque, para poder volver a ella.
- Botón "Restore defaults" que restaura **esa** foto, no los valores de fábrica del SDK.
- Deslizador para los ajustes decimales con límites, en vez de una caja de texto.
- La API gráfica en uso, leída del registro de cvars.

Ese último punto tiene una lección cara detrás. La primera versión usaba una variable
global compartida con `rex_app.cpp` y **no enlazaba**:

```
lld-link: error: undefined symbol: rex::ui::g_gpu_backend_en_uso
```

`rex_app.cpp` no se compila dentro del SDK: se **instala como fuente** en
`share/rexglue/` y lo compila cada aplicación. Así que la definición acababa dentro de
`nfsmw.exe` y la referencia dentro de `rexruntime.dll`. Para hablar entre módulos está
el registro de cvars.

### `parche_velocidad.py` — velocidad del juego

Añade `game_speed`, en porcentaje, de 0 a 200. No es un límite de fps: cambia a qué
ritmo pasa el tiempo dentro del juego.

En porcentaje y no en multiplicador porque en la ventana de F4 sale un número pelado y
"1.0" no dice de qué. Con un suelo en 0.1% porque un cero literal no cuelga el juego: lo
tumba, por la división de `RecomputeGuestTickScalar`.

### `parche_privilegios.py` — la puerta del multijugador

De fábrica `XamUserCheckPrivilege` deniega **todos** los privilegios, siempre. El
comentario original lo dice: *"If we deny everything, games should hopefully not try to
do stuff"*. En Most Wanted el efecto es el cartel "Los privilegios que tienes en Xbox
Live no te permiten acceder a esta función".

Añade el ajuste `grant_user_privileges`, **apagado por defecto**. Encendido, contesta
que sí a todo.

Abre la puerta del menú y nada más. Lo que hay detrás no funciona; ver
[diario/red-y-privilegios.md](diario/red-y-privilegios.md).

### `parche_diagnostico.py` — trazas del arranque

Instrumentación general que se quedó porque es barata y útil. Entre otras cosas es lo
que puso nombre y hora al cuelgue del audio.

### `parche_fotogramas.py` — el contador de fotogramas del guest

Publica `Presenter::guest_frames_refreshed()`: cuántos refreshes activos del guest
output ha aceptado el presentador, o lo que es lo mismo, cuántos fotogramas del juego
han pasado por pantalla. Es lo que la app lee para la línea `[fps]` del log y para el
overlay (`MideFotogramas` en `nfsmw_app.h`): un contador que solo sube cuando hay
fotograma de verdad, no cuando la UI repinta.

Es un parche LOCAL del SDK que existió en el checkout Linux del usuario, sobre el que
se escribió el medidor de la app, y que nunca llegó al SDK puro (v0.10.0): sin él, la
app no compila (`error: no member named 'guest_frames_refreshed' in
'rex::ui::Presenter'`). Es el décimo parche y el único que no está en `CONSTRUIR.bat`;
`tools/build_mac.sh` lo aplica tras `parche_privilegios`.

Toca dos ficheros: el accesor y el `std::atomic<uint64_t>` van en
`include/rex/ui/presenter.h` (ya incluía `<atomic>`), y el `fetch_add` va en el
`RefreshGuestOutput` de `src/ui/presenter.cpp`, solo en la rama `is_active` — un
refresh en blanco (guest output inactivo) no cuenta, o el medidor volvería a medir
repintados de la UI. El contador es atómico porque `RefreshGuestOutput` corre en
cualquier hilo; solo alimenta un medidor de ritmo, así que `relaxed`.

**Comprobado:** los tres anclajes aparecen exactamente una vez en el SDK puro (contado
con grep antes de escribirlos), aplicar → idempotente, `--revertir` restaura el par
desde los `.original`, reaplicar deja el mismo texto; y el build de la app enlaza con
él (ver la sección macOS de [compilar.md](compilar.md)).

### `parche_ui_ticks.py` — el ritmo de pintado de la UI fuera de Windows

**El arreglo gordo del rendimiento en macOS.** Windows limita el ritmo de pintado de la
UI al vblank del monitor en `Presenter::WaitForUITickFromUIThread`, con señales de
DXGI; fuera de Windows esa función es un no-op (todo el cuerpo está bajo
`#if REX_PLATFORM_WIN32`).

Eso solo importa porque hay algo que pide repintados sin parar: `ImGuiDrawer::Draw`
llama a `RequestUIPaintFromUIThread` en cada fotograma mientras haya cualquier diálogo
registrado, y `ReXApp::LaunchModule` registra siempre el toast de logros —aunque no
haya logros que mostrar—. Medido en un M1 con el juego en el modo demostración:

- ~200 pintados de UI por segundo, 4.8 ms cada uno: el hilo de UI al 100%.
- El refresh del guest (`RefreshGuestOutput`, el swap del juego) esperaba 30-43 ms por
  fotograma.
- El juego a ~15 fps con la GPU al 60-70%: no limitaba la GPU, limitaba la presentación.

El parche implementa la rama no-Windows con un límite por reloj al ritmo del modo de
vídeo del guest (`video_mode_refresh_rate`, 60 Hz por defecto, el mismo valor que usa
el hilo del vblank). El present del guest no espera: `ForceUIThreadPaintTick` pone un
aviso que la espera consulta cada milisegundo, el mismo contrato que el vblank en
Windows. Con el límite puesto: refresh 7-14 ms, juego ~24 fps.

**Comprobado:** aplicar → idempotente, `--estado` 3/3, `--revertir` deja
`src/ui/presenter.cpp` con solo el hunk de `parche_fotogramas`; medido en el M1 antes y
después (los números de arriba).

### `parche_pipeline_pintado.py` — el pipeline del presentador, una vez por formato

`GuestOutputPaintPipeline::swapchain_format` se queda en `VK_FORMAT_UNDEFINED` para
siempre: nadie lo asigna. La comprobación que destruye el pipeline cuando el formato de
la swapchain cambia veía "formato cambiado" en **cada** pintado, así que destruía el
pipeline bueno y lo volvía a crear con `VK_NULL_HANDLE` de caché. En un driver nativo
es caro; en MoltenVK, cada `vkCreateGraphicsPipelines` vuelve a traducir el SPIR-V a
MSL y a crear el pipeline de Metal. Medido con `sample` en el M1: 150 de 569 muestras
del hilo de UI dentro de `CreateGuestOutputPaintPipeline` → `vkCreateGraphicsPipelines`.

El parche asigna el campo justo después de crear el pipeline; a partir de ahí se crea
una vez por formato de swapchain, como estaba pensado.

**Comprobado:** aplicar → idempotente, `--estado` 1/1, `--revertir` deja el fichero sin
diff; con el parche aplicado, el hilo de UI ya no aparece dentro de
`CreateGuestOutputPaintPipeline` en los muestreos (antes: 150 de 569 muestras).

### `parche_cvar_plugin.py` — los cvars del plugin sobreviven a la caída de backend

En macOS (y en cualquier sitio donde el backend pedido no esté compilado) la app carga
el plugin dos veces: pide `d3d12`, la fábrica devuelve `null` y vuelve a llamar con
`vulkan`. La salida temprana destruía la `DynamicLibrary` local → `dlclose` → los
destructores estáticos del plugin desregistraban sus cvars. El segundo `Load` los
registraba otra vez, pero los valores pendientes de `nfsmw.toml` y de la línea de
comandos ya se habían consumido en el primer registro y se perdían en silencio.

Medido en el M1 con `resolution_scale = 2` en el toml:

```
[temp-cvar] late registration of 'resolution_scale': pending_found=true config=2 cmdline=2
[temp-cvar] late registration of 'resolution_scale': pending_found=false config=<none> cmdline=<none>
[temp-scale] resolution_scale=1 non_default=false ... effective=1x1
```

Lo mismo valía para `anisotropic_override`, `render_target_path_d3d12` y los `vulkan_*`.
En Windows no se nota porque el plugin carga una sola vez.

El parche guarda la librería en `LoadedPlugins()` antes de devolver `null`: el segundo
`Load` reutiliza la misma imagen, no se re-ejecutan los estáticos y los valores puestos
se conservan.

**Comprobado:** aplicar → idempotente, `--estado` 1/1, `--revertir` deja el fichero sin
diff; tras reconstruir, el log muestra el aviso `Vulkan draw resolution scaling is
experimental` y `draw-scale swap sizing: ... active=2560x1440`, prueba de que la escala
del toml se respeta (antes del parche, con `resolution_scale = 2`, no aparecía ninguno
de los dos).

### `parche_sleep0.py` — sueño real en los sondeos con `Sleep(0)`

El hilo principal del juego sondea con `Sleep(0)` sin parar; `XThread::Delay` lo
convierte en `MaybeYield()` (sched_yield) para prioridades normales. Instrumentando
`Delay` en el M1: **1500-2450 sondeos por segundo consumiendo ~1000 ms de cada
segundo** —un núcleo entero—. La app ya pedía un sueño de 50 µs por sondeo
(`PonerSiNadieLoPidio("guest_sleep0_us", "50")` en `nfsmw_app.h`), pero el cvar no
existía en este SDK.

El parche añade `guest_sleep0_us` (µs, 0 = comportamiento de antes) y lo usa en la rama
de timeout 0. Con 50 µs el coste baja a ~9% de un núcleo; la latencia por sondeo es de
decenas de µs contra fotogramas de 16 ms. Con 0 el yield y el sueño de 100 µs de las
prioridades bajas quedan exactamente como estaban.

**Comprobado:** aplicar → idempotente, `--estado` 2/2, `--revertir` deja `xthread.cpp`
con solo los hunks de los parches de diagnóstico; la línea `[sdk-delay]` del muestreo
baja de ~1000 ms/s a decenas.

### `tools/diagnostico/parche_xma.py` — instrumentación pesada del XMA

**Fuera del build por defecto.** Traza por segundo del hilo de audio, cada envío y cada
silencio. Se aplica a mano para investigar y se revierte después.

---

## Por qué los parches están escritos así

No es capricho. Cada regla viene de un fallo concreto.

### Sustitución de texto exacta, sin `.original`

La primera versión guardaba una copia del fichero antes de tocarlo. Deja de funcionar en
cuanto **dos parches tocan el mismo fichero**: el segundo guarda como "original" un
fichero que ya estaba parcheado, y revertir deja el árbol en un estado que no es ni el
de antes ni el de después.

Ahora cada parche aplica y deshace por texto, y no guarda nada.

### Bloque a bloque, no un marcador por fichero

Hubo una versión con un solo marcador por fichero: si estaba, el parche se daba por
aplicado. El día que se le añadió un bloque nuevo a un parche ya aplicado, **no hizo
nada** y no dijo nada. El síntoma fue *"abrí el exe y no tenía la barra para cambiar la
velocidad"*.

Ahora cada bloque se comprueba y se aplica por separado.

### Se niegan a escribir si un anclaje no aparece exactamente una vez

Un parche a medias es peor que uno que falla. Si el SDK cambió y el anclaje ya no está,
o está dos veces, el script sale sin tocar nada.

### La regla de migración, que costó tres intentos

Cuando cambias un parche que ya estaba aplicado en algún sitio, hay que quitar la
versión vieja antes de poner la nueva. Y ahí hay dos trampas simétricas:

- **El bloque viejo es un trozo del nuevo** (se le añadió código). Buscar el viejo lo
  encuentra *dentro* del bueno, y sustituirlo por el anclaje le corta la cabeza al
  bloque recién puesto. Luego se vuelve a aplicar y la cola queda **duplicada**. El
  fichero crecía en cada pasada.
- **El bloque nuevo es un trozo del viejo** (se le quitó código). Entonces "el bloque
  bueno está" da que sí aunque lo que hay siga siendo el viejo entero, y el script se da
  por aplicado dejando dentro código muerto.

Intenté resolverlo con una *huella* por versión: un trozo que solo estuviera en esa
versión. No siempre existe: cuando el viejo es prefijo exacto del nuevo, todo lo que hay
en el viejo está también en el nuevo.

La regla que sí vale no necesita huellas:

```python
es_de_verdad_vieja = (viejo in txt) and (viejo not in nuevo or nuevo not in txt)
```

Los dos casos salen bien con eso, y se comprueba solo con los textos.

**Y se prueba corriendo el parche dos veces seguidas y comparando.** El fallo del
duplicado no se ve en la primera pasada, que es la única que se suele mirar.

### Idempotencia

Consecuencia de lo anterior, pero merece decirse aparte: ejecutar un parche N veces
tiene que dar el mismo fichero que ejecutarlo una. Si no, `CONSTRUIR.bat` corrompe el
árbol un poco más en cada reconstrucción.

### Un detalle de Windows

Los parches leen y escriben en modo texto. En Windows eso conserva los CRLF; en Linux
los convierte a LF en la primera escritura. Si comparas resultados entre plataformas,
normaliza los finales de línea antes de gritar.
