@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul 2>&1

rem =============================================================================
rem  Construye Lanzador.exe
rem
rem  Compila tools\lanzador\Lanzador.cs con el compilador de C# que YA VIENE
rem  con Windows. No hay que instalar Visual Studio, ni el SDK de .NET, ni
rem  nada: csc.exe esta dentro de C:\Windows\Microsoft.NET\ desde Windows 8.
rem
rem  El icono y la portada quedan DENTRO del exe. Una vez construido, el
rem  Lanzador.exe se lleva solo a donde sea; no necesita las imagenes al lado.
rem
rem  EN build\ EL LANZADOR SE LLAMA NFS_Most_Wanted.exe
rem  ==================================================
rem  Y el juego pasa a llamarse nfsmw.exe, que es como se llama en el arbol del
rem  proyecto. El motivo es solo que al hacer doble clic en el icono del juego
rem  salga la ventana de opciones, como en cualquier juego con lanzador.
rem
rem  El juego SIGUE sabiendo arrancar solo: nfsmw.exe a pelo funciona igual que
rem  antes -se busca la ISO al lado y se pone gpu_plugin y mnk_mode el solo-,
rem  asi que ahi queda como salida por si el lanzador diera guerra.
rem
rem  Tampoco cambia donde guarda sus cosas el juego: esa carpeta sale de
rem  GetName() en el codigo, no del nombre del fichero.
rem
rem  El cambio de nombre se hace aqui abajo y es idempotente: si ya existe
rem  build\nfsmw.exe, es que ya se hizo y solo se refresca el lanzador.
rem
rem  Se puede llamar desde otro .bat con  /silencioso  para que no haga pausa.
rem
rem  OJO CON "RC": vcvars64 lo usa para el compilador de recursos, asi que en
rem  este proyecto los codigos de retorno van siempre en SALIDA.
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

rem ---- Que estan los ingredientes --------------------------------------------
rem
rem  Solo el codigo es obligatorio. La portada y el icono son la caratula del
rem  juego, arte de Electronic Arts, y por eso NO estan en el repositorio.
rem
rem  El lanzador arranca perfectamente sin ellas: CargarRecurso devuelve null si
rem  el recurso no esta y el panel lateral se dibuja en negro con el titulo. Asi
rem  que aqui se avisa y se sigue, en vez de negarse a compilar.
rem
rem  Si quieres poner las tuyas, ver docs\lanzador.md.
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

rem ---- Buscar csc.exe --------------------------------------------------------
rem
rem  Se prueba de mas nuevo a mas viejo. El v4.0.30319 esta en todos los Windows
rem  modernos; los v3.5 y v2.0 son de Windows 7 y tan antiguos que ni se
rem  intentan, porque WinForms de esa epoca no trae cosas que se usan aqui.
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

rem ---- Compilar --------------------------------------------------------------
rem
rem  /target:winexe  y no /target:exe, para que no salga una ventana negra de
rem                  consola detras del lanzador.
rem  /win32icon      el icono que ve el explorador de archivos.
rem  /resource       mete la portada DENTRO del exe. El nombre de despues de la
rem                  coma es el que busca el codigo, asi que tiene que ser
rem                  exactamente "portada.jpg".
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

rem ---- Ponerlo en la carpeta repartible ---------------------------------------
rem
rem  Aqui es donde el lanzador toma el nombre del juego. Dos casos, y se
rem  distinguen por si existe ya build\nfsmw.exe:
rem
rem    todavia no    build\NFS_Most_Wanted.exe es EL JUEGO. Se le cambia el
rem                  nombre a nfsmw.exe y el lanzador ocupa su sitio.
rem    ya hecho      build\nfsmw.exe existe, o sea que NFS_Most_Wanted.exe ya
rem                  es un lanzador de una vez anterior. Solo se refresca.
rem
rem  Asi se puede ejecutar esto las veces que haga falta sin romper nada, que
rem  es justo lo que pasa cuando lo llama DIST.bat en cada reconstruccion.
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
