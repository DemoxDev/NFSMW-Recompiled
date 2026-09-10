# Diario técnico

Las investigaciones que costaron tiempo, escritas para que no haya que repetirlas.

Cada entrada cuenta qué decía la evidencia, no qué se suponía. Incluidas las teorías
razonables que resultaron falsas — esas son las que más ahorran, porque son las que
alguien va a volver a tener.

| Entrada | De qué va |
|---|---|
| [audio-cuelgue.md](audio-cuelgue.md) | El descodificador XMA esperándose a sí mismo. El arreglo obvio era el equivocado |
| [red-y-privilegios.md](red-y-privilegios.md) | Por qué el multijugador no funciona, con la cuenta exacta de lo que falta |

## Cómo se diagnostica aquí

El patrón que ha funcionado, en orden:

1. **Instrumentar antes que teorizar.** Los parches de diagnóstico son baratos y el log
   dice cosas que la lectura del código no.
2. **Cuidado con la propia instrumentación.** Una vez limité a una traza por segundo
   *todas* las funciones del XMA, getters y setters. Eso escondió justo lo que hacía
   falta ver y el diagnóstico se fue por el camino equivocado un buen rato.
3. **Leer el código del juego, no solo el del emulador.** `codegen.partition.json` mapea
   direcciones del guest a ficheros generados. El cuelgue del audio se resolvió ahí: la
   rareza del emulador resultó ser una señal que el juego usaba a propósito.
4. **Comparar contra una ejecución buena.** Los 43 `NtCreateFile FAILED` parecían graves
   hasta que se vio que salen idénticos en una partida que funcionó.
5. **Sospechar de la configuración antes que del código.** La "pantalla verde rota" eran
   dos interruptores de depuración en el toml.
