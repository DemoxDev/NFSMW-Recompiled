# El cuelgue del audio

El fallo más difícil del proyecto, y el que mejor enseña cómo se diagnostica aquí.

**Síntoma:** después del prólogo, al salir del garaje el audio se moría. Y al volver al
menú, el juego se congelaba entero.

## Lo que resultó ser

Todo el audio de Most Wanted lo lleva **un solo hilo del guest** (el `0xD`). Ese mismo
hilo hace tres cosas:

1. alimenta al descodificador XMA con datos comprimidos
2. consume lo que sale
3. mezcla las voces

El atasco: cuando ese hilo entra a mezclar una voz que se acaba de quedar sin datos, se
pone a esperar audio que solo podría producir el descodificador. Y al descodificador
tendría que alimentarlo él, en cuanto saliera de ahí. No sale. Se espera a sí mismo.

## El arreglo

El propio juego tiene una salida de emergencia. Se ve en su código recompilado: cuando
su lectura alcanza a la escritura, pregunta si el buffer sigue siendo válido
(`XMAIsOutputBufferValid`), y si le dicen que no, lo da por terminado y sigue.

En el atasco se queda a **un bloque** de alcanzarla, así que nunca llega a preguntar.

`parche_desatasco.py` le da esa señal cuando lleva más de 250 ms girando sobre una voz
sin entrada:

```cpp
const bool atascado = llevo > 250 && context.output_buffer_valid &&
                      !context.input_buffer_0_valid && !context.input_buffer_1_valid &&
                      context.output_buffer_write_offset != context.output_buffer_read_offset;
if (atascado) {
  context.output_buffer_write_offset = context.output_buffer_read_offset;
  context.output_buffer_valid = 0;
  context.Store(context_ptr);
  return context.output_buffer_write_offset;
}
```

Es un apaño deliberado: rompe el atasco en vez de evitarlo. Puede costar un tropiezo de
audio en esa voz. Si en el log salen muchas líneas `[desatasco]`, significa que el hilo
de audio va justo de tiempo en esa máquina y hay que ir a por eso, no por el síntoma.

## El intento equivocado, que es la parte útil

Antes de esto probé otra cosa: reservar un bloque en el buffer circular para que
`read == write` solo pudiera significar "vacío" y nunca "lleno". Es el arreglo de libro
para un buffer circular ambiguo.

**Estaba mal, y lo estaba por una razón que no se ve desde fuera del juego.**

Leyendo el código recompilado del propio juego se ve que `output_buffer_valid = 0` con
el anillo lleno **no es un bug: es la señal que el hardware le da al juego** para decir
"buffer completo". El juego la lee y actúa en consecuencia. Al "arreglarlo" le estaba
quitando la única salida que tenía.

Se revirtió entero.

La lección: en una recompilación, el comportamiento raro del emulador puede ser
exactamente lo que el juego espera. Antes de arreglar una rareza, mira si el juego la
está usando.

## Cómo se llegó ahí

El camino, porque el método vale más que el resultado:

1. **Instrumentar el kernel del XMA** (`parche_anillo.py`) para ver cada llamada.
2. **Un fallo del propio diagnóstico:** limité a una traza por segundo *todas* las
   funciones, getters y setters. Eso escondió justo lo que hacía falta ver —las entregas
   de entrada— y estuve un rato mirando en la dirección equivocada. Al dejar los setters
   sin límite apareció el patrón.
3. **Ver que no se producía nada**: se añadió una traza explícita para el caso "el
   contexto giró y no produjo ni una muestra", con el estado completo. Ahí quedó claro
   que era un contexto sin entrada, dando vueltas.
4. **Leer el código del juego**, no solo el del emulador. `codegen.partition.json` mapea
   direcciones del guest a ficheros generados; con eso se encuentra la función que
   pregunta por el buffer y se ve qué hace con la respuesta.

El paso 4 es el que resolvió el caso. Los tres primeros solo acotaron dónde mirar.

## Qué mirar si vuelve

En el log:

- Líneas `[desatasco]`: cuántas y cada cuánto. Ninguna y el juego aguanta = era esto.
  Muchas = el hilo de audio va justo en esa máquina.
- `XmaContext {}: NO PRODUJO NADA` con la instrumentación pesada puesta
  (`tools/diagnostico/parche_xma.py`): dice qué contexto, con qué entradas y en qué
  posición del anillo.

Y el aviso `Too few processor cores - scheduling will be wonky` en el arranque no es
decorativo: en máquinas con pocos núcleos el hilo de audio compite peor y el atasco es
más probable.
