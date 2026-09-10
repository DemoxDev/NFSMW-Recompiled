@echo off
setlocal
cd /d "%~dp0"

echo ============================================
echo   NFSMW Recomp - Mapa de huecos de codigo
echo ============================================
echo.
echo No compila nada: solo lee el C++ generado y calcula donde hay
echo codigo sin funcion asignada. Es donde viven las llamadas
echo indirectas que revientan el arranque.
echo.

set "PY="
py -3 --version >nul 2>nul && set "PY=py -3"
if not defined PY (
    python --version >nul 2>nul && set "PY=python"
)
if not defined PY (
    echo [ERROR] No se encontro Python.
    pause
    exit /b 1
)

if not exist "logs" mkdir "logs"

%PY% tools\huecos.py --min 8 --comprobar 0x82869668 0x8220C090 0x8285CB90 0x8215FEA8 0x826BE258 0x824EDEB0 0x8285CE80

echo.
echo ============================================
pause
