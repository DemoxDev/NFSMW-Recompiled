@echo off
setlocal
cd /d "%~dp0"

rem ===========================================================================
rem  STARTUP TEST - for anyone whose game won't start.
rem
rem  Goes in the same folder as the game. Double-click and done.
rem
rem  WHAT IT DOES
rem  Launches the game 20 times: 5 for each of 4 different thread scheduling
rem  configurations. Each attempt starts with an EMPTY shader cache, which is
rem  what exposes the bug.
rem
rem  Windows will open and close on their own. That's normal. Takes about 8
rem  minutes.
rem
rem  At the end it prints a table. THAT TABLE IS WHAT NEEDS TO BE SENT.
rem ===========================================================================

if not exist "%~dp0matriz.ps1" (
    echo [ERROR] Falta matriz.ps1 en esta carpeta.
    echo         Tiene que estar al lado del juego
    echo.
    pause
    exit /b 1
)

rem  The game is nfsmw.exe: in build\ the name NFS_Most_Wanted.exe belongs to
rem  THE LAUNCHER, so the game's icon opens the options window. The old name
rem  is still accepted as a fallback, for folders from before the change.
set "JUEGO=%~dp0nfsmw.exe"
if not exist "%JUEGO%" set "JUEGO=%~dp0NFS_Most_Wanted.exe"
if not exist "%JUEGO%" (
    echo [ERROR] No encuentro nfsmw.exe en esta carpeta.
    echo.
    pause
    exit /b 1
)

set "HAYISO="
for %%f in ("%~dp0*.iso") do set "HAYISO=1"
if not defined HAYISO (
    echo [ERROR] No hay ninguna .iso en esta carpeta.
    echo         Copia aqui tu ISO del juego antes de probar.
    echo.
    pause
    exit /b 1
)

echo ============================================
echo   Prueba de arranque
echo ============================================
echo.
echo Voy a lanzar el juego 20 veces seguidas, con distintas opciones,
echo para averiguar cual de ellas lo hace arrancar.
echo.
echo Se abriran y cerraran ventanas solas. Es normal, no toques nada.
echo Tarda unos 8 minutos.
echo.
echo Al terminar sale una TABLA. Esa tabla es lo que hay que mandar.
echo.
pause
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0matriz.ps1"

echo.
echo ============================================
echo   Manda la tabla de arriba
echo ============================================
echo.
echo Si tambien quieres mandar los detalles, estan en la carpeta:
echo   %~dp0matriz
echo.
pause
