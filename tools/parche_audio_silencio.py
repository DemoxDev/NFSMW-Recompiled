#!/usr/bin/env python3
"""
Audio silencioso cuando no hay dispositivo, en vez de morir.

    python tools/parche_audio_silencio.py            aplicar
    python tools/parche_audio_silencio.py --estado
    python tools/parche_audio_silencio.py --revertir

Touches three SDK files:
    include/rex/audio/sdl/sdl_audio_driver.h
    src/audio/sdl/sdl_audio_driver.cpp
    src/audio/sdl/sdl_audio_system.cpp

Applies and undoes by exact text substitution, block by block; no .original.


WHY THIS WAS NEEDED
=======================

El juego no sobrevive a un fallo de inicializacion de audio. Medido en un M1:
tras dormir el Mac, CoreAudio se quedo atascado (AudioQueueStart -66681, con
afplay fallando igual, o sea un problema del sistema, no del juego), y el
juego murio con

    [error] [apu] SDL_OpenAudioDeviceStream() failed: CoreAudio error ...
    [error] [sys] Unhandled guest access violation: read of guest 0x00000014
                  on thread 0xF800002C

Es decir: XAudioRegisterRenderDriverClient devuelve error, el juego no lo
comprueba y desreferencia un puntero nulo. No se puede arreglar el codigo del
juego (viene del XEX), asi que lo que se arregla es la causa: que el registro
del cliente no falle nunca.

QUE HACE ESTE PARCHE
=======================

Si el driver de SDL no consigue abrir el dispositivo (InitSubSystem,
OpenAudioDeviceStream, GetAudioStreamDevice o ResumeAudioDevice fallan),
CreateDriver ya no devuelve error: llama a InitializeSilent() y le da al juego
un driver que consume los fotogramas al ritmo real del dispositivo (256
muestras a 48 kHz) y los descarta. El hilo de audio del juego sigue avanzando
-el semaforo se suelta una vez por fotograma, como con el dispositivo real-
solo que no suena nada. Se avisa en el log con una linea.

El consumo lo hace un hilo propio, no SubmitFrame: SubmitFrame corre con el
cerrojo global del audio cogido (AudioSystem::SubmitFrame), asi que dormir
ahi dentro bloquea a cualquier otro hilo que toque el audio y el juego cae a
~10 fps. El hilo de ritmo solo toca la cola del driver, igual que el callback
de SDL. Al apagar el driver se para y se une.

Con dispositivo, el camino es exactamente el de antes: Initialize() no cambia.
"""

import argparse
import pathlib
import sys

# ---------------------------------------------------------------------------
#  1) Declarations in the header
# ---------------------------------------------------------------------------

CAB_ANCLA = """#pragma once

#include <mutex>
#include <queue>
#include <stack>
"""

CAB_NUEVO = """#pragma once

#include <atomic>  // PARCHE LOCAL - audio silencioso si no hay dispositivo
#include <mutex>
#include <queue>
#include <stack>
#include <thread>  // PARCHE LOCAL - audio silencioso si no hay dispositivo
"""

DECL_ANCLA = """  bool Initialize();
  void SubmitFrame(uint32_t frame_ptr) override;
  void Shutdown();
"""

DECL_NUEVO = """  bool Initialize();
  // PARCHE LOCAL - audio silencioso si no hay dispositivo
  bool InitializeSilent();
  void SubmitFrame(uint32_t frame_ptr) override;
  void Shutdown();
"""

MIEMBRO_ANCLA = """  SDL_AudioStream* sdl_stream_ = nullptr;
  bool sdl_initialized_ = false;
  uint8_t sdl_device_channels_ = 0;
"""

MIEMBRO_NUEVO = """  SDL_AudioStream* sdl_stream_ = nullptr;
  bool sdl_initialized_ = false;
  uint8_t sdl_device_channels_ = 0;

  // PARCHE LOCAL - audio silencioso si no hay dispositivo
  //
  // Sin dispositivo, este hilo hace el papel del callback de SDL: saca un
  // fotograma de la cola al ritmo real (256 muestras a 48 kHz) y suelta el
  // semaforo. No duerme SubmitFrame, que corre con el cerrojo global del
  // audio cogido y bloquearia al resto de hilos que lo tocan.
  bool silent_ = false;
  std::atomic<bool> silent_thread_running_{false};
  std::thread silent_thread_;
"""

