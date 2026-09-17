@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

rem ===========================================================================
rem  Builds the portable  build\  folder and checks that it's self-contained.
rem
rem  IT NOW STARTS WITH THE FIXES, AND THAT'S NOT DECORATION
rem
rem  The game's fixes don't live in the app's code: they live in the SDK,
rem  applied by the scripts in tools\ over its sources. So they end up
rem  inside rexruntime.dll, not the .exe.
rem
rem  Before, this only compiled the app and copied whatever was there. If the
rem  SDK was unpatched -freshly cloned, reverted by hand, or from another
rem  branch-, build\ came out with a rexruntime.dll WITHOUT the fixes and
rem  looking just like a good one. You don't notice that failure until the
rem  game hangs at someone else's place, which is the worst place to find out.
rem
rem  So now the patches get applied -they're idempotent: if they're already
rem  there, they say so and touch nothing- and the SDK gets recompiled before
rem  assembling the folder. If everything was already up to date, that phase
rem  takes seconds.
rem
rem  WHICH FIXES GO IN
rem    tools\parche_desatasco.py    THE AUDIO/HANG ONE. When the game's audio
rem                                 thread has spent more than a quarter
rem                                 second spinning on a voice that ran out
rem                                 of data, it's given the "buffer finished"
rem                                 signal that its own code knows how to
rem                                 read, and it moves on.
rem    tools\parche_diagnostico.py  the "Too few processor cores" warning was
rem                                 printing a thousand times a second and
rem                                 choking the CPU on low-core machines. Now
rem                                 it prints once. Also, if something
rem                                 crashes, the log says which game thread
rem                                 and with what registers.
rem    tools\parche_gpu_fallback.py if there's no GPU with Direct3D 12 level
rem                                 11_0, it tries WARP before giving up; and
rem                                 if that fails too, it shows a dialog box
rem                                 instead of doing nothing on launch.
rem    tools\parche_restaurar.py    improvements to the settings menu (F4): a
rem                                 "Restore defaults" button and sliders for
rem                                 decimal settings with limits. It doesn't
rem                                 fix anything, but when trying out
rem                                 performance cvars you end up touching six
rem                                 or seven and then have no way back to the
rem                                 starting point without restarting.
rem    tools\parche_velocidad.py    a game_speed setting that multiplies how
rem                                 fast time passes inside the game,
rem                                 adjustable on the fly from F4. It's not an
rem                                 fps cap: fps is how many times it draws,
rem                                 this is how fast the game progresses.
rem    tools\parche_backend.py      a gpu_backend setting to choose the
rem                                 graphics API: d3d12 or vulkan. The plugin
rem                                 already knew how to choose; what was
rem                                 missing was someone telling it to. Needs a
rem                                 restart to take effect.
rem                                 DX11 isn't in the list because this SDK
rem                                 has no DX11 backend, and never did: the
rem                                 Xenos emulation uses DX12-generation
rem                                 features -ROV, unbounded descriptors,
rem                                 typed writes from shaders-.
rem    tools\parche_anillo.py       XMA instrumentation. Doesn't change
rem                                 behavior and prints nothing with normal
rem                                 logging, but it's what put a name and a
rem                                 time on the hang, and what will be needed
rem                                 if it comes back. Also the unstick fix
rem                                 relies on its headers, so it goes first.
rem
rem  WHAT GOES INTO build\
rem    NFS_Most_Wanted.exe        THE LAUNCHER, with the game's icon. This is
rem                               what you open: it brings up the options
rem                               window, and from there you play.
rem    nfsmw.exe                  the actual game. It used to be called
rem                               NFS_Most_Wanted.exe until the launcher took
rem                               that name. Opening it directly still works
rem                               just like always: it looks for the ISO
rem                               next to it.
rem    rexruntime.dll             SDK runtime: this is where the fixes live
rem    rexgpu-xenos.dll           GPU emulation. Loaded with LoadLibrary based
rem                               on the gpu_plugin cvar, so it does NOT show
rem                               up in the linker's dependencies: it has to
rem                               be copied by hand or the screen stays black.
rem    MSVCP140.dll               \  Visual C++ runtime. The ones the .exe and
rem    MSVCP140_ATOMIC_WAIT.dll    | rexruntime import that don't ship with
rem    VCRUNTIME140.dll            | Windows. Resolved from the toolchain
rem    VCRUNTIME140_1.dll         /  itself, with no fixed paths.
rem    LANZADOR.bat / lanzador.ps1
rem    nfsmw.toml  COMPARAR_VIDEO.bat  PROBAR.bat  matriz.ps1  LEEME.txt
rem
rem  THE ISO IS NOT COPIED. It's several GB, it's yours, and the game reads
rem  it on the fly. Put it in build\ yourself whenever you want to use the
rem  folder.
rem
rem  SALIDA is used for return codes, NEVER "RC": that variable is set by
rem  vcvars64 with the resource compiler's path, and CMake reads it when
rem  detecting the toolchain.
rem ===========================================================================

