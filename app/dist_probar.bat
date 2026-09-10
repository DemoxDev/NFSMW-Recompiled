@echo off
setlocal
cd /d "%~dp0"

rem ===========================================================================
rem  PRUEBA DE ARRANQUE - para quien ve que el juego no le arranca.
rem
rem  Va en la misma carpeta que el juego. Doble clic y ya.
rem
rem  QUE HACE
rem  Lanza el juego 20 veces: 5 por cada una de 4 configuraciones distintas de
rem  planificacion de hilos. Cada intento arranca con la cache de shaders
rem  VACIA, que es lo que destapa el fallo.
rem
rem  Se abriran y cerraran ventanas solas. Es normal. Tarda unos 8 minutos.
rem
rem  Al final imprime una tabla. ESA TABLA ES LO QUE HAY QUE MANDAR.
rem ===========================================================================

if not exist "%~dp0matriz.ps1" (
    echo [ERROR] Falta matriz.ps1 en esta carpeta.
    echo         Tiene que estar al lado del juego
    echo.
    pause
    exit /b 1
)

rem  El juego es nfsmw.exe: en build\ el nombre NFS_Most_Wanted.exe lo lleva
rem  EL LANZADOR, para que el icono del juego abra la ventana de opciones. Se
rem  acepta el nombre viejo detras, para carpetas de antes del cambio.
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