# ---------------------------------------------------------------------------
#  2) The silent implementation and its pacing thread
# ---------------------------------------------------------------------------

DRIVER_ANCLA = """void SDLAudioDriver::SubmitFrame(uint32_t frame_ptr) {
  const auto input_frame = memory_->TranslateVirtual<float*>(frame_ptr);
"""

DRIVER_NUEVO = """bool SDLAudioDriver::InitializeSilent() {
  // PARCHE LOCAL - audio silencioso si no hay dispositivo
  silent_ = true;
  silent_thread_running_.store(true, std::memory_order_relaxed);
  silent_thread_ = std::thread([this] {
    const auto frame_duration = std::chrono::microseconds(
        uint64_t(channel_samples_) * 1000000 / frame_frequency_);
    while (silent_thread_running_.load(std::memory_order_relaxed)) {
      rex::thread::Sleep(frame_duration);
      std::unique_lock<std::mutex> guard(frames_mutex_);
      if (frames_queued_.empty()) {
        continue;
      }
      frames_unused_.push(frames_queued_.front());
      frames_queued_.pop();
      auto ret = semaphore_->Release(1, nullptr);
      assert_true(ret);
    }
  });
  return true;
}

void SDLAudioDriver::SubmitFrame(uint32_t frame_ptr) {
  const auto input_frame = memory_->TranslateVirtual<float*>(frame_ptr);
"""

# ---------------------------------------------------------------------------
#  3) Stop the pacing thread on shutdown
# ---------------------------------------------------------------------------

PARADA_ANCLA = """void SDLAudioDriver::Shutdown() {
  if (sdl_stream_) {
"""

PARADA_NUEVO = """void SDLAudioDriver::Shutdown() {
  // PARCHE LOCAL - audio silencioso si no hay dispositivo
  silent_thread_running_.store(false, std::memory_order_relaxed);
  if (silent_thread_.joinable()) {
    silent_thread_.join();
  }
  if (sdl_stream_) {
"""

# ---------------------------------------------------------------------------
#  3) The fallback where the error used to be returned
# ---------------------------------------------------------------------------

SISTEMA_ANCLA = """  auto driver = new SDLAudioDriver(memory_, semaphore);
  if (!driver->Initialize()) {
    driver->Shutdown();
    delete driver;
    return X_STATUS_UNSUCCESSFUL;
  }

  *out_driver = driver;
  return X_STATUS_SUCCESS;
"""

SISTEMA_NUEVO = """  auto driver = new SDLAudioDriver(memory_, semaphore);
  if (!driver->Initialize()) {
    driver->Shutdown();
    // PARCHE LOCAL - audio silencioso si no hay dispositivo
    //
    // El juego no sobrevive a un fallo de inicializacion de audio: si
    // XAudioRegisterRenderDriverClient falla, revienta con una violacion de
    // acceso en el hilo principal (medido: CoreAudio atascado tras dormir el
    // Mac, AudioQueueStart -66681). En vez de devolver error, se le da un
    // driver que consume los fotogramas al ritmo del dispositivo y los
    // descarta: el juego corre sin sonido en lugar de morir.
    if (!driver->InitializeSilent()) {
      delete driver;
      return X_STATUS_UNSUCCESSFUL;
    }
    REXAPU_WARN(
        "Audio device unavailable; continuing with silent audio (no sound, the "
        "game keeps running)");
  }

  *out_driver = driver;
  return X_STATUS_SUCCESS;
"""

