# =============================================================================
#  Matriz de arranque: lanza el juego muchas veces, en distintas condiciones,
#  y dice en cuales murio.
#
#  PARA QUE SIRVE
#  El fallo que perseguimos es una CARRERA: el mismo binario arranca en una
#  maquina y muere en otra, y a veces en la misma maquina depende del dia. Un
#  arranque suelto no prueba nada -ni que funcione ni que no-. Lo que hace
#  falta es una tabla: "esta combinacion murio 4 de 5 veces".
#
#  DOS COSAS QUE ESTE SCRIPT HACE Y QUE UN DOBLE CLIC NO
#
#  1. Vacia la cache de shaders en cada intento.
#     Es lo que mas timing cambia. Con la cache poblada, la inicializacion se
#     para dos segundos y medio justo donde arranca el hilo problematico, y esa
#     pausa TAPA la carrera. Con la cache vacia son 3 milisegundos. Por eso una
#     maquina lenta con cache "funciona" y una rapida sin cache no: no es el
#     hardware, es la tregua.
#
#     Se consigue con --user_data_root a una carpeta nueva cada vez.
#
#  2. Repite. Una carrera no falla siempre; falla a menudo. Sin repeticiones,
#     un "ha funcionado" es ruido.
#
#  POR QUE EL NIVEL DE LOG ES "info" Y NO "debug"
#  Porque escribir el log cuesta tiempo, y ese tiempo puede tapar justo la
#  carrera que buscamos. Con -Detallado se puede subir, pero entonces un "no
#  falla" vale menos: puede ser que el propio log lo este escondiendo.
#
#      powershell -ExecutionPolicy Bypass -File tools\matriz.ps1
#      powershell -ExecutionPolicy Bypass -File tools\matriz.ps1 -Repeticiones 10
#      powershell -ExecutionPolicy Bypass -File tools\matriz.ps1 -Segundos 45 -Detallado
#
#  Funciona igual desde tools\ del proyecto que copiado dentro de build\, asi
#  que se le puede pasar a quien tenga la carpeta portable.
# =============================================================================

param(
    [string]$Exe = '',
    [int]$Repeticiones = 5,
    [int]$Segundos = 25,
    [switch]$Detallado
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- Localizar el ejecutable ------------------------------------------------
if (-not $Exe) {
    # nfsmw.exe PRIMERO: desde que el lanzador ocupa el nombre
    # NFS_Most_Wanted.exe, el juego en build\ se llama asi. Los nombres
    # viejos se siguen mirando detras, para carpetas de antes del cambio.
    $candidatos = @(
        (Join-Path $PSScriptRoot 'nfsmw.exe')                                 # dentro de build\
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\nfsmw.exe')
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'app\out\build\win-amd64-release\nfsmw.exe')
        (Join-Path $PSScriptRoot 'NFS_Most_Wanted.exe')
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\NFS_Most_Wanted.exe')
    )
    foreach ($c in $candidatos) {
        if (Test-Path -LiteralPath $c) { $Exe = $c; break }
    }
}
if (-not $Exe -or -not (Test-Path -LiteralPath $Exe)) {
    Write-Host 'No encuentro el ejecutable.' -ForegroundColor Red
    Write-Host 'Pasalo a mano:  -Exe "C:\ruta\nfsmw.exe"'
    exit 1
}
$Exe    = (Resolve-Path -LiteralPath $Exe).Path
$CarpEx = Split-Path -Parent $Exe

# ---- Comprobar que hay ISO --------------------------------------------------
$isos = @(Get-ChildItem -LiteralPath $CarpEx -File -Filter '*.iso' -ErrorAction SilentlyContinue)
if ($isos.Count -eq 0) {
    Write-Host "No hay ninguna .iso junto al ejecutable:" -ForegroundColor Red
    Write-Host "  $CarpEx"
    exit 1
}

# ---- Las combinaciones ------------------------------------------------------
#
# Se prueban solo cosas de PLANIFICACION DE HILOS, que es donde vive la
# sospecha. Los dos cvars vienen a true de fabrica: el SDK ignora tanto las
# prioridades como las afinidades que pide el juego. Ponerlos a false devuelve
# al juego el orden que el mismo pidio, y eso vale para cualquier maquina, que
# es de lo que se trata.
$combos = @(
    @{ Nombre = 'base (como esta ahora)';        Args = @() }
    @{ Nombre = 'respetar prioridades';          Args = @('--ignore_thread_priorities=false') }
    @{ Nombre = 'respetar afinidades';           Args = @('--ignore_thread_affinities=false') }
    @{ Nombre = 'respetar las dos';              Args = @('--ignore_thread_priorities=false',
                                                          '--ignore_thread_affinities=false') }
)

