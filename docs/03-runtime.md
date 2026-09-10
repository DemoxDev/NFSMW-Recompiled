# Fase 3 y 4 — Runtime, stubs y el ciclo largo

Aquí es donde vive el trabajo de verdad. El codegen es un fin de semana; esto son
meses.

## Qué te da ReXGlue

El SDK trae un runtime derivado de Xenia:

- **Memory** — el mapa de memoria del guest (base `0x82000000`), heaps, protecciones
- **Kernel State & Objects** — hilos, eventos, mutex, semáforos, TLS
- **Virtual File System** — mapea las rutas del guest (`game:\`, `d:\`) a tu disco
- **ReXApp** — el marco de la aplicación host: ventana, bucle principal, presentación
- **CVar System** — variables de configuración en runtime
- **Logging** — imprescindible; súbelo a `trace` cuando algo se rompa

Lo que **tú** pones: los imports del kernel que este juego usa y que no están
implementados, los shaders, y todos los parches específicos de NFSMW.

## El ciclo

```
compilar → ejecutar → crash/hang → leer el log → identificar qué falta → implementar → repetir
```

Arranca siempre con logging alto la primera vez:

```bash
./app/build/nfsmw --log_level trace --log_file run.log
```

El primer arranque va a morir rápido. Casi siempre con algo del estilo:

```
[error] unimplemented kernel import: XamUserGetSigninState (ordinal 0x0000014B)
```

## Implementar un import que falta

Los imports no resueltos se declaran como stubs. Empieza por la versión más tonta que
deje avanzar al juego:

```cpp
// app/src/stubs/xam.cpp
uint32_t XamUserGetSigninState(uint32_t user_index) {
    // 1 = signed in locally. Suficiente para pasar el chequeo de perfil.
    return user_index == 0 ? 1 : 0;
}
```

Regla práctica: **devuelve lo mínimo que no rompa**, no lo correcto. Si el juego
consulta el estado de Xbox Live, di que no hay conexión. Si pregunta por logros,
devuelve lista vacía. Ya volverás a ello. Lo que no puedes hacer es devolver basura:
un handle inválido tratado como puntero te da un crash 40 frames después, imposible
de rastrear hasta aquí.

Marca cada stub:
```cpp
// STUB: devuelve siempre "sin conexión". Revisar si el modo carrera lo consulta.
```
y mantén un `STUBS.md` con la lista. Vas a acumular cientos.

## Mid-ASM hooks: el bisturí

Cuando necesitas intervenir en medio de una función del juego sin reescribirla —
saltarte un chequeo, forzar un valor, instrumentar — usas un hook a nivel de
instrucción:

```toml
[[midasm_hook]]
address           = 0x8214C880   # la instrucción exacta a interceptar
name              = "SkipDiscCheck"
registers         = ["r3", "r4"]
after_instruction = false
return_on_true    = true
```

```cpp
bool SkipDiscCheck(PPCRegister& r3, PPCRegister& r4) {
    if (r3.u32 == 0) { r3.u32 = 1; return true; }  // return desde la función guest
    return false;                                   // seguir normal
}
```

Usos típicos en un juego de coches:
- desactivar el chequeo de disco / DVD region
- forzar resolución o aspect ratio distintos del 720p fijo
- desbloquear el framerate (NFSMW 2005 está clavado a 30)
- saltarse la intro de EA sin tocar los assets

Los hooks son la herramienta preferida frente a parchear el binario: quedan en el
TOML, son versionables, y no distribuyes nada del juego.

## Gráficos

El juego emite microcódigo de shaders de Xenos y comandos del ring buffer. Necesitas
traducirlo. Dos caminos:

1. **XenosRecomp** (de los mismos de XenonRecomp) — recompila los shaders a HLSL/SPIR-V
   ahead-of-time. Es lo que usó Unleashed Recompiled.
2. Lo que traiga ReXGlue en su capa gráfica — revisa `Runtime Architecture Overview`
   en la wiki, que está evolucionando rápido.

Cosas específicas de NFSMW 2005 que te van a dar guerra:
- **Motion blur y bloom**: usa render targets con formatos que no tienen equivalente
  directo en D3D12/Vulkan. Vas a necesitar conversión manual.
- **EDRAM tiling**: el 360 resuelve desde EDRAM con predicated tiling. Hay que emularlo
  como render passes.
- **Reflejos del coche en tiempo real**: cubemaps dinámicos, sensibles al orden de
  comandos.

Consejo: no persigas fidelidad al principio. Un frame que dibuja *algo* reconocible ya
es un hito enorme. Primero geometría, luego texturas, luego post-proceso.

## Audio

El punto más flojo del stack. El decodificador XMA del 360 es un bloque MMIO, y tanto
XenonRecomp como ReXGlue lo tienen incompleto. Opciones:

- Usar el decodificador XMA de Xenia (código portable, hay implementaciones basadas en
  FFmpeg).
- Stub silencioso al principio: devuelve buffers en cero. El juego arranca, tú avanzas,
  y vuelves al audio cuando lo demás funcione.

NFSMW 2005 mezcla XMA (música, el soundtrack licenciado) con ADPCM y streams de motor.
Los efectos de motor son procedurales sobre samples cortos — esos suelen ser más
fáciles que la música.

## Input

`XamInputGetState` mapeado a SDL2/XInput. Es de lo más agradecido: un mando de Xbox
moderno mapea 1:1 al de 360. Suele funcionar casi a la primera.

## Assets

El juego busca sus archivos en rutas del guest. Configura el VFS para que
`game:\` apunte a la carpeta donde extrajiste el ISO:

```
assets/game_root/
├── FRONTEND/
├── CARS/
├── TRACKS/
└── SOUND/
```

Si el juego se cuelga leyendo, sube el log del VFS a `trace` y mira qué ruta exacta
pide. Casi siempre es un problema de mayúsculas (el 360 es case-insensitive, Linux no)
o de separadores `\` vs `/`.

## Hitos realistas, en orden

1. El codegen termina sin errores
2. El binario compila y enlaza
3. Arranca y llega al `main` del juego sin crashear
4. El VFS resuelve el primer archivo
5. Primer frame dibujado (aunque sea negro con un triángulo)
6. Logo de EA / pantalla de carga visible
7. Menú principal navegable con mando
8. Una carrera carga
9. Una carrera es jugable
10. Audio
11. Todo lo demás

Entre el 3 y el 5 se va la mitad del esfuerzo total. Es normal quedarse semanas ahí.

## Cómo pedir ayuda

Cuando te atores, lo útil que puedes compartir sin distribuir nada del juego:
- el `codegen.log` con el error
- las líneas relevantes del `run.log`
- el fragmento de TOML que estás intentando
- la dirección y el desensamblado de la función problemática

El Discord de hedge-dev (XenonRecomp / Unleashed Recompiled) y el repo de ReXGlue son
donde está la gente que sabe.
