#!/usr/bin/env python3
"""
Unsticks the XMA voice when the game gets stuck spinning on it.

    python tools/parche_desatasco.py            apply
    python tools/parche_desatasco.py --estado
    python tools/parche_desatasco.py --revertir

Touches one SDK file:  src/kernel/xboxkrnl/xboxkrnl_audio_xma.cpp
Runs AFTER tools/parche_anillo.py, on that same file.

WARNING UP FRONT: this is a WORKAROUND, not the cure. It breaks the stall
from the outside instead of preventing it from happening. Saying this here
so it's on record.


WHAT'S ALREADY BEEN MEASURED, WITH NO GAPS
============================================

All of the game's audio runs on a SINGLE thread, 0xD. That same thread feeds
the decoder, consumes what's decoded, and mixes. Here's the end, down to the
millisecond:

  01.528  the game feeds input to voice 19
  01.679  enters the mixing loop (sub_825E1CD0) for that voice
  01.679  Work produces, write 0 -> 4
  01.700  Work produces, write 4 -> 8
  01.709  Work produces, write 8 -> 12
  01.728  Work PRODUCES NOTHING.  ent0=0 ent1=0.  Input is gone.
  01.739  ...
  01.782  ...  meanwhile the game keeps moving its read pointer through 16,
               20, 0, 4, 8: a full lap of the ring consuming what nobody
               refills anymore. It stops once it gets back to 8.
  02.119  from here on, 90 seconds of reading the two offsets and nothing
          else.

And in that same window the game DOES feed the neighboring voices -6500 and
6540- at 01.549, 01.608, 01.658, 01.698, 01.759, and 01.779. It feeds voice
19 nothing at all. It's not that it forgets: to reach the point of feeding
it, it would have to exit the mixing loop, and from there it never exits.


WHY IT DOESN'T EXIT
====================

The loop, read instruction by instruction:

  - if a voice is poorly served, it sets a flag and does NOT move on to the
    next one: it repeats that same voice endlessly
  - to know how much audio there is, it subtracts:  write*256 - its cursor
  - if that subtraction comes out to ZERO, and only then, it asks whether
    the output buffer is still valid. If told no, it interprets that as
    "buffer complete" and takes all 6144 bytes at once. That's its
    emergency exit.

During the stall the subtraction comes out to around 1000, not zero: the
game's read pointer stays ONE BLOCK short of catching up to the write
pointer. So it never gets to ask, and its emergency exit never fires. It
waits for audio that only a decoder could produce, and that decoder has
nothing to work with, fed by the very same thread that's waiting.


WHAT THIS PATCH DOES
======================

It watches for that exact situation, inside the very function the game
polls in a loop. When ALL of the following have held true at once for more
than 250 ms:

  - the game asks for the write offset of the same context over and over
  - that context has its output marked as valid
  - both of its input buffers are empty, meaning the decoder has absolutely
    nothing to produce
  - and write and read don't match, which is what keeps the game from ever
    reaching its own check

then it gives the signal that the game's own code knows how to interpret:
it sets write equal to read and turns off output_buffer_valid. In other
words, "this buffer is done". The game does its subtraction, gets zero or
negative, asks, finds out, takes what's left, and continues.

The 250 ms is plenty of margin: under normal play those checks resolve in
microseconds. The condition never triggers during normal play.

The cost is a stutter of audio on that voice, because part of what gets
taken is stale material from the ring. In exchange for not hanging.


WHY IT'S A WORKAROUND AND NOT THE CURE
=========================================

The cure would be for the decoder to never run dry mid-mix, and that means
understanding why the game arrives so tight on input. I suspect it's a
timing issue: on this machine, at 18 fps with logging maxed out, the audio
thread arrives late to refill. But suspecting isn't knowing, and I'm not
going to pass it off as if I knew.

What can be said is that it targets a situation that's IMPOSSIBLE to reach
during normal play -a thread spinning for a quarter of a second on a voice
with no input- and that if it fires, it leaves a warning in the log. If it
shows up often, the timing problem is serious and needs to be tackled head
on. If it never shows up and the game stops hanging, this was it.
"""

import argparse
import pathlib
import sys

MARCA = "PARCHE LOCAL - desatasco de la voz XMA"

ANCLA = """u32 XMAGetOutputBufferWriteOffset_entry(mapped_void context_ptr) {
  XMA_CONTEXT_DATA context(context_ptr);
"""