$nivel   = if ($Detallado) { 'debug' } else { 'info' }
$raizTmp = Join-Path $env:TEMP ('nfsmw_matriz_' + [Guid]::NewGuid().ToString('N').Substring(0,8))
$salida  = Join-Path $CarpEx 'matriz'
New-Item -ItemType Directory -Path $salida -Force | Out-Null

Write-Host ''
Write-Host '============================================'
Write-Host '  Matriz de arranque'
Write-Host '============================================'
Write-Host ''
Write-Host "  Ejecutable : $Exe"
Write-Host "  ISO        : $($isos[0].Name)"
Write-Host "  Intentos   : $Repeticiones por combinacion"
Write-Host "  Espera     : $Segundos s antes de dar un arranque por bueno"
Write-Host "  Nivel log  : $nivel"
if ($Detallado) {
    Write-Host '  AVISO: con debug el log cuesta tiempo y puede TAPAR la carrera.' -ForegroundColor DarkYellow
    Write-Host '         Un "no falla" con debug vale menos que uno con info.' -ForegroundColor DarkYellow
}
Write-Host ''
Write-Host "  Peor caso: unos $([Math]::Round($combos.Count * $Repeticiones * $Segundos / 60.0, 1)) min."
Write-Host '  Los arranques que fallan mueren en un segundo, asi que sera menos.'
Write-Host ''

# ---- Clasificar un log ------------------------------------------------------
#
# Devuelve una etiqueta corta. Interesa distinguir QUE fallo, no solo que
# fallo: si una combinacion cambia el error, eso ya es informacion.
function Clasificar([string]$log) {
    if (-not (Test-Path -LiteralPath $log)) { return 'sin log' }
    $t = Get-Content -LiteralPath $log -Raw -ErrorAction SilentlyContinue
    if (-not $t) { return 'log vacio' }

    if ($t -match 'No function registered at ([0-9A-Fa-f]+)')      { return "sin funcion $($Matches[1])" }
    if ($t -match 'access violation: read of guest (0x[0-9A-Fa-f]+)')  { return "lectura nula $($Matches[1])" }
    if ($t -match 'access violation: write of guest (0x[0-9A-Fa-f]+)') { return "escritura nula $($Matches[1])" }
    if ($t -match 'Unhandled guest access violation')               { return 'access violation' }
    if ($t -match 'game_data_root')                                 { return 'falta la ISO' }
    if ($t -match '\[critical\]')                                   { return 'critical' }
    if ($t -match 'Execution complete')                             { return 'salio solo' }
    return 'murio sin decir nada'
}

