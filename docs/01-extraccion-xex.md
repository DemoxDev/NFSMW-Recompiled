# Fase 1 — Sacar el `default.xex` de tu ISO

Objetivo: pasar de tu ISO dumpeada a `assets/default.xex` + los assets del juego,
y anotar el `base address` que vas a necesitar en todas las fases siguientes.

Todo esto es sobre **tu propio dump**. Nada de lo que salga de aquí se sube a ningún
repositorio.

---

## Camino rápido: el script incluido

`tools/fase1_extraer.py` hace todo el proceso. Solo necesita Python 3.8+, sin
dependencias ni clonar nada.

### Paso 1 — Mirar qué hay dentro (no extrae nada)

```powershell
python tools\fase1_extraer.py "D:\ruta\a\NFSMW.iso" --listar
```

Salida esperada, más o menos:

```
Particion de juego en offset 0x0FD90000  (XGD2 (la mayoria de juegos de 360))
Directorio raiz: sector 33, 4,096 bytes

412 archivos, 18 directorios, 6,834,221,056 bytes en total

     6,291,456  default.xex
   [dir]        CARS
   [dir]        FRONTEND
   ...
```

Si el offset detectado no es `0x0FD90000`, no pasa nada: el script prueba XGD1,
XGD3 y, si hace falta, barre la imagen buscando el sistema de archivos.

**Si falla aquí** con "No se encontro un sistema de archivos XDVDFS": tu imagen no
es un ISO plano. Los `.cci`, `.god`, `.zar` y los `.iso` recomprimidos hay que
convertirlos antes (ver más abajo).

### Paso 2 — Extraer

```powershell
python tools\fase1_extraer.py "D:\ruta\a\NFSMW.iso" -o assets\game_root
```

Tarda unos minutos y ocupa ~7 GB. Al terminar imprime automáticamente la cabecera
del `default.xex`.

Si solo quieres el ejecutable de momento (unos segundos, unos MB):

```powershell
python tools\fase1_extraer.py "D:\ruta\a\NFSMW.iso" -o assets\game_root --solo-xex
```

### Paso 3 — Dejar el XEX donde toca

**No lo muevas fuera de `game_root`.** ReXGlue exige que el `--xex-path` esté
*dentro* del `--game-root`, porque de ahí deriva las rutas del guest (`game:\...`)
que el juego usará para buscar sus archivos. Si lo sacas, `rexglue init` falla con:

```
Failed: --xex_path (...) is not inside --game_root (...)
```

La extracción ya lo deja en su sitio: `assets/game_root/default.xex`. No hay nada
que copiar.

### Paso 4 — Guardar la info del XEX

```powershell
python tools\fase1_extraer.py assets\game_root\default.xex --info > docs\xex_info.txt
type docs\xex_info.txt
```

Esto es lo que tienes que ver:

```
== Datos clave ==
  Title ID              : 454107D9
  Media ID              : ........
  Version               : 1.0.0.0
  Disco                 : 1 de 1
  Image base address    : 0x82000000
  Entry point           : 0x82......
  Load address          : 0x82000000
  Tamano de imagen      : ......... bytes
  Cifrado               : normal (AES-128) (1)
  Compresion            : normal (LZX) (2)

  >> Title ID coincide con Need for Speed: Most Wanted (2005). Correcto.
```

**Lo importante de esa salida:**

- **Title ID `454107D9`** confirma que es NFSMW 2005 y no la versión de 2012 ni otro
  juego. Si el script te avisa con "OJO", para y comprueba el dump.
- **Image base address** (casi siempre `0x82000000`) es la referencia de todas las
  direcciones que vas a escribir en el TOML. Todo lo que declares — funciones, jump
  tables, hooks — va a estar por encima de este valor.
- **Cifrado AES-128 + compresión LZX** es lo normal en retail. **No hay que
  desencriptarlo a mano**: ReXGlue lo hace internamente durante el codegen. Si aquí
  saliera "ninguna/ninguno" sería un XEX ya procesado, lo cual también sirve.

En Linux es idéntico cambiando `\` por `/`:

```bash
python3 tools/fase1_extraer.py ~/dumps/NFSMW.iso --listar
python3 tools/fase1_extraer.py ~/dumps/NFSMW.iso -o assets/game_root
python3 tools/fase1_extraer.py assets/game_root/default.xex --info > docs/xex_info.txt
```

---

## Casos especiales

### Mi dump no es un ISO plano

| Formato | Qué es | Cómo pasarlo a ISO |
|---|---|---|
| `.cci` / `.cso` | ISO comprimido | `ciso` / `cci-tool` para descomprimir |
| GOD / carpeta `000D0000` | Games on Demand (STFS) | ver abajo |
| `.zar` | archivo de Xbox Backup Creator | extraer con XBC |

### Tengo un GOD / LIVE / CON en vez de ISO

Los Games on Demand no son XDVDFS, son paquetes STFS. Para esos sí hace falta la
herramienta externa:

```bash
git clone https://github.com/sp00nznet/360tools.git
python 360tools/tools/extract_stfs.py /ruta/al/archivo-header -o assets/game_root
```

Un GOD viene como un archivo sin extensión con nombre hexadecimal, más una carpeta
`000D0000/` con las partes. Apunta el script al **archivo header**, no a la carpeta.
Después sigue desde el Paso 3.

### Quiero abrirlo en Ghidra / IDA

Lo vas a necesitar en fase 2 para localizar `setjmp`/`longjmp` y resolver jump tables.

- **IDA Pro**: abre el `.xex` directamente con el loader de Xbox 360.
- **Ghidra**: necesita el PE crudo (desencriptado y descomprimido). Usa
  `360tools/tools/extract_pe.py`, o deja que ReXGlue haga el codegen y trabaja sobre
  el `.map` que genera. Al cargarlo: procesador **PowerPC 32-bit big-endian**.

---

## Dónde queda todo

```
NFSMW Recomp/
└── assets/
    └── game_root/         ← --game-root: el XEX Y los assets, juntos
        ├── default.xex    ← --xex-path (tiene que estar aqui dentro)
        ├── Movies/
        └── NFS/
└── docs/
    └── xex_info.txt       ← la salida del paso 4
```

`assets/` está en el `.gitignore`. Que siga así.

---

## Siguiente

Con `assets/game_root/default.xex` en su sitio y `docs/xex_info.txt` guardado →
`docs/02-codegen.md`.