if /i "%~1"=="__run" goto :run

if not exist "logs" mkdir "logs"

echo ============================================
echo   Build portable
echo ============================================
echo.
echo Comprueba los arreglos, recompila lo que haga falta y arma la
echo carpeta portable  build\
echo.
echo   1. Arreglos del SDK   audio, vsync, GPU, menu de F4, API grafica
echo   2. Recompilar el SDK  ahi es donde viven esos arreglos
echo   3. Compilar la app
echo   4. Armar build\
echo   5. Comprobar que la carpeta sea autonoma
echo.
echo Si ya estaba todo al dia, son unos segundos.
echo Si hay que reenlazar, el paso final son casi 50 MB y no imprime nada
echo durante varios minutos. NO CIERRES LA VENTANA.
echo.
echo Registro en logs\construir.log
echo.
pause

echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "& { & $env:ComSpec /c 'CONSTRUIR.bat __run 2>&1' | Tee-Object -FilePath 'logs\construir.log' }"

echo.
echo ============================================
pause
exit /b

rem ===========================================================================
:run
rem ===========================================================================

call "%~dp0tools\_entorno_vs.bat"
if not defined ENTORNO_OK goto fin

rem Without Python the patches can't be applied, and without patches the
rem folder would come out without the fixes. Better to stop here than build
rem a broken build.
if not defined PY (
    echo [ERROR] No encuentro Python. Hace falta para aplicar los arreglos
    echo         del SDK, que es donde vive el del audio.
    echo         Instala Python 3 y vuelve a intentarlo.
    goto fin
)

echo ############################################
echo # 1/5  ARREGLOS DEL SDK
echo ############################################
rem Idempotent: if they're already applied they say so and touch nothing.
rem
rem ORDER MATTERS. parche_anillo runs before parche_desatasco because it's
rem the one that adds <atomic> and <chrono> to the kernel file, and desatasco
rem uses them. desatasco checks for that and refuses to apply if it's
rem missing, so at worst this stops here with a clear message, not halfway
rem through the build.
%PY% "%~dp0tools\parche_diagnostico.py"
if errorlevel 1 (
    echo [ERROR] No se pudo aplicar el parche de diagnostico. Me detengo.
    goto fin
)
%PY% "%~dp0tools\parche_anillo.py"
if errorlevel 1 (
    echo [ERROR] No se pudo instrumentar el kernel del XMA. Me detengo.
    goto fin
)
%PY% "%~dp0tools\parche_desatasco.py"
if errorlevel 1 (
    echo [ERROR] No se pudo aplicar el desatasco del audio. Me detengo.
    echo.
    echo         Este es EL arreglo del cuelgue. Sin el, la carpeta no vale
    echo         para repartir, asi que no sigo y no toco build\
    goto fin
)
rem Vsync and the fps limiter. Out of the box NEITHER works: "vsync" exists
rem as a cvar but the presenter's Present had SyncInterval hardcoded to 0,
rem and there was no limiter at all. Without this, those two launcher
rem settings do nothing and the launcher itself flags it in red.
%PY% "%~dp0tools\parche_presentador.py"
if errorlevel 1 (
    echo [ERROR] No se pudo aplicar el vsync y el limite de fps. Me detengo.
    goto fin
)
%PY% "%~dp0tools\parche_gpu_fallback.py"
if errorlevel 1 (
    echo [ERROR] No se pudo aplicar el parche de GPU. Me detengo.
    goto fin
)
rem This one's a convenience, not a correctness fix: the restore button in the F4 menu.
%PY% "%~dp0tools\parche_restaurar.py"
if errorlevel 1 (
    echo [ERROR] No se pudo mejorar el menu de ajustes. Me detengo.
    goto fin
)
%PY% "%~dp0tools\parche_velocidad.py"
if errorlevel 1 (
    echo [ERROR] No se pudo anadir el ajuste de velocidad. Me detengo.
    goto fin
)
%PY% "%~dp0tools\parche_backend.py"
if errorlevel 1 (
    echo [ERROR] No se pudo anadir el selector de API grafica. Me detengo.
    goto fin
)
rem The multiplayer gate. Adds the grant_user_privileges setting, OFF by
rem default, so adding it here doesn't change anyone's behavior: it just
rem leaves the switch available in F4.
%PY% "%~dp0tools\parche_privilegios.py"
if errorlevel 1 (
    echo [ERROR] No se pudo anadir el ajuste de privilegios. Me detengo.
    goto fin
)
echo.

