@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul 2>&1

rem =============================================================================
rem  Builds Lanzador.exe
rem
rem  Compiles tools\lanzador\Lanzador.cs with the C# compiler that ALREADY
rem  SHIPS with Windows. No need to install Visual Studio, or the .NET SDK,
rem  or anything: csc.exe has been inside C:\Windows\Microsoft.NET\ since
rem  Windows 8.
rem
rem  The icon and cover art end up INSIDE the exe. Once built, Lanzador.exe
rem  can be carried anywhere on its own; it doesn't need the images next to it.
rem
rem  IN build\ THE LAUNCHER IS CALLED NFS_Most_Wanted.exe
rem  ==================================================
rem  And the game gets renamed to nfsmw.exe, which is what it's called in the
rem  project tree. The only reason is so that double-clicking the game's icon
rem  brings up the options window, like in any game with a launcher.
rem
rem  The game STILL knows how to start on its own: nfsmw.exe by itself works
rem  just like before -it looks for the ISO next to it and sets gpu_plugin and
rem  mnk_mode on its own-, so it stays there as a fallback in case the
rem  launcher gives trouble.
rem
rem  It also doesn't change where the game stores its data: that folder comes
rem  from GetName() in the code, not from the filename.
rem
rem  The rename happens further down and is idempotent: if build\nfsmw.exe
rem  already exists, it means this already ran and only the launcher gets
rem  refreshed.
rem
rem  Can be called from another .bat with  /silencioso  so it doesn't pause.
rem
rem  WATCH OUT FOR "RC": vcvars64 uses it for the resource compiler, so in
rem  this project return codes always go in SALIDA.
rem =============================================================================

set "RAIZ=%~dp0"
if "%RAIZ:~-1%"=="\" set "RAIZ=%RAIZ:~0,-1%"
set "FUENTE=%RAIZ%\tools\lanzador"
set "SALIDA_EXE=%RAIZ%\Lanzador.exe"

set "SILENCIOSO="
if /i "%~1"=="/silencioso" set "SILENCIOSO=1"

echo.
echo  ======================================================================
echo   Lanzador de NFS Most Wanted - Recompilacion
echo  ======================================================================
echo.

rem ---- Check that the ingredients are there -----------------------------------
rem
rem  Only the code is required. The cover art and icon are the game's box
rem  art, Electronic Arts' artwork, and that's why they're NOT in the
rem  repository.
rem
rem  The launcher starts up perfectly fine without them: CargarRecurso
rem  returns null if the resource isn't there and the side panel draws in
rem  black with the title. So here it just warns and continues, instead of
rem  refusing to compile.
rem
rem  If you want to add your own, see docs\lanzador.md.
if not exist "%FUENTE%\Lanzador.cs" (
    echo  [ERROR] Falta %FUENTE%\Lanzador.cs
    echo.
    echo  Es el codigo del lanzador y sin el no hay nada que compilar.
    goto :fin_mal
)

set "ARG_ICONO="
set "ARG_PORTADA="
if exist "%FUENTE%\icono.ico" (
    set "ARG_ICONO=/win32icon:"%FUENTE%\icono.ico""
) else (
    echo  [aviso] No hay icono.ico. El exe saldra con el icono generico.
)
if exist "%FUENTE%\portada.jpg" (
    set "ARG_PORTADA=/resource:"%FUENTE%\portada.jpg",portada.jpg"
) else (
    echo  [aviso] No hay portada.jpg. El panel lateral saldra en negro.
)

rem ---- Find csc.exe ------------------------------------------------------------
rem
rem  Tried newest to oldest. v4.0.30319 is on every modern Windows; v3.5 and
rem  v2.0 are from Windows 7 and old enough that they're not even attempted,
rem  because WinForms from that era doesn't have things used here.
set "CSC="
for %%D in (Framework64 Framework) do (
    if not defined CSC (
        if exist "%WINDIR%\Microsoft.NET\%%D\v4.0.30319\csc.exe" (
            set "CSC=%WINDIR%\Microsoft.NET\%%D\v4.0.30319\csc.exe"
        )
    )
)

if not defined CSC (
    echo  [ERROR] No encuentro el compilador de C# de Windows.
    echo.
    echo  Se ha buscado en:
    echo     %WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
    echo     %WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
    echo.
    echo  Eso viene con el .NET Framework 4, que trae Windows de serie. Si no
    echo  esta, se activa en:
    echo     Panel de control ^> Programas ^> Activar o desactivar las
    echo     caracteristicas de Windows ^> .NET Framework 4.x
    echo.
    echo  Mientras tanto sigues teniendo LANZADOR.bat, que hace lo mismo.
    goto :fin_mal
)

