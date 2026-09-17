@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

rem ===========================================================================
rem  COMPARE THE TWO VIDEO ENGINES
rem
rem  Goes in the same folder as the game. Double-click and done.
rem
rem  WHAT IT'S FOR
rem  We're chasing a visual glitch and need to know if it happens to
rem  everyone or only to one specific card. This .bat launches the game two
rem  different ways so they can be compared.
rem
rem  WHAT TO LOOK FOR
rem  A HORIZONTAL BAND crossing the screen. Below it the road and ground
rem  look brighter, yellowish; above it, dimmer. The edge is straight and
rem  always stays at the same height on the screen, it doesn't move with the
rem  scenery.
rem
rem  Easiest to spot driving on an open road in daylight.
rem
rem  WHAT TO ANSWER
rem  Just two things per option:
rem     1. whether that band is visible or not
rem     2. the fps shown by F3
rem
rem  That's it. With those four data points we can tell if the bug is in the
rem  game or in one specific graphics card.
rem ===========================================================================

rem  The game is nfsmw.exe: in build\ the name NFS_Most_Wanted.exe belongs to
rem  THE LAUNCHER, so the game's icon opens the options window. The old name
rem  is still accepted as a fallback, for folders from before the change.
set "JUEGO=%~dp0nfsmw.exe"
if not exist "%JUEGO%" set "JUEGO=%~dp0NFS_Most_Wanted.exe"
if not exist "%JUEGO%" (
    echo [ERROR] No encuentro nfsmw.exe en esta carpeta.
    echo         Este archivo tiene que estar al lado del juego.
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

:menu
cls
echo ============================================
echo   Comparar los dos motores de video
echo ============================================
echo.
echo   1  Rapido    (rtv)
echo   2  Exacto    (rov)
echo   3  Salir
echo.
echo   QUE MIRAR EN CADA UNO
echo.
echo     Una FRANJA HORIZONTAL cruzando la pantalla. Debajo de ella el suelo
echo     se ve mas iluminado y amarillento, encima mas apagado. El borde es
echo     recto y NO se mueve con el paisaje: se queda clavado a la misma
echo     altura de la pantalla aunque gires el coche.
echo.
echo     Se nota mejor en carretera abierta y de dia.
echo.
echo     Apunta dos cosas por opcion:  se ve la franja (si/no)  y  los fps.
echo     F3 dentro del juego muestra los fps.
echo.
echo   Los dos arrancan en ventana y sin vsync, para que los fps sean reales.
echo   Prueba los dos EN EL MISMO SITIO del mapa.
echo.
set "OPCION="
set /p "OPCION=Elige: "

if "%OPCION%"=="1" set "CAMINO=rtv" & goto :lanzar
if "%OPCION%"=="2" set "CAMINO=rov" & goto :lanzar
if "%OPCION%"=="3" goto :fin
goto menu

:lanzar
echo.
echo Lanzando en modo %CAMINO%. Cierra la ventana del juego cuando termines.
echo.
"%JUEGO%" --render_target_path_d3d12=%CAMINO% --fullscreen=false --vsync=false

echo.
echo ============================================
echo   Modo %CAMINO%
echo ============================================
set "FRANJA="
set /p "FRANJA=Se veia la franja horizontal? (si/no): "
set "FPS="
set /p "FPS=Cuantos fps marcaba F3?: "

if defined FRANJA (
    echo %DATE% %TIME%  modo=%CAMINO%  franja=%FRANJA%  fps=%FPS%>>"%~dp0resultado_video.txt"
    echo.
    echo Apuntado.
)
echo.
pause
goto menu

:fin
echo.
if exist "%~dp0resultado_video.txt" (
    echo ============================================
    echo   ESTO ES LO QUE HAY QUE MANDAR
    echo ============================================
    echo.
    type "%~dp0resultado_video.txt"
    echo.
    echo Esta guardado en:
    echo   %~dp0resultado_video.txt
) else (
    echo No has apuntado ningun resultado todavia.
)
echo.
pause
exit /b