echo ############################################
echo # 2/5  RECOMPILAR EL SDK
echo ############################################
echo Los arreglos viven en rexruntime.dll, no en el .exe. Si el SDK ya
echo estaba compilado y no cambio nada, esto tarda segundos.
echo.
rem ---------------------------------------------------------------------------
rem  CONFIGURE WITH VULKAN ON
rem
rem  On Windows the SDK ships with REXGLUE_USE_VULKAN set to OFF, so the
rem  Vulkan backend -which lives entirely in src/graphics/vulkan- doesn't get
rem  compiled, and the gpu_backend=vulkan setting would have nothing to load.
rem
rem  This turns it on in the CMake cache. It's idempotent: if it was already
rem  set, configuring changes nothing and takes seconds. NOT THE FIRST TIME
rem  THOUGH: changing an option forces half the SDK to recompile, and pulls
rem  in glslang and spirv-tools too. That run takes a good while.
rem
rem  No need to install the Vulkan SDK: the headers, loader, memory allocator
rem  and glslang already ship in thirdparty\
rem ---------------------------------------------------------------------------
pushd "%SDK%"
cmake --preset win-amd64 -DREXGLUE_USE_VULKAN=ON
set "SALIDA=!errorlevel!"
if not "!SALIDA!"=="0" (
    popd
    echo [ERROR] Fallo la configuracion del SDK con codigo !SALIDA!
    echo         Si se queja de Vulkan, se puede seguir sin el:
    echo             cmake --preset win-amd64 -DREXGLUE_USE_VULKAN=OFF
    echo         El resto de arreglos no lo necesitan.
    goto fin
)
cmake --build out/build/win-amd64 --config Release --target install
set "SALIDA=!errorlevel!"
popd
if not "!SALIDA!"=="0" (
    echo [ERROR] Fallo la compilacion del SDK con codigo !SALIDA!
    echo.
    echo Para dejar el SDK como estaba:
    echo     %PY% tools\parche_anillo.py --revertir
    echo     %PY% tools\parche_diagnostico.py --revertir
    echo     %PY% tools\parche_gpu_fallback.py --revertir
    goto fin
)
echo.

echo ############################################
echo # 3/5  COMPILAR LA APP EN RELEASE
echo ############################################
set "DIRREL=%~dp0app\out\build\win-amd64-release"
if exist "%DIRREL%\.ninja_lock" del /q "%DIRREL%\.ninja_lock" >nul 2>&1

pushd "app"
cmake --preset win-amd64-release

rem ---------------------------------------------------------------------------
rem  TWO PASSES, AND IT'S NOT A WHIM
rem
rem  Codegen rewrites generated\default\nfsmw_pch.h, and the precompiled
rem  header (cmake_pch.hxx.pch) that the 131 generated files use is built
rem  from that header.
rem
rem  In a SINGLE pass, ninja decides at startup which files are dirty. At
rem  that point nfsmw_pch.h hasn't changed yet, so it considers the PCH
rem  good. Then, still within the same pass, codegen changes it. When it's
rem  the .cpp files' turn, clang compares and aborts:
rem
rem      fatal error: file 'nfsmw_pch.h' has been modified since the
rem      precompiled header was built: size changed (was 18553, now 18522)
rem
rem  By running codegen first and separately, the second pass starts with
rem  the headers already final and correctly figures out what needs rebuilding.
rem ---------------------------------------------------------------------------
echo -- Pasada 1: codegen --
cmake --build --preset win-amd64-release --target nfsmw_codegen
set "SALIDA=!errorlevel!"
if not "!SALIDA!"=="0" (
    popd
    echo [ERROR] El codegen fallo con codigo !SALIDA!
    goto fin
)

