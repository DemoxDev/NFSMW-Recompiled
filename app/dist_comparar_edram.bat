@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

rem ===========================================================================
rem  COMPARAR LOS DOS MOTORES DE VIDEO
rem
rem  Va en la misma carpeta que el juego. Doble clic y ya.
rem
rem  PARA QUE SIRVE
rem  Estamos persiguiendo un fallo visual y hace falta saber si le pasa a todo
rem  el mundo o solo a una tarjeta concreta. Este .bat lanza el juego de dos
rem  formas distintas para poder compararlas.
rem
rem  QUE HAY QUE MIRAR
rem  Una FRANJA HORIZONTAL que cruza la pantalla. Por debajo de ella la
rem  carretera y el suelo se ven mas iluminados, en amarillo; por encima, mas
rem  apagados. El borde es recto y se queda siempre a la misma altura de la
rem  pantalla, no se mueve con el paisaje.
rem
rem  Se ve mejor conduciendo por una carretera abierta y de dia.
rem
rem  QUE CONTESTAR
rem  Solo dos cosas por cada opcion:
rem     1. si esa franja se ve o no
rem     2. los fps que marca F3
rem
rem  Eso es todo. Con esos cuatro datos sabemos si el fallo es del juego o de
rem  una tarjeta grafica concreta.
rem ===========================================================================

rem  El juego es nfsmw.exe: en build\ el nombre NFS_Most_Wanted.exe lo lleva
rem  EL LANZADOR, para que el icono del juego abra la ventana de opciones. Se
rem  acepta el nombre viejo detras, para carpetas de antes del cambio.
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