NUEVO = """u32 XMAGetOutputBufferWriteOffset_entry(mapped_void context_ptr) {
  XMA_CONTEXT_DATA context(context_ptr);

  // PARCHE LOCAL - desatasco de la voz XMA
  //
  // Aqui es donde el juego se queda girando cuando se cuelga: pide este
  // offset, pide el de lectura, y vuelta a empezar, para siempre.
  //
  // Se vigila un solo contexto a la vez, el ultimo que haya preguntado. No
  // hace falta mas: cuando se atasca pregunta por uno y solo por uno, asi que
  // dos enteros atomicos bastan y esto no cuesta nada en el camino normal,
  // que es lo que importa estando en un bucle tan caliente.
  {
    const uint32_t direccion = context_ptr.guest_address();
    static std::atomic<uint32_t> vigilado{0};
    static std::atomic<int64_t> desde{0};

    const int64_t ahora = std::chrono::duration_cast<std::chrono::milliseconds>(
                              std::chrono::steady_clock::now().time_since_epoch())
                              .count();

    if (vigilado.load(std::memory_order_relaxed) != direccion) {
      vigilado.store(direccion, std::memory_order_relaxed);
      desde.store(ahora, std::memory_order_relaxed);
    } else {
      const int64_t llevo = ahora - desde.load(std::memory_order_relaxed);

      // La foto exacta del atasco, y nada mas que esa:
      //   salida valida  +  las dos entradas vacias  +  offsets distintos.
      // Con las entradas vacias el descodificador no puede producir ni una
      // muestra por mucho que se le insista, asi que esperar no arregla nada.
      // Y con los offsets distintos el juego nunca llega a preguntar si el
      // buffer sigue valido, que es su unica salida.
      const bool atascado = llevo > 250 && context.output_buffer_valid &&
                            !context.input_buffer_0_valid && !context.input_buffer_1_valid &&
                            context.output_buffer_write_offset != context.output_buffer_read_offset;

      if (atascado) {
        REXAPU_WARN(
            "[desatasco] ctx={:08X} lleva {} ms girando sin entrada "
            "(escritura={} lectura={}). Le digo que el buffer esta terminado.",
            direccion, llevo, uint32_t(context.output_buffer_write_offset),
            uint32_t(context.output_buffer_read_offset));

        // Igualar los dos offsets hace que la resta del juego de cero o
        // negativo, que es lo que le empuja a preguntar; y apagar la validez
        // es la respuesta que su codigo entiende como "buffer completo".
        context.output_buffer_write_offset = context.output_buffer_read_offset;
        context.output_buffer_valid = 0;
        context.Store(context_ptr);

        // El reloj se reinicia para no repetirlo en la vuelta siguiente si el
        // juego tardara un poco en reaccionar.
        desde.store(ahora, std::memory_order_relaxed);
        return context.output_buffer_write_offset;
      }
    }
  }
"""


def localizar_sdk():
    raiz = pathlib.Path(__file__).resolve().parent.parent
    for cand in [raiz.parent / "rexglue-sdk", raiz / "sdk"]:
        if (cand / "src" / "audio" / "xma_context.cpp").exists():
            return cand
    sys.exit("[ERROR] No encuentro el SDK. Se busca en ..\\rexglue-sdk y en .\\sdk")


def main():
    p = argparse.ArgumentParser(add_help=True)
    p.add_argument("--estado", action="store_true")
    p.add_argument("--revertir", action="store_true")
    args = p.parse_args()

    f = localizar_sdk() / "src" / "kernel" / "xboxkrnl" / "xboxkrnl_audio_xma.cpp"
    if not f.exists():
        sys.exit(f"[ERROR] No encuentro {f}")

    if args.estado:
        puesto = MARCA in f.read_text(encoding="utf-8")
        print(f"  {f.name:30s} desatasco {'aplicado' if puesto else 'sin aplicar'}")
        return 0

    if args.revertir:
        # The backup of this file is made by parche_anillo.py, which is the
        # one that touches it first. Restoring it here would wipe out its
        # instrumentation, so it's handed off to the one responsible for it.
        print("  Este parche va encima de parche_anillo.py y comparte con el la")
        print("  copia de seguridad, asi que se deshace desde alli:")
        print(r"    py -3 tools\parche_anillo.py --revertir")
        print()
        print("  Y si quieres la instrumentacion pero sin el desatasco, ejecuta")
        print(r"  despues tools\parche_anillo.py otra vez.")
        return 0

    txt = f.read_text(encoding="utf-8")
    if MARCA in txt:
        print(f"[ok] {f.name}: el desatasco ya estaba puesto")
        return 0

    # This patch uses std::atomic and std::chrono, and the one that puts
    # those two headers in the file is parche_anillo.py. Without it, this
    # would fail to compile and the error would show up halfway through the
    # SDK build, which is the worst possible place to find out. Better to
    # stop it here.
    if "PARCHE LOCAL - escucha de la conversacion XMA" not in txt:
        sys.exit("[ERROR] Falta parche_anillo.py, que es quien pone las cabeceras\n"
                 "        que este necesita. Ejecutalo antes:\n"
                 "            py -3 tools\\parche_anillo.py\n"
                 "        No he tocado nada.")

    n = txt.count(ANCLA)
    if n != 1:
        sys.exit(f"[ERROR] El anclaje aparece {n} veces, esperaba 1.\n"
                 f"        Ejecuta antes tools\\parche_anillo.py. No he tocado nada.")

    f.write_text(txt.replace(ANCLA, NUEVO), encoding="utf-8")
    print(f"[ok] Desatasco puesto en {f.name}")
    print()
    print("  Si salta, dejara un aviso [desatasco] en el log.")
    print()
    print("  HAY QUE RECOMPILAR EL SDK para que sirva de algo:")
    print("    cmake --build out/build/win-amd64 --config Release --target install")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
