@echo off
title NFSMW Recomp - Fase 1: extraer el ISO
cd /d "%~dp0"

echo ============================================
echo   NFSMW Recomp - Fase 1
echo   Extraer el ISO y leer la cabecera del XEX
echo ============================================
echo.

rem --- locate Python ----------------------------------------------------------
set "PY="
py -3 --version >nul 2>nul && set "PY=py -3"
if not defined PY (
    python --version >nul 2>nul && set "PY=python"
)
if not defined PY (
    echo [ERROR] No se encontro Python en el PATH.
    echo.
    echo Instalalo desde https://www.python.org/downloads/
    echo IMPORTANTE: marca la casilla "Add Python to PATH" durante la instalacion.
    echo.
    pause
    exit /b 1
)

for /f "delims=" %%v in ('%PY% --version 2^>^&1') do set "PYVER=%%v"
echo Python detectado: %PYVER%
echo.

rem --- menu ---------------------------------------------------------------------
echo Que quieres hacer?
echo.
echo   1. Solo listar el contenido del ISO  (rapido, no escribe nada)
echo   2. Extraer TODO                      (~7 GB, varios minutos)
echo   3. Extraer solo el default.xex       (rapido, unos MB)
echo   4. Ver la cabecera de assets\default.xex
echo.
set /p OPCION="Elige 1-4 y pulsa Enter: "
echo.

if "%OPCION%"=="1" goto listar
if "%OPCION%"=="2" goto extraer_todo
if "%OPCION%"=="3" goto extraer_xex
if "%OPCION%"=="4" goto info
echo Opcion no valida.
goto fin

:listar
%PY% tools\fase1_extraer.py --listar
goto fin

:extraer_todo
%PY% tools\fase1_extraer.py -o assets\game_root
if errorlevel 1 goto fin
call :copiar_xex
goto fin

:extraer_xex
%PY% tools\fase1_extraer.py -o assets\game_root --solo-xex
if errorlevel 1 goto fin
call :copiar_xex
goto fin

:copiar_xex
if exist "assets\game_root\default.xex" (
    copy /y "assets\game_root\default.xex" "assets\default.xex" >nul
    echo.
    echo default.xex copiado a assets\default.xex
    if not exist "docs" mkdir "docs"
    %PY% tools\fase1_extraer.py "assets\default.xex" --info > "docs\xex_info.txt"
    echo Cabecera guardada en docs\xex_info.txt
    echo.
    type "docs\xex_info.txt"
) else (
    echo.
    echo [AVISO] No aparecio un default.xex en la raiz del ISO.
    echo Lanza la opcion 1 para ver donde esta el ejecutable.
)
exit /b 0

:info
if not exist "assets\default.xex" (
    echo No existe assets\default.xex todavia. Usa la opcion 2 o 3 primero.
    goto fin
)
%PY% tools\fase1_extraer.py "assets\default.xex" --info
goto fin

:fin
echo.
echo ============================================
pause
