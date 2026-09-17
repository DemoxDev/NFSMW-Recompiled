# =============================================================================
#  Boot matrix: launches the game many times, under different conditions,
#  and reports which ones died.
#
#  WHAT IT'S FOR
#  The bug we're chasing is a RACE: the same binary boots on one machine and
#  dies on another, and sometimes on the same machine it depends on the day.
#  A single run proves nothing -neither that it works nor that it doesn't-.
#  What's needed is a table: "this combination died 4 out of 5 times".
#
#  TWO THINGS THIS SCRIPT DOES THAT A DOUBLE-CLICK DOESN'T
#
#  1. Clears the shader cache on every attempt.
#     This is what changes timing the most. With the cache populated,
#     initialization pauses for two and a half seconds right where the
#     problem thread starts, and that pause HIDES the race. With an empty
#     cache it's 3 milliseconds. That's why a slow machine with cache
#     "works" and a fast one without cache doesn't: it's not the hardware,
#     it's the breathing room.
#
#     Achieved with --user_data_root pointing at a fresh folder every time.
#
#  2. Repeats. A race doesn't fail every time; it fails often. Without
#     repetitions, a single "it worked" is just noise.
#
#  WHY THE LOG LEVEL IS "info" AND NOT "debug"
#  Because writing the log takes time, and that time can hide the exact race
#  we're looking for. With -Detallado it can be raised, but then a "doesn't
#  fail" is worth less: the log itself might be masking it.
#
#      powershell -ExecutionPolicy Bypass -File tools\matriz.ps1
#      powershell -ExecutionPolicy Bypass -File tools\matriz.ps1 -Repeticiones 10
#      powershell -ExecutionPolicy Bypass -File tools\matriz.ps1 -Segundos 45 -Detallado
#
#  Works the same whether run from the project's tools\ or copied inside
#  build\, so it can be handed to whoever has the portable folder.
# =============================================================================

param(
    [string]$Exe = '',
    [int]$Repeticiones = 5,
    [int]$Segundos = 25,
    [switch]$Detallado
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- Locate the executable ---------------------------------------------------
if (-not $Exe) {
    # nfsmw.exe FIRST: ever since the launcher took over the name
    # NFS_Most_Wanted.exe, the game in build\ is called that. The old names
    # are still checked afterward, for folders from before the change.
    $candidatos = @(
        (Join-Path $PSScriptRoot 'nfsmw.exe')                                 # inside build\
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

# ---- Check that there's an ISO ------------------------------------------------
$isos = @(Get-ChildItem -LiteralPath $CarpEx -File -Filter '*.iso' -ErrorAction SilentlyContinue)
if ($isos.Count -eq 0) {
    Write-Host "No hay ninguna .iso junto al ejecutable:" -ForegroundColor Red
    Write-Host "  $CarpEx"
    exit 1
}

# ---- The combinations ---------------------------------------------------------
#
# Only THREAD SCHEDULING things are tested, since that's where the suspicion
# lives. Both cvars default to true: the SDK ignores both the priorities and
# the affinities the game requests. Setting them to false gives the game back
# the order it asked for itself, and that holds for any machine, which is
# the whole point.
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

# ---- Classify a log -------------------------------------------------------
#
# Returns a short label. It matters to distinguish WHAT failed, not just that
# it failed: if a combination changes the error, that's already information.
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

# ---- A single attempt ----------------------------------------------------------
function UnIntento($combo, [int]$n) {
    # FRESH data folder: this is what clears the shader cache and removes
    # the 2.5 s pause that hides the race.
    $datos = Join-Path $raizTmp ("run_{0}" -f [Guid]::NewGuid().ToString('N').Substring(0,6))
    $log   = Join-Path $salida  ("{0}_{1}.log" -f ($combo.Nombre -replace '[^\w]','_'), $n)
    if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }

    # NOTE: the variable is NOT called $args. In PowerShell $args is
    # automatic -inside a function it holds the unbound arguments- and
    # shadowing it is one of those mistakes that stays hidden until it
    # causes a weird problem.
    $argumentos = @(
        '--log_level', $nivel
        '--log_file', ('"{0}"' -f $log)
        '--user_data_root', ('"{0}"' -f $datos)
        '--fullscreen=false'          # not fullscreen: it can be killed without drama
        '--readback_resolve=fast'     # the usual one, otherwise the image comes out washed out
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
        # Survived the wait. For what we're after, that's a good boot.
        #
        # THE [void] IS NOT REDUNDANT. WaitForExit(int) returns a bool, and in
        # PowerShell any value that isn't captured goes into the function's
        # OUTPUT stream and gets mixed in with the return. Without this,
        # UnIntento wouldn't return the results table but rather
        # @($true, @{Estado=...}), and the caller would get an array where it
        # expected an object.
        try { $p.Kill(); [void]$p.WaitForExit(5000) } catch { }
        # The log is still checked anyway: it might have survived while spewing errors.
        $c = Clasificar $log
        if ($c -in @('murio sin decir nada','salio solo')) {
            return @{ Estado = 'OK'; Detalle = '' }
        }
        return @{ Estado = 'OK'; Detalle = "pero el log dice: $c" }
    }

    return @{ Estado = 'FALLO'; Detalle = (Clasificar $log) }
}

# ---- Walk the matrix -----------------------------------------------------------
$tabla = @()
foreach ($combo in $combos) {
    Write-Host ("-- {0}" -f $combo.Nombre)
    $ok = 0; $mal = 0; $motivos = @{}

    for ($i = 1; $i -le $Repeticiones; $i++) {
        $r = UnIntento $combo $i

        # SAFETY NET, not a patch. If some call writes to the output stream
        # again without capturing it, an array would arrive here instead of
        # an object. Instead of dying with "property Estado not found", the
        # last element -which is the real return value- is taken and a
        # WARNING IS SHOWN, so the bug gets fixed instead of staying hidden.
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

# ---- Cleanup and summary --------------------------------------------------------
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
