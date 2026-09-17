@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

rem ===========================================================================
rem  Launches the game with logging at maximum detail, to hunt the hang.
rem
rem  WHY IT'S NEEDED
rem  With normal logging, the session that hung left NOTHING: zero errors,
rem  and total silence from the moment it locks up. That rules out an
rem  exception or an unregistered function -those are visible-. What's left
rem  is that the game's code got stuck waiting for something that never
rem  arrives, or spinning.
rem
rem  At debug level, kernel calls are also logged: waits on events and
rem  semaphores, file reads, thread creation and exit. If the game is
rem  blocked on a wait, the LAST LINES before the silence say what for.
rem
rem  WHY THIS COULDN'T BE DONE BEFORE
rem  Because the "Too few processor cores" warning was printing a thousand
rem  times a second and eating the whole log: 105 MB in fifteen minutes, and
rem  the interesting part would rotate out of the file before anyone had time
rem  to read it. That's fixed now, so the detail fits.
rem
rem  WHAT log_noisy IS, AND WHY IT WORKS NOW
rem  Many internal SDK messages -including the ENTIRE lifecycle of the XMA
rem  audio decoder- sit behind REXLOG_NOISY_DEBUG, which isn't compiled out:
rem  it's turned on with the log_noisy cvar. And XMA is exactly where the
rem  game got stuck, spinning between XMAGetOutputBufferWriteOffset and
rem  XMAGetOutputBufferReadOffset waiting for data that never arrives.
rem  Without this you don't see a single line of what that decoder is doing.
rem
rem  THE LOG WILL BE VERY LARGE. That's normal. It rotates on its own, and
rem  the most recent part -which is what matters- always stays in
rem  logs\detallado.log.
rem
rem  HOW TO USE IT
rem    1. Double-click.
rem    2. Reproduce the failure: finish the prologue, leave the garage, wait
rem       for the audio to die, and try to go back to the menu.
rem    3. When it hangs, WAIT A FEW SECONDS before closing. In case something
rem       logs with a delay, give it time.
rem    4. Close it and report back. The file is logs\detallado.log
rem ===========================================================================

set "EXE="
rem nfsmw.exe FIRST: since the launcher took over the name
rem NFS_Most_Wanted.exe, the game in build\ is called that. The old name is
rem still checked afterward, for folders built before the change.
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
