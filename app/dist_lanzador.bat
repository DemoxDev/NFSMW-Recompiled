@echo off
setlocal
cd /d "%~dp0"

rem ===========================================================================
rem  LANZADOR - la forma normal de jugar.
rem
rem  Abre una ventana donde elegir resolucion, pantalla completa o ventana,
rem  la ISO, vsync y limite de fps. Recuerda lo que elijas para la proxima vez.
rem
rem  Si prefieres jugar sin mas, tambien puedes abrir nfsmw.exe
rem  directamente: cogera la ISO que encuentre en esta carpeta y los ajustes
rem  de nfsmw.toml.
rem ===========================================================================

if not exist "%~dp0lanzador.ps1" (
    echo [ERROR] Falta lanzador.ps1 en esta carpeta.
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

where powershell >nul 2>&1
if errorlevel 1 (
    echo [ERROR] No encuentro Windows PowerShell.
    echo         Abre nfsmw.exe directamente.
    echo.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lanzador.ps1"