# ---- Un intento -------------------------------------------------------------
function UnIntento($combo, [int]$n) {
    # Carpeta de datos NUEVA: esto es lo que vacia la cache de shaders y quita
    # la pausa de 2,5 s que tapa la carrera.
    $datos = Join-Path $raizTmp ("run_{0}" -f [Guid]::NewGuid().ToString('N').Substring(0,6))
    $log   = Join-Path $salida  ("{0}_{1}.log" -f ($combo.Nombre -replace '[^\w]','_'), $n)
    if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }

    # OJO: la variable NO se llama $args. En PowerShell $args es automatica
    # -dentro de una funcion contiene los argumentos no enlazados- y pisarla
    # es de los errores que no dan la cara hasta que dan un problema raro.
    $argumentos = @(
        '--log_level', $nivel
        '--log_file', ('"{0}"' -f $log)
        '--user_data_root', ('"{0}"' -f $datos)
        '--fullscreen=false'          # sin pantalla completa: se puede matar sin drama
        '--readback_resolve=fast'     # el de siempre, si no la imagen sale lavada
    ) + $combo.Args

    $p = $null
    try {
        $p = Start-Process -FilePath $Exe -ArgumentList ($argumentos -join ' ') `
                           -WorkingDirectory $CarpEx -PassThru
    } catch {
        return @{ Estado = 'no arranco'; Detalle = $_.Exception.Message }
    }

    $vivo = -not $p.WaitForExit($Segundos * 1000)

    if ($vivo) {
        # Sobrevivio la espera. Para lo que buscamos, eso es un arranque bueno.
        #
        # EL [void] NO SOBRA. WaitForExit(int) devuelve un bool, y en PowerShell
        # todo valor que no se captura se va al flujo de SALIDA de la funcion y
        # se mezcla con el return. Sin esto, UnIntento no devolvia la tabla de
        # resultados sino @($true, @{Estado=...}), y quien la llamaba recibia un
        # array donde esperaba un objeto.
        try { $p.Kill(); [void]$p.WaitForExit(5000) } catch { }
        # Aun asi se mira el log: puede haber sobrevivido escupiendo errores.
        $c = Clasificar $log
        if ($c -in @('murio sin decir nada','salio solo')) {
            return @{ Estado = 'OK'; Detalle = '' }
        }
        return @{ Estado = 'OK'; Detalle = "pero el log dice: $c" }
    }

    return @{ Estado = 'FALLO'; Detalle = (Clasificar $log) }
}

# ---- Recorrer la matriz -----------------------------------------------------
$tabla = @()
foreach ($combo in $combos) {
    Write-Host ("-- {0}" -f $combo.Nombre)
    $ok = 0; $mal = 0; $motivos = @{}

    for ($i = 1; $i -le $Repeticiones; $i++) {
        $r = UnIntento $combo $i

        # RED DE SEGURIDAD, no parche. Si alguna llamada vuelve a escribir al
        # flujo de salida sin capturar, aqui llegaria un array en vez de un
        # objeto. En vez de morir con "no se encuentra la propiedad Estado", se
        # coge el ultimo -que es el return de verdad- y SE AVISA, para que el
        # fallo se arregle en lugar de quedarse escondido.
        if ($r -is [System.Array]) {
            Write-Host ''
            Write-Host ("   [aviso interno] UnIntento devolvio {0} valores; algo escribe al flujo de salida." -f $r.Count) -ForegroundColor DarkYellow
            $r = $r[-1]
        }

        if ($r.Estado -eq 'OK') {
            $ok++
            Write-Host '   .' -NoNewline -ForegroundColor DarkGreen
        } else {
            $mal++
            Write-Host '   X' -NoNewline -ForegroundColor Red
            $d = [string]$r.Detalle
            if ($d) { $motivos[$d] = 1 + $(if ($motivos.ContainsKey($d)) { $motivos[$d] } else { 0 }) }
        }
    }
    Write-Host ''
    $det = ($motivos.Keys | Sort-Object) -join '; '
    Write-Host ("   {0}/{1} arrancaron{2}" -f $ok, $Repeticiones,
                $(if ($det) { "   ->  $det" } else { '' }))
    Write-Host ''

    $tabla += [pscustomobject]@{
        Combinacion = $combo.Nombre
        Arrancaron  = "$ok/$Repeticiones"
        Fallos      = $mal
        Motivo      = $det
    }
}

# ---- Limpieza y resumen -----------------------------------------------------
if (Test-Path -LiteralPath $raizTmp) {
    Remove-Item -LiteralPath $raizTmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '============================================'
Write-Host '  RESUMEN'
Write-Host '============================================'
$tabla | Format-Table -AutoSize | Out-String | Write-Host

$buenas = @($tabla | Where-Object { $_.Fallos -eq 0 })
$malas  = @($tabla | Where-Object { $_.Fallos -eq $Repeticiones })

if ($buenas.Count -eq $tabla.Count) {
    Write-Host '  Todas arrancaron siempre.' -ForegroundColor Green
    Write-Host ''
    Write-Host '  Ojo con lo que esto significa y lo que no. En ESTA maquina, con'
    Write-Host '  la cache vacia, no se reproduce. No prueba que este arreglado:'
    Write-Host '  una carrera puede necesitar mas nucleos o mas velocidad. Que lo'
    Write-Host '  lance tambien quien SI lo ve fallar.'
} elseif ($buenas.Count -gt 0) {
    Write-Host '  HAY COMBINACIONES QUE NO FALLAN NUNCA:' -ForegroundColor Green
    foreach ($b in $buenas) { Write-Host ("    - {0}" -f $b.Combinacion) }
    Write-Host ''
    Write-Host '  Eso es una pista de verdad, no un parche por maquina: si respetar'
    Write-Host '  las prioridades arregla el arranque, es que el juego CONTABA con'
    Write-Host '  ese orden y el SDK lo estaba tirando.'
} else {
    Write-Host '  Fallaron todas.' -ForegroundColor Red
    Write-Host '  La planificacion de hilos no es la causa, o no es la unica.'
    Write-Host '  Los logs de cada intento estan en:  matriz\'
}

if ($malas.Count -eq $tabla.Count -and $Repeticiones -gt 1) {
    Write-Host ''
    Write-Host '  Falla el 100% de las veces, asi que probablemente NO sea una'
    Write-Host '  carrera sino un fallo determinista. Eso es mejor: se depura'
    Write-Host '  mucho mas facil.' -ForegroundColor DarkYellow
}

$csv = Join-Path $salida 'resumen.csv'
$tabla | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
Write-Host ''
Write-Host "  Tabla:  $csv"
Write-Host "  Logs :  $salida"
Write-Host ''