echo.
echo -- Pasada 2: compilar --
cmake --build --preset win-amd64-release
set "SALIDA=!errorlevel!"
popd
if not "!SALIDA!"=="0" (
    echo [ERROR] Fallo la compilacion con codigo !SALIDA!
    goto fin
)
echo.

echo ############################################
echo # 4/5  ARMAR build\
echo ############################################
rem Besides copying, it removes leftovers from previous runs -logs\, matriz\,
rem shaders\, cache\-, which belong to THIS machine and shouldn't travel.
pushd "app"
cmake --build --preset win-amd64-release --target dist
set "SALIDA=!errorlevel!"
popd
if not "!SALIDA!"=="0" (
    echo [ERROR] No se pudo armar build\ con codigo !SALIDA!
    goto fin
)
echo.

rem ---------------------------------------------------------------------------
rem  The launcher, and the rename that puts it in front
rem
rem  The dist target leaves the game as build\NFS_Most_Wanted.exe. This
rem  renames it to nfsmw.exe and puts the launcher in its place, so double-
rem  clicking the game's icon opens the options window. Opening nfsmw.exe
rem  directly still works just like before.
rem
rem  Runs BEFORE the self-containment check on purpose: that way what gets
rem  checked is the folder as it will actually end up, launcher included.
rem
rem  If it fails, the folder is still usable: the game will be either
rem  nfsmw.exe or NFS_Most_Wanted.exe and LANZADOR.bat works the same either
rem  way. That's why this doesn't abort.
echo -- Lanzador --
call "%~dp0CONSTRUIR_LANZADOR.bat" /silencioso
set "SALIDA=!errorlevel!"
if not "!SALIDA!"=="0" (
    echo [aviso] No se pudo construir el lanzador ^(codigo !SALIDA!^).
    echo         La carpeta sigue valiendo: se juega con LANZADOR.bat.
)
echo.

echo ############################################
echo # 5/5  COMPROBAR QUE SEA AUTONOMA
echo ############################################
rem Reads each build\ binary's PE import table and follows the dependency
rem chain. Doesn't use dumpbin on purpose: dumpbin comes with Visual Studio,
rem and the point is to check this without assuming any tools are installed.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\comprobar_dist.ps1"

echo.

rem ---------------------------------------------------------------------------
rem  And while we're at it, the distribution folders
rem
rem  This used to be a manual step: "zip build\ without the ISO". It's done
rem  here because this is exactly the moment build\ is freshly made and
rem  clean, and because the manual step had a trap: the ISO is several GB and
rem  it's easy to send it by mistake.
rem
rem  Leaves two folders next to the project, in "build release":
rem
rem    NFSMW Windows x64\              ready to play, and to send to someone
rem                                    who has THEIR OWN copy of the game
rem    NFSMW Windows x64 - Portable\   everything but the game; this one is
rem                                    the one to publish
rem
rem  If the script isn't found, nothing happens: build\ is already made and
rem  can be zipped by hand as always.
set "RELEASE=%~dp0..\build release\PREPARAR_RELEASE.bat"
if exist "%RELEASE%" (
    echo ############################################
    echo # EXTRA  CARPETAS DE REPARTO
    echo ############################################
    call "%RELEASE%" /silencioso
    if errorlevel 1 (
        echo [aviso] No se pudieron armar las carpetas de reparto.
        echo         build\ esta bien; comprimela a mano si hace falta.
    )
    echo.
)

echo ============================================
echo   LISTO
echo ============================================
echo.
echo build\ esta rehecha, con los arreglos dentro y sin rastro de
echo ejecuciones anteriores.
echo.
echo PARA JUGAR TU
echo   Copia tu ISO en build\ y doble clic en NFS_Most_Wanted.exe
echo.
echo   Ese es el LANZADOR, con el icono del juego: abre la ventana de
echo   opciones y desde ahi se juega. El juego de verdad es nfsmw.exe, y
echo   normalmente no hay que tocarlo. LANZADOR.bat sigue haciendo lo mismo.
echo.
echo PARA MANDARSELA A ALGUIEN
echo   Ya esta hecha, en  ..\build release\NFSMW Windows x64\
echo   Sin la ISO dentro. Comprimela y mandala.
echo.
echo   El tiene que poner SU PROPIA ISO, y del MISMO default.xex. Esto no
echo   es un emulador: el .exe lleva dentro el codigo de esa ISO concreta,
echo   traducido y compilado. Con una ROM de otra region no arranca, y ya
echo   nos costo un dia averiguarlo la primera vez.
echo.

:fin
exit /b
