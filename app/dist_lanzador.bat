@echo off
setlocal
cd /d "%~dp0"

rem ===========================================================================
rem  LAUNCHER - the normal way to play.
rem
rem  Opens a window to choose resolution, fullscreen or windowed, the ISO,
rem  vsync, and fps limit. Remembers your choices for next time.
rem
rem  If you'd rather just play, you can also open nfsmw.exe directly: it
rem  will pick up whichever ISO it finds in this folder and the settings
rem  from nfsmw.toml.
rem ===========================================================================

if not exist "%~dp0lanzador.ps1" (
    echo [ERROR] Falta lanzador.ps1 en esta carpeta.
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

where powershell >nul 2>&1
if errorlevel 1 (
    echo [ERROR] No encuentro Windows PowerShell.
    echo         Abre nfsmw.exe directamente.
    echo.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lanzador.ps1"
