# Problemas conocidos

Lo que está roto, y hasta dónde se llegó investigando cada cosa. Un problema con el
diagnóstico a medias vale más que uno sin empezar.

## Abiertos

### Vulkan renderiza en negro (Intel)

**Estado:** reproducible, sin diagnosticar.

El backend de Vulkan está entero en el SDK y compila. Se carga bien —tan bien que el
respaldo automático no salta, porque ese solo entra cuando la API ni siquiera existe en
la copia— y la pantalla sale negra.

Lo siguiente sería mirar el log de esa ejecución con `--log_level=debug` a ver qué dice
antes de quedarse en negro. No se ha hecho.

Mientras tanto: el lanzador siempre pasa `--gpu_backend`, así que elegir mal aquí nunca
deja el juego sin poder abrirse. Vuelves al lanzador y marcas DirectX 12.

### Franja horizontal con el camino RTV

**Estado:** visto, no acotado.

En algunas gráficas integradas el camino rápido de la EDRAM deja una franja horizontal
rara. Como cuesta la mitad de los fps, merece la pena investigarlo antes que renunciar.

Sin comprobar todavía: si depende de la versión del driver de Intel, y si se reproduce en
otras integradas o solo en la Iris 540.

### Multijugador

**Estado:** diagnosticado a fondo, sin implementar.

La puerta de los privilegios está resuelta. Debajo faltan 114 de 158 funciones de red,
incluidas las del System Link, y los manejadores de sesión son stubs que devuelven éxito
sin hacer nada.

El detalle completo, con la tabla de qué falta, está en
[diario/red-y-privilegios.md](diario/red-y-privilegios.md).

### Pocos núcleos

El SDK avisa en el arranque:

```
Too few processor cores - scheduling will be wonky
```

No es decorativo. En máquinas con pocos núcleos el hilo de audio compite peor y el
atasco del XMA es más probable. Si en el log salen muchas líneas `[desatasco]`, es por
aquí.

## Resueltos, documentados por si vuelven

### El audio se moría y el juego se congelaba

Arreglado por `parche_desatasco.py`. La historia completa, incluido el arreglo que
parecía obvio y estaba mal, en [diario/audio-cuelgue.md](diario/audio-cuelgue.md).

### Pantalla verde rota que parecía un fallo del backend

**No era el código.** Eran dos interruptores de depuración que se habían colado en
`nfsmw.toml` desde el menú de F4:

```toml
d3d12_tessellation_wireframe = true
native_stencil_value_output_d3d12_intel = true
```

El primero dibuja en alambre la geometría teselada. El segundo fuerza la salida nativa de
stencil **en Intel**, que es justo el caso que el SDK excluye a propósito. Con el camino
RTV destroza el render sin dar un solo error de GPU.

**Lección: si de repente se ve mal, mira el toml antes de sospechar del código.**

### `NtCreateFile FAILED` en el log

43 avisos de ficheros del juego que no se abren, con `0xc000000f`. **Es normal.** El
juego tantea ficheros que en este disco no existen. Se confirmó comparando con una
ejecución larga que llegó hasta el final: salen exactamente los mismos 43.

No perseguir esto.

### El aviso permanente de "hace falta reiniciar"

El menú de F4 abría siempre diciendo `Restart needed to apply: gpu_backend`, aunque no
hubieras tocado nada.

`SetFlagFromSource` apunta en la lista de pendientes cualquier cvar `kRequiresRestart`
que se toque, sin mirar de dónde viene el valor. Como el lanzador pasa `--gpu_backend`
siempre, entraba en la lista pese a estar ya aplicado. Un aviso que no se puede quitar
deja de leerse, y entonces tampoco se lee cuando es real.

`parche_backend.py` limpia la lista cuando termina el arranque.

### Subir la resolución no cambiaba nada

No era un fallo: eran dos controles distintos con nombres parecidos. `--resolution` solo
agranda la imagen; el que la hace más fina es `--resolution_scale`. El lanzador ahora los
llama "Tamaño de la ventana" y "Resolución interna", y enseña qué hace la escala elegida.

Ver [rendimiento.md](rendimiento.md).

## Cosas que conviene no volver a intentar

**Reservar un bloque en el anillo del XMA** para desambiguar lleno/vacío. Parece el
arreglo de libro y es incorrecto: `output_buffer_valid = 0` con el anillo lleno es la
señal que el juego usa para saber que el buffer terminó. Quitársela le quita su única
salida.

**Buscar un backend de DirectX 11.** No existe en este SDK y no es un olvido: la
emulación de la Xenos se apoya en cosas de la generación de DX12 —los rasterizer ordered
views, los descriptores sin límite, las escrituras tipadas desde shaders para el
memexport—. Un backend de DX11 no es un ajuste, es rehacer el plugin de GPU. Y no
arreglaría nada: el cuello está en la GPU al 100%, y la API no cambia cuántos píxeles hay
que sombrear.

**Perseguir los servidores de EA.** Están apagados. La única vía para el multijugador es
System Link.
