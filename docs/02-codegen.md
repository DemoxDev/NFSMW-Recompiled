# Fase 2 — De PowerPC a C++

## Crear el proyecto

Desde la raíz de `NFSMW Recomp/`:

```bash
rexglue init --app_name "nfsmw" --app_root ./app --app_desc "NFS Most Wanted (2005) recompiled" --app_author "tu-nombre"
```

Esto genera en `app/`:
- `CMakeLists.txt` — el proyecto de la app
- `src/main.cpp` — punto de entrada del host
- `nfsmw_config.toml` — la config de codegen
- plantillas de stubs y hooks

Mueve o enlaza esa config a `config/nfsmw_config.toml` si prefieres tenerla junto al
resto (o simplemente edita la que generó `init`; lo importante es que haya **una sola**).

## La config mínima

```toml
project_name        = "nfsmw"
file_path           = "../assets/default.xex"
out_directory_path  = "generated"

# Si tienes title update:
# patch_file_path    = "../assets/patch.xexp"
# patched_file_path  = "../assets/default_patched.xex"
```

Ver `config/nfsmw_config.toml` en este repo: ya viene con todas las opciones
comentadas y explicadas.

## Primera pasada de codegen

```bash
cmake --build --preset win-amd64-debug --target nfsmw_codegen
# o en Linux:
cmake --build --preset linux-amd64-debug --target nfsmw_codegen
```

También se puede invocar directo:
```bash
rexglue codegen config/nfsmw_config.toml --log_level debug --log_file codegen.log
```

Lo que hace: carga el XEX, lo desencripta/descomprime, recorre el `.text` descubriendo
límites de funciones, resuelve tablas de saltos, y escribe C++ en `generated/`.

**La primera pasada casi nunca sale limpia.** Espera warnings y errores. Eso es normal
y esperado — el ciclo de fase 2 es exactamente resolverlos.

## Los tres problemas clásicos

### 1. `bctr` sin tabla resuelta

```
warning: unresolved jump table at 0x8210A4C0 (bctr)
```

El análisis no dedujo a dónde salta un `bctr`. Hay que declararlo a mano. Abre esa
dirección en Ghidra/IDA, mira qué registro carga el índice y dónde está la tabla de
labels, y añade:

```toml
[[switch_tables]]
address  = 0x8210A4C0   # la dirección del bctr
register = 11           # el GPR con el índice (rN)
labels   = [0x8210A4D0, 0x8210A520, 0x8210A5A0]  # los destinos, en orden
```

Los `labels` van en el orden exacto del índice: `labels[0]` es a donde salta con
índice 0. Sacarlos mal produce crashes silenciosos y difíciles, así que verifica dos
veces contra el desensamblado.

### 2. Datos dentro de `.text`

```
warning: invalid instruction at 0x8230F118
```

El compilador de EA intercala constantes (tablas de floats, strings, vtables) entre
código. Si son pocas, ajusta el umbral:

```toml
[analysis]
data_region_threshold = 8   # menos instrucciones inválidas seguidas para cortar
```

Si hay un patrón repetido concreto:
```toml
[[invalid_instructions]]
data = 0x00000000
size = 16
```

### 3. Límites de función mal detectados

Cuando una función tiene una jump table dentro, el analizador se pasa de largo o se
queda corto. Se declara explícito:

```toml
[functions]
0x8210A400 = { name = "Physics_Integrate", end = 0x8210B180 }
0x8215C200 = { size = 512 }
# fragmento discontinuo que pertenece a otra función:
0x8215C900 = { parent = 0x8215C200, size = 64 }
```

Ponerles nombre a las funciones que vayas identificando (`name = "..."`) hace que el
C++ generado sea legible y que los stack traces del debugger tengan sentido. Vale
mucho la pena hacerlo desde el principio.

## `setjmp` / `longjmp`

Si el juego los usa (muy probable — EA los usaba para manejo de errores del
streaming), hay que decirle dónde están o los saltos no locales corrompen el estado:

```toml
setjmp_address  = 0x82XXXXXX
longjmp_address = 0x82XXXXXX
```

Cómo encontrarlos: en Ghidra busca la función que guarda ~18 registros no volátiles
(r14–r31, LR, CR, SP) en un buffer que llega por `r3` y devuelve 0. Esa es `setjmp`.
`longjmp` es la que hace lo inverso y termina en `mtctr`/`bctr`.

## Opciones de calidad de código generado

Todas por defecto en `false`. Actívalas **después** de tener un build que arranca,
nunca antes — cambian el codegen y pueden enmascarar bugs:

```toml
cr_as_local           = true   # el que más rinde: CR como locales
xer_as_local          = true
ctr_as_local          = true
non_volatile_as_local = true   # r14-r31 como locales
skip_lr               = true   # ahorra en funciones hoja
```

`cr_as_local` es el de mayor impacto en código con muchos branches — que en un juego
de coches es casi todo (física, IA de tráfico, colisiones).

## Recompilar tras cada cambio

```bash
cmake --build --preset win-amd64-debug --target nfsmw_codegen
cmake --build --preset win-amd64-debug
```

Cuando el codegen termine sin errores y el proyecto compile → `docs/03-runtime.md`.
