# Compilar desde cero

De un clon limpio a una carpeta jugable.

## Lo que hace falta

| Cosa | Por qué |
|---|---|
| Windows 10 u 11 x64 | El backend gráfico es Direct3D 12 |
| Visual Studio 2022 Build Tools | MSVC y el SDK de Windows. No hace falta el IDE |
| CMake 3.28+ y Ninja | El SDK y la aplicación usan presets |
| Clang 20+ | El C++ generado no compila con MSVC |
| Python 3.10+ | Los parches y las herramientas |
| El SDK ReXGlue | Se clona al lado, en `..\rexglue-sdk` |
| Tu propia ISO o dump GOD | El juego. No está aquí ni lo va a estar |

Detalle de la instalación del entorno en [00-entorno.md](00-entorno.md).

## La estructura que se espera

Los scripts buscan el SDK **al lado** del proyecto, no dentro:

```
Documents\
├── NFSMW Recompiled\     ← este repositorio
└── rexglue-sdk\          ← el SDK, clonado aparte
```

Si lo tienes en otro sitio, los parches también miran en `.\sdk`.

## Los pasos

### 1. El SDK

```powershell
.\tools\bootstrap.ps1
```

Comprueba los prerrequisitos, clona el SDK en `..\rexglue-sdk` y lo compila e instala.

### 2. Tu `default.xex`

```bat
EXTRAER_XEX.bat
```

Saca el `default.xex` de tu ISO y lo deja en `assets\`. Esa carpeta está en
`.gitignore` y ahí se queda.

Detalle y alternativas (GOD, XContent) en
[01-extraccion-xex.md](01-extraccion-xex.md).

### 3. Compilar

```bat
CONSTRUIR.bat
```

Esto es todo. Por dentro hace cinco fases:

1. **Parches del SDK.** Aplica los nueve parches del proyecto sobre `..\rexglue-sdk`.
   El orden importa: `parche_anillo` va antes que `parche_desatasco`.
2. **Recompilar el SDK.** Aquí es donde acaban los arreglos, dentro de
   `rexruntime.dll`. Se configura con Vulkan encendido para que el selector de API
   tenga dos opciones de verdad.
3. **Generar y compilar el juego.** Dos pasadas de ninja, y no es capricho: ver abajo.
4. **Armar `build\`.** Copia el ejecutable, las DLL y los ficheros de apoyo, y borra
   los restos de ejecuciones anteriores. Después construye el lanzador y le cambia el
   nombre al juego.
5. **Comprobar que la carpeta es autónoma.** Lee la tabla de importaciones PE de cada
   binario y sigue las dependencias en cadena, para asegurarse de que no falta ninguna
   DLL.

Y al terminar arma las carpetas de reparto en `..\build release\`, para que no haya
que acordarse de un paso a mano. Antes esto era "comprime `build\` sin la ISO", y ese
paso tenía una trampa: la ISO son varios GB y es fácil mandarla sin querer.

- `NFSMW Windows x64\` — jugable, con el ejecutable dentro. Se comprime y se manda a
  alguien que tenga su propia copia. **No se publica.**
- `NFSMW Windows x64 - Portable\` — todo menos el juego. Esta sí.

Tarda bastante la primera vez: son 131 ficheros de C++ generado, más de un millón de
líneas.

### 4. Jugar

Copia tu ISO dentro de `build\` y abre `build\NFS_Most_Wanted.exe`.

Ese es **el lanzador**, con el icono del juego. El juego de verdad es `nfsmw.exe`.
El intercambio de nombres es para que al hacer doble clic en el icono salga la ventana
de opciones; ver [lanzador.md](lanzador.md).

Si llamas a tu ISO `nfsmw.iso` será la preferida cuando haya varias.

## Por qué dos pasadas de compilación

El generador reescribe `generated\default\nfsmw_pch.h`, y de esa cabecera sale la
precompilada que usan los 131 ficheros generados.

En una sola pasada, ninja decide al arrancar qué ficheros están sucios. En ese momento
`nfsmw_pch.h` todavía no ha cambiado, así que da la precompilada por buena. Luego, ya
dentro de la misma pasada, el generador la cambia. Cuando le toca el turno a los `.cpp`,
clang compara y aborta:

```
fatal error: file 'nfsmw_pch.h' has been modified since the precompiled header was
built: size changed (was 18553, now 18522)
```

Lanzando el generador primero y por separado, la segunda pasada arranca con las
cabeceras ya definitivas.

## Cuando algo falla

### El SDK no enlaza

Lo más probable es que un parche esté a medias. Mira el estado:

```bat
for %f in (tools\parche_*.py) do python %f --estado
```

Y si hace falta, revierte todos y vuelve a empezar:

```bat
for %f in (tools\parche_*.py) do python %f --revertir
```

### Un parche dice que el anclaje no aparece una sola vez

El SDK ha cambiado respecto a lo que el parche espera. El script no ha tocado nada. Hay
que mirar el bloque a mano y actualizar el parche; ver [parches.md](parches.md).

### `RC` y `vcvars64`

En los `.bat` de este proyecto los códigos de retorno van siempre en una variable
llamada `SALIDA`, **nunca** `RC`. `vcvars64` pone `RC` con la ruta del compilador de
recursos y CMake la lee al detectar el toolchain. Usar `RC` para otra cosa rompe la
configuración de forma difícil de ver.

### El juego arranca pero se ve mal

Antes de sospechar del código, mira `build\nfsmw.toml`. Los ajustes que se guardan desde
el menú de F4 acaban ahí, y hay dos de depuración que destrozan el render sin dar
errores. Ver [problemas-conocidos.md](problemas-conocidos.md).

### Sin espacio o sin paciencia

El árbol generado ocupa varios GB. `app\generated\` se puede borrar entero: se rehace.

## Compilar solo el lanzador

```bat
CONSTRUIR_LANZADOR.bat
```

Usa el `csc.exe` que ya trae Windows dentro de `C:\Windows\Microsoft.NET\`. No hace
falta instalar nada. Ver [lanzador.md](lanzador.md).

## Recompilar tras tocar un parche

No hace falta rehacer el juego: los parches solo tocan el SDK.

```bat
python tools\parche_loquesea.py
cd ..\rexglue-sdk
cmake --build out/build/win-amd64 --config Release --target install
```

Y copiar la `rexruntime.dll` nueva a `build\`. `CONSTRUIR.bat` hace todo eso, pero si
solo cambiaste un parche, esto es mucho más rápido.