echo  Compilador:  %CSC%
echo  Fuente:      %FUENTE%\Lanzador.cs
echo  Destino:     %SALIDA_EXE%
echo.

rem ---- Compile -----------------------------------------------------------------
rem
rem  /target:winexe  and not /target:exe, so no black console window shows up
rem                  behind the launcher.
rem  /win32icon      the icon the file explorer sees.
rem  /resource       puts the cover art INSIDE the exe. The name after the
rem                  comma is what the code looks for, so it has to be
rem                  exactly "portada.jpg".
echo  Compilando...
"%CSC%" /nologo /target:winexe /optimize+ /platform:anycpu ^
    /out:"%SALIDA_EXE%" ^
    %ARG_ICONO% ^
    %ARG_PORTADA% ^
    /reference:System.dll ^
    /reference:System.Drawing.dll ^
    /reference:System.Windows.Forms.dll ^
    "%FUENTE%\Lanzador.cs"
set SALIDA=%ERRORLEVEL%

if not "%SALIDA%"=="0" (
    echo.
    echo  [ERROR] La compilacion ha fallado ^(codigo %SALIDA%^).
    echo.
    echo  Los errores de arriba llevan numero de linea de Lanzador.cs. Si
    echo  hablan de caracteres raros o de ';' que faltan, casi seguro es que
    echo  este Windows trae un csc mas antiguo de lo que se esperaba.
    goto :fin_mal
)

if not exist "%SALIDA_EXE%" (
    echo.
    echo  [ERROR] El compilador dijo que si, pero no hay ningun Lanzador.exe.
    goto :fin_mal
)

rem ---- Put it in the distributable folder --------------------------------------
rem
rem  This is where the launcher takes over the game's name. Two cases,
rem  distinguished by whether build\nfsmw.exe already exists:
rem
rem    not yet       build\NFS_Most_Wanted.exe is THE GAME. It gets renamed
rem                  to nfsmw.exe and the launcher takes its place.
rem    already done  build\nfsmw.exe exists, meaning NFS_Most_Wanted.exe is
rem                  already a launcher from a previous run. Just refreshed.
rem
rem  This way it can be run as many times as needed without breaking
rem  anything, which is exactly what happens when DIST.bat calls it on every
rem  rebuild.
set "DESTINO=%RAIZ%\build"
if not exist "%DESTINO%" goto sin_build

if not exist "%DESTINO%\nfsmw.exe" (
    if exist "%DESTINO%\NFS_Most_Wanted.exe" (
        echo  Renombrando el juego a nfsmw.exe para dejarle el nombre al lanzador...
        move /Y "%DESTINO%\NFS_Most_Wanted.exe" "%DESTINO%\nfsmw.exe" >nul
        if errorlevel 1 (
            echo  [ERROR] No he podido renombrarlo. Tienes el juego abierto?
            goto :fin_mal
        )
    ) else (
        echo  [aviso] En build\ no hay ni nfsmw.exe ni NFS_Most_Wanted.exe.
        echo          Ejecuta DIST.bat para armar la carpeta portable.
        goto sin_build
    )
)

copy /Y "%SALIDA_EXE%" "%DESTINO%\NFS_Most_Wanted.exe" >nul
if errorlevel 1 (
    echo  [aviso] No he podido copiarlo a build\. Estara abierto?
) else (
    set "PUESTO=1"
)

:sin_build
echo.
echo  ======================================================================
echo   LISTO
echo  ======================================================================
echo.
echo   Lanzador.exe               en la raiz del proyecto
if defined PUESTO (
    echo   build\NFS_Most_Wanted.exe  el lanzador, con el icono del juego
    echo   build\nfsmw.exe            el juego de verdad
    echo.
    echo   Doble clic en NFS_Most_Wanted.exe abre la ventana de opciones, y
    echo   desde ahi se juega. nfsmw.exe a pelo tambien sigue funcionando.
)
echo.
echo   El icono y la portada van dentro del exe, asi que se puede mover
echo   solo, sin llevarse nada al lado.
echo.
echo   Los ajustes son los mismos de siempre ^(lanzador.json^), asi que lo
echo   que ya tenias configurado sigue puesto. LANZADOR.bat sigue ahi por
echo   si lo prefieres.
echo.
if not defined SILENCIOSO pause
exit /b 0

:fin_mal
echo.
if not defined SILENCIOSO pause
exit /b 1