# (indice de fichero, nombre, ancla, nuevo). El indice apunta a FICHEROS, no a
# bloques: los dos bloques del .h comparten el mismo buffer de texto, o el
# segundo se aplicaria sobre una copia vieja y se perderia al escribir.
BLOQUES = [
    (0, "cabeceras (sdl_audio_driver.h)", CAB_ANCLA, CAB_NUEVO),
    (0, "declaracion (sdl_audio_driver.h)", DECL_ANCLA, DECL_NUEVO),
    (0, "miembro (sdl_audio_driver.h)", MIEMBRO_ANCLA, MIEMBRO_NUEVO),
    (1, "driver silencioso (sdl_audio_driver.cpp)", DRIVER_ANCLA, DRIVER_NUEVO),
    (1, "parada del hilo (sdl_audio_driver.cpp)", PARADA_ANCLA, PARADA_NUEVO),
    (2, "respaldo (sdl_audio_system.cpp)", SISTEMA_ANCLA, SISTEMA_NUEVO),
]


def localizar_sdk():
    raiz = pathlib.Path(__file__).resolve().parent.parent
    for cand in [raiz.parent / "rexglue-sdk", raiz / "sdk"]:
        h = cand / "include" / "rex" / "audio" / "sdl" / "sdl_audio_driver.h"
        c = cand / "src" / "audio" / "sdl" / "sdl_audio_driver.cpp"
        s = cand / "src" / "audio" / "sdl" / "sdl_audio_system.cpp"
        if h.exists() and c.exists() and s.exists():
            return h, c, s
    sys.exit("[ERROR] No encuentro el driver de audio SDL del SDK.\n"
             "        Se busca en ..\\rexglue-sdk y en .\\sdk")


def main():
    p = argparse.ArgumentParser(add_help=True)
    p.add_argument("--estado", action="store_true")
    p.add_argument("--revertir", action="store_true")
    args = p.parse_args()

    h, c, s = localizar_sdk()
    ficheros = [h, c, s]
    textos = [f.read_text(encoding="utf-8") for f in ficheros]

    if args.estado:
        puestos = sum(1 for i, _, _, nuevo in BLOQUES if nuevo in textos[i])
        print(f"  audio SDL                {puestos} de {len(BLOQUES)} bloques aplicados")
        for i, nombre, _, nuevo in BLOQUES:
            print(f"      {'si' if nuevo in textos[i] else 'NO':>2}  {nombre}")
        return 0

    if args.revertir:
        quitados = 0
        for i, nombre, ancla, nuevo in BLOQUES:
            if nuevo not in textos[i]:
                continue
            if textos[i].count(nuevo) != 1:
                sys.exit(f"[ERROR] El bloque '{nombre}' aparece {textos[i].count(nuevo)} veces.\n"
                         f"        No lo toco, quitalo tu.")
            textos[i] = textos[i].replace(nuevo, ancla)
            quitados += 1
        if not quitados:
            print("[ok] audio SDL: no habia nada puesto")
            return 0
        for f, txt in zip(ficheros, textos):
            f.write_text(txt, encoding="utf-8")
        print(f"[ok] Quitados {quitados} bloques del driver de audio")
        print()
        print("  HAY QUE RECOMPILAR EL SDK.")
        return 0

    faltan = [(i, n, a, v) for i, n, a, v in BLOQUES if v not in textos[i]]
    if not faltan:
        print(f"[ok] audio SDL: los {len(BLOQUES)} bloques ya estaban")
        return 0

    for i, nombre, ancla, _ in faltan:
        n = textos[i].count(ancla)
        if n != 1:
            sys.exit(f"[ERROR] El anclaje de '{nombre}' aparece {n} veces, esperaba 1.\n"
                     f"        El SDK habra cambiado. No he tocado nada.")

    for i, nombre, ancla, nuevo in faltan:
        textos[i] = textos[i].replace(ancla, nuevo)
        print(f"[ok] Aplicado: {nombre}")
    for f, txt in zip(ficheros, textos):
        f.write_text(txt, encoding="utf-8")
    print()
    print("  Sin dispositivo de audio el juego corre en silencio en vez de")
    print("  morir con una violacion de acceso.")
    print()
    print("  HAY QUE RECOMPILAR EL SDK para que sirva de algo:")
    print("    cmake --build out/build/mac-arm64 --config Release --target install")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
