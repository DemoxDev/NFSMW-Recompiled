# Fase 0 — Entorno de compilación

ReXGlue **solo** funciona con Clang. MSVC y GCC no están soportados: el código
generado depende de intrinsics y de comportamiento de optimización específicos de
Clang/LLVM. No intentes forzarlo, se rompe de formas raras.

## Windows

| Herramienta | Versión mínima | Nota |
|---|---|---|
| Visual Studio 2022 Community | — | workload *Desktop development with C++* |
| C++ Clang Compiler for Windows | 20.x | componente opcional dentro del instalador de VS |
| MSBuild support for LLVM (clang-cl) | — | componente opcional |
| CMake | 3.25+ | el que trae VS sirve |
| Ninja | cualquiera | el que trae VS sirve |
| Windows SDK + headers D3D12 | — | vienen con el workload |
| Python | 3.8+ | solo para las herramientas de extracción |
| Git | — | con `--recursive` para submódulos |

En el instalador de VS: pestaña **Individual components** → busca "clang" → marca
*C++ Clang Compiler for Windows* y *MSBuild support for LLVM (clang-cl) toolset*.

Verificación:
```powershell
cmake --version
ninja --version
clang --version     # debe decir 20.x o superior
python --version
```

## Linux

Debian / Ubuntu:
```bash
sudo apt update
sudo apt install -y clang-20 lld-20 cmake ninja-build git python3 libgtk-3-dev
```

Si tu distro no tiene `clang-20` en repos, usa el instalador de LLVM:
```bash
wget https://apt.llvm.org/llvm.sh
chmod +x llvm.sh
sudo ./llvm.sh 20
```

Arch:
```bash
sudo pacman -S clang lld cmake ninja git python gtk3
```

Verificación:
```bash
clang --version    # 20+
cmake --version    # 3.25+
ninja --version
pkg-config --modversion gtk+-3.0
```

## macOS (Apple Silicon)

```bash
xcode-select --install
brew install cmake ninja python
python3 --version    # 3.10+; si no, brew te enlaza python3.12
```

El SDK, igual que en Linux:

```bash
cd rexglue-sdk
git submodule update --init --recursive
cmake --preset mac-arm64 -DREXGLUE_USE_VULKAN=ON
cmake --build out/build/mac-arm64 --config Release --target install
```

El juego: `tools/build_mac.sh` hace todo (parches, SDK, codegen, juego, carpeta
`build/mac/` y el bundle `NFSMW.app`). Ver [macos.md](macos.md).

## Camino rápido (Windows)

Doble clic en **`FASE0_ENTORNO.bat`** en la raíz del proyecto. Localiza Visual Studio
con `vswhere` (incluidas las versiones Insiders/Preview), carga el entorno de
compilación x64, verifica cada herramienta, y si está todo clona y compila el SDK.

### El error clásico: marcar solo los componentes de Clang

Es tentador ir a *Componentes individuales*, buscar "clang", marcar los dos que
salen, y darle a instalar. **No funciona.** Clang en Windows no es autosuficiente:
necesita las cabeceras y librerías del **Windows SDK** y el toolchain de **MSVC**
para enlazar. Y ReXGlue necesita además los headers de **D3D12**, que también vienen
del SDK.

Si el instalador te pregunta *"¿Desea continuar sin las cargas de trabajo?"*, la
respuesta es **no**: dale a *Agregar cargas de trabajo* y marca
**"Desarrollo para el escritorio con C++"**.

### Por qué hace falta el .bat y no vale una consola normal

`cmake`, `ninja` y `clang-cl` que instala Visual Studio **no están en el PATH global**.
Tampoco lo están las variables `INCLUDE` y `LIB` que apuntan al Windows SDK. Todo eso
solo existe después de ejecutar `vcvars64.bat`, que es lo que hace el *Developer
Command Prompt*.

El `.bat` de fase 0 hace eso por ti. Si prefieres trabajar a mano, abre
**"Developer PowerShell for VS"** desde el menú de inicio en vez de una PowerShell
normal.

## Instalar el SDK

```bash
git clone --recursive https://github.com/rexglue/rexglue-sdk.git
cd rexglue-sdk

# Windows
cmake --preset win-amd64
cmake --build out/build/win-amd64 --target install

# Linux
cmake --preset linux-amd64
cmake --build out/build/linux-amd64 --target install
```

`install` registra el SDK en el *user package registry* de CMake, así que tu proyecto
lo encuentra solo con `find_package(rexglue)` sin rutas absolutas.

Comprueba que el CLI quedó en el PATH:
```bash
rexglue --help
```

Si no aparece, añade el `bin/` de la instalación al PATH, o llama al binario por ruta
completa desde `out/install/<preset>/bin/`.

## Sobre compilar en Windows y Linux a la vez

Es viable y de hecho recomendable: los dos toolchains usan Clang, así que los errores
de codegen aparecen igual en ambos, pero Linux te da mejores sanitizers (ASan/UBSan)
para cazar corrupciones de memoria del guest, y Windows te da RenderDoc/PIX cómodos
para depurar la parte gráfica. Mantén un solo `config/nfsmw_config.toml` y dos
directorios de build separados.


---

## Problemas conocidos

### `error: expected identifier or '('` en `lzxd.c` (libmspack)

```
lzxd.c:1:1: error: expected identifier or '('
    1 | ../../libmspack/mspack/lzxd.c
```

El archivo no tiene código C dentro: tiene una **ruta**. Varios submódulos
(libmspack el primero) usan enlaces simbólicos en su árbol. Crear symlinks en
Windows requiere permisos especiales, así que git —cuando no los tiene— hace
check out del enlace como un fichero de texto normal cuyo único contenido es la
ruta del destino. El compilador lo abre esperando C y encuentra eso.

`FASE0_ENTORNO.bat` lo repara solo antes de compilar. Para lanzarlo a mano:

```powershell
python tools\arreglar_symlinks.py ..\rexglue-sdk
python tools\arreglar_symlinks.py ..\rexglue-sdk --simular   # ver sin tocar
```

Sustituye cada enlace roto por una copia real del archivo destino. No hace falta
ser administrador ni volver a clonar.

**Ojo:** git verá esos archivos como modificados, y un `git submodule update`
los revierte. Si vuelves a actualizar el SDK, relanza el script (es idempotente).

La alternativa "correcta" es activar el Modo de desarrollador de Windows, poner
`git config --global core.symlinks true` y volver a clonar — pero son 800 MB de
descarga otra vez para arreglar tres archivos.

### El preset `win-amd64` sale como desactivado

```
CMake Error: Cannot use disabled configure preset ... "win-amd64"
```

Tienes MSYS2, Cygwin o Git Bash por delante de Visual Studio en el PATH. Su
`cmake` reporta `${hostSystemName}` como `MSYS` en vez de `Windows`, y el preset
exige `Windows`. `FASE0_ENTORNO.bat` lo evita anteponiendo al PATH el `cmake`,
`ninja` y `clang` de Visual Studio, y marca con `[??]` cualquier herramienta que
no venga de ahí.
