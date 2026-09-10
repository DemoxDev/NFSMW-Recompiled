@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

rem ===========================================================================
rem  Lanza el juego con el log al maximo detalle, para cazar el cuelgue.
rem
rem  POR QUE HACE FALTA
rem  Con el log normal, la sesion que se colgo no dejo NADA: cero errores, y
rem  silencio total desde el momento en que se traba. Eso descarta que sea una
rem  excepcion o una funcion sin registrar -esas se ven-. Lo que queda es que
rem  el codigo del juego se quedo esperando algo que no llega, o dando vueltas.
rem
rem  A nivel debug se registran ademas las llamadas al kernel: esperas sobre
rem  eventos y semaforos, lecturas de archivo, creacion y salida de hilos. Si
rem  el juego esta bloqueado en una espera, las ULTIMAS LINEAS antes del
rem  silencio dicen sobre que.
rem
rem  POR QUE NO SE PODIA HACER ANTES
rem  Porque el aviso "Too few processor cores" salia mil veces por segundo y
rem  se comia el log entero: 105 MB en un cuarto de hora, y lo interesante
rem  rotaba fuera del archivo antes de que a uno le diera tiempo a leerlo. Ya
rem  esta arreglado, asi que ahora el detalle cabe.
rem
rem  QUE ES log_noisy, Y POR QUE AHORA SI
rem  Muchos mensajes internos del SDK -entre ellos TODO el ciclo de vida del
rem  descodificador de audio XMA- estan detras de REXLOG_NOISY_DEBUG, que no
rem  se compila fuera: se enciende con el cvar log_noisy. Y el XMA es
rem  justamente donde se quedo colgado el juego, dando vueltas entre
rem  XMAGetOutputBufferWriteOffset y XMAGetOutputBufferReadOffset esperando
rem  datos que no llegan. Sin esto no se ve ni una linea de lo que hace ese
rem  descodificador.
rem
rem  EL LOG VA A SER MUY GRANDE. Es normal. Rota solo, y lo mas reciente
rem  -que es lo que interesa- se queda siempre en logs\detallado.log.
rem
rem  COMO USARLO
rem    1. Doble clic.
rem    2. Reproduce el fallo: termina el prologo, sal del taller, espera a que
rem       se muera el audio, e intenta volver al menu.
rem    3. Cuando se cuelgue, ESPERA UNOS SEGUNDOS antes de cerrar. Si hay algo
rem       que se registre con retraso, que le de tiempo.
rem    4. Cierra y avisa. El archivo es logs\detallado.log
rem ===========================================================================

set "EXE="
rem nfsmw.exe PRIMERO: desde que el lanzador ocupa el nombre
rem NFS_Most_Wanted.exe, el juego en build\ se llama asi. Se sigue mirando
rem el nombre viejo detras, para carpetas armadas antes del cambio.
if exist "%~dp0build\nfsmw.exe" set "EXE=%~dp0build\nfsmw.exe"
if not defined EXE if exist "%~dp0build\NFS_Most_Wanted.exe" set "EXE=%~dp0build\NFS_Most_Wanted.exe"
if not defined EXE if exist "%~dp0app\out\build\win-amd64-release\nfsmw.exe" set "EXE=%~dp0app\out\build\win-amd64-release\nfsmw.exe"

if not defined EXE (
    echo [ERROR] No encuentro el ejecutable.
    echo.
    pause
    exit /b 1
)

set "ISO="
for %%d in ("%EXE%") do set "DIREXE=%%~dpd"
for %%f in ("!DIREXE!*.iso") do if not defined ISO set "ISO=%%~ff"
if not defined ISO for %%f in ("%~dp0build\*.iso") do if not defined ISO set "ISO=%%~ff"
if not defined ISO for %%f in ("%~dp0*.iso") do if not defined ISO set "ISO=%%~ff"
if not defined ISO for %%f in ("%~dp0assets\*.iso") do if not defined ISO set "ISO=%%~ff"

if not defined ISO (
    echo [ERROR] No encuentro ninguna .iso.
    echo.
    pause
    exit /b 1
)

if not exist "logs" mkdir "logs"

echo ============================================
echo   Log detallado - cazar el cuelgue
echo ============================================
echo.
echo   Ejecutable: %EXE%
echo   ISO       : %ISO%
echo   Log       : %~dp0logs\detallado.log
echo.
echo QUE HACER
echo   1. Termina el prologo y sal del taller con el coche.
echo   2. Espera a que se muera el audio.
echo   3. Intenta volver al menu.
echo   4. Cuando se cuelgue, ESPERA UNOS SEGUNDOS antes de cerrar.
echo.
echo El juego va a ir BASTANTE MAS LENTO: se registra todo, incluido el
echo detalle interno del descodificador de audio, que es donde se cuelga.
echo Eso no importa para lo que buscamos, solo hay que llegar al fallo.
echo.
echo Y cuando se cuelgue, AGUANTA 30 SEGUNDOS antes de cerrar: hacen falta
echo dos o tres instantaneas del vigilante dentro del cuelgue.
echo.
pause
echo.
echo Lanzando...
echo.

"%EXE%" --game_data_root="%ISO%" --log_level=debug --log_noisy=true --log_file="%~dp0logs\detallado.log" --fullscreen=false --vsync=false

echo.
echo ============================================
echo   Terminado
echo ============================================
echo.
echo El log esta en:
echo   %~dp0logs\detallado.log
echo.
echo Si hay archivos detallado.1.log, detallado.2.log y demas, son los
echo trozos anteriores. El que importa es detallado.log a secas: siempre
echo tiene lo mas reciente, que es justo el momento del cuelgue.
echo.
pause
