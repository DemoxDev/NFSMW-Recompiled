# Rendimiento

Lo medido, no lo supuesto. La máquina de referencia es modesta a propósito: si algo se
nota ahí, se nota en cualquier sitio.

**Equipo de referencia:** Intel Iris 540 (integrada, vendor 0x8086, device 0x1926),
pocos núcleos. El SDK avisa en el arranque: `Too few processor cores - scheduling will
be wonky`.

Lo que la GPU reporta y que condiciona lo demás:

```
Max GPU virtual address bits per resource: 38
Rasterizer-ordered views: yes
Resource binding: tier 3
Tiled resources: tier 3
Pixel-shader-specified stencil reference: yes
```

## Lo que más cambia: el camino de la EDRAM

| Camino | Qué hace | FPS medidos |
|---|---|---|
| ROV | Rasterizer ordered views. Exacto | ~10 |
| RTV | Render targets del host. Aproximado | ~18 |

Casi el doble. El SDK elige ROV en Intel por defecto, que es la decisión conservadora;
`render_target_path_d3d12 = "rtv"` se la salta.

**El coste:** en algunas integradas el camino rápido deja una franja horizontal rara.
Está sin cerrar del todo — ver [problemas-conocidos.md](problemas-conocidos.md).

Este ajuste es `kInitOnly`: se decide al arrancar y no se puede tocar desde F4. El
lanzador lo pasa por línea de comandos.

## Resolución interna

`--resolution_scale` es el "x2" de los emuladores: multiplica el tamaño de los render
targets y de la EDRAM emulada, así que el juego dibuja de verdad más píxeles.

Crece con el cuadrado: x2 son **cuatro** veces los píxeles. Partiendo de 18–38 fps a x1,
en esta máquina x2 no es jugable.

Lo que sí conviene saber es que **no se va a recortar por falta de capacidad**. El SDK
lo limita en dos casos:

- si la GPU está por debajo de *tiled resources tier 1* — aquí es tier 3
- si el espacio de direcciones no llega: `kBufferSize × escala²` tiene que caber en los
  bits por recurso. Con 38 bits y un buffer de 512 MB, a x2 hacen falta 31. Sobra
  muchísimo.

Si el SDK llega a recortarla, lo dice:

```
The requested draw resolution scale is not supported by the device or the emulator,
reducing to NxN
```

No confundir con `--resolution`, que solo cambia el tamaño de la ventana y del modo de
vídeo del guest. Ver [arquitectura.md](arquitectura.md).

## Ajustes que cuestan y a veces no se ven

### `readback_resolve`

Por defecto `none`. El valor `fast` copia de GPU a CPU **en cada fotograma**.

Lo pone la propia aplicación (`nfsmw_app.h`) porque sin él la imagen sale lavada y el sol
reventado. O sea: es un arreglo visual, no una preferencia, y su coste es el precio de
que se vea bien.

### `native_stencil_value_output_d3d12_intel`

**Dejar apagado en Intel.** El SDK excluye esta ruta en Intel a propósito:

```cpp
use_stencil_reference_output_ =
    REXCVAR_GET(native_stencil_value_output) &&
    provider.IsPSSpecifiedStencilReferenceSupported() &&
    (REXCVAR_GET(native_stencil_value_output_d3d12_intel) ||
     provider.GetAdapterVendorID() != kIntel);
```

Encenderlo fuerza esa salida en Intel, que es justo el caso excluido. Con el camino RTV
destroza el render **sin dar un solo error de GPU**, lo cual lo hace especialmente
difícil de diagnosticar.

### `d3d12_tessellation_wireframe`

Interruptor de depuración: dibuja en alambre toda la geometría teselada. No tocarlo salvo
para depurar.

Estos dos últimos se colaron una vez en el `nfsmw.toml` desde el menú de F4 y produjeron
una pantalla verde rota que parecía un fallo del backend gráfico. **Si de repente se ve
mal, mira el toml antes de sospechar del código.**

## Fotogramas

Ni el vsync ni el límite de fps funcionan de fábrica: `parche_presentador.py` los
implementa. Ver [parches.md](parches.md).

Un detalle que sorprende: **limitar los fps no ralentiza el juego.** El parpadeo vertical
del guest lo genera un hilo aparte contra el reloj de pared, a `video_mode.refresh_rate`
(60 Hz), independiente del ritmo de dibujado. Si quieres cambiar la velocidad del juego,
eso es `game_speed`, otro ajuste distinto.

## La caché de shaders

Vive en `%USERPROFILE%\Documents\nfsmw\cache`, **fuera** de la carpeta portable. Sale de
`GetUserFolder() / GetName()`, y `GetName()` está en el código, así que renombrar el
ejecutable no la mueve.

Dos consecuencias:

- Rehacer `build\` no la borra. El primer arranque tras una build nueva sigue siendo
  rápido.
- Si sospechas que la caché está corrupta tras cambiar de backend, hay que borrarla a
  mano.

En un arranque normal se ven líneas como `Translated 85 shaders from the storage` y
`Created 258 graphics pipelines ... from the storage`.

## Método

Los números de arriba salieron de comparar ejecuciones cambiando **una** cosa cada vez y
mirando el contador de F3. Es tosco pero suficiente para diferencias del 80%.

Para diferencias pequeñas no vale: la variabilidad entre ejecuciones en una integrada con
pocos núcleos se come cualquier mejora de un dígito.
