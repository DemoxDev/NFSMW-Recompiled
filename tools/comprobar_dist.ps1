# =============================================================================
#  Checks that build\ -the portable folder- is REALLY self-contained.
#
#  It doesn't guess: it reads the PE import table of every .exe and .dll in
#  the folder, follows the dependency chain, and for each DLL decides whether
#
#    - it's in the folder itself             -> fine, it ships with the game
#    - it's a Windows DLL                    -> fine, it's on any machine
#    - it's neither one nor the other        -> MISSING, and says so by name
#
#  It's the only honest way to answer "will this work on a clean PC" without
#  having a clean PC in front of you.
#
#      powershell -ExecutionPolicy Bypass -File tools\comprobar_dist.ps1
#      powershell -ExecutionPolicy Bypass -File tools\comprobar_dist.ps1 -Dist "D:\otra\carpeta"
# =============================================================================

param(
    [string]$Dist = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Dist) {
    $Dist = Join-Path (Split-Path -Parent $PSScriptRoot) 'build'
}

if (-not (Test-Path -LiteralPath $Dist)) {
    Write-Host "No encuentro la carpeta: $Dist" -ForegroundColor Red
    Write-Host "Genera la build portable primero:  DIST.bat"
    exit 1
}

# -----------------------------------------------------------------------------
#  PE import table reader.
#
#  It's done by hand and not with dumpbin on purpose: dumpbin comes with
#  Visual Studio, and the whole point of this script is to check things
#  WITHOUT assuming that dev tools are installed.
# -----------------------------------------------------------------------------
function Get-PeImports([string]$Ruta) {
    $b = [System.IO.File]::ReadAllBytes($Ruta)
    if ($b.Length -lt 0x40) { return @() }
    $pe = [BitConverter]::ToInt32($b, 0x3C)
    if ($pe -le 0 -or $pe + 24 -ge $b.Length) { return @() }
    if ($b[$pe] -ne 0x50 -or $b[$pe+1] -ne 0x45) { return @() }   # "PE"

    $nsec  = [BitConverter]::ToUInt16($b, $pe + 6)
    $optsz = [BitConverter]::ToUInt16($b, $pe + 20)
    $opt   = $pe + 24
    $magic = [BitConverter]::ToUInt16($b, $opt)
    $pe32p = ($magic -eq 0x20b)
    $dd    = $opt + $(if ($pe32p) { 112 } else { 96 })
    $impRva = [BitConverter]::ToUInt32($b, $dd + 8)
    if ($impRva -eq 0) { return @() }

    # Sections, to translate RVA to a file offset.
    $secs = @()
    $so = $opt + $optsz
    for ($i = 0; $i -lt $nsec; $i++) {
        $s = $so + $i * 40
        $secs += [pscustomobject]@{
            Va  = [BitConverter]::ToUInt32($b, $s + 12)
            Sz  = [Math]::Max([BitConverter]::ToUInt32($b, $s + 8),
                              [BitConverter]::ToUInt32($b, $s + 16))
            Raw = [BitConverter]::ToUInt32($b, $s + 20)
        }
    }
    function RvaToOff($rva) {
        foreach ($s in $secs) {
            if ($rva -ge $s.Va -and $rva -lt ($s.Va + $s.Sz)) { return $s.Raw + ($rva - $s.Va) }
        }
        return -1
    }

    $nombres = @()
    $p = RvaToOff $impRva
    if ($p -lt 0) { return @() }
    while ($true) {
        if ($p + 20 -gt $b.Length) { break }
        $nameRva = [BitConverter]::ToUInt32($b, $p + 12)
        if ($nameRva -eq 0) { break }
        $no = RvaToOff $nameRva
        if ($no -lt 0) { break }
        $e = $no
        while ($e -lt $b.Length -and $b[$e] -ne 0) { $e++ }
        $nombres += [Text.Encoding]::ASCII.GetString($b, $no, $e - $no)
        $p += 20
    }
    return $nombres
}

# -----------------------------------------------------------------------------
#  What counts as "already comes with Windows".
#
#  The api-ms-win-* ones are the UCRT and the API sets, part of Windows 10 and
#  11. The rest is the list of system DLLs that these binaries touch.
# -----------------------------------------------------------------------------
$deWindows = @(
    'kernel32.dll','user32.dll','gdi32.dll','advapi32.dll','shell32.dll','ole32.dll',
    'oleaut32.dll','ws2_32.dll','winmm.dll','imm32.dll','version.dll','setupapi.dll',
    'hid.dll','bcrypt.dll','crypt32.dll','dxgi.dll','d3d12.dll','d3d11.dll',
    'dwmapi.dll','shcore.dll','comdlg32.dll','uxtheme.dll','powrprof.dll',
    'cfgmgr32.dll','ntdll.dll','rpcrt4.dll','secur32.dll','userenv.dll',
    'msvcrt.dll','dbghelp.dll','wintrust.dll','iphlpapi.dll','psapi.dll',
    'xinput1_4.dll','xinput9_1_0.dll','avrt.dll','mmdevapi.dll','propsys.dll',
    # The launcher is a .NET executable and the only thing it really imports
    # is mscoree.dll, the Common Language Runtime bootstrap. It's come with
    # Windows since XP SP3. Without this in the list, the check was reporting
    # the folder as broken right after assembling it correctly.
    'mscoree.dll','mscoreei.dll'
)

$enCarpeta = @{}
Get-ChildItem -LiteralPath $Dist -File | Where-Object { $_.Extension -in '.dll','.exe' } |
    ForEach-Object { $enCarpeta[$_.Name.ToLower()] = $_.FullName }

Write-Host ''
Write-Host '============================================'
Write-Host '  Comprobacion de la carpeta portable'
Write-Host '============================================'
Write-Host ''
Write-Host "  $Dist"
Write-Host ''

# ---- Contents ---------------------------------------------------------------
# @() IS NOT DECORATIVE. Get-ChildItem returns a LOOSE object when there's a
# single result, not a one-element array. With Set-StrictMode, asking that
# loose object for .Count throws PropertyNotFoundStrict and the script dies.
# Wrapping in @() forces an array always, whether it has 0, 1, or 20 elements.
$exes = @(Get-ChildItem -LiteralPath $Dist -File -Filter '*.exe')
$isos = @(Get-ChildItem -LiteralPath $Dist -File -Filter '*.iso')
$dlls = @(Get-ChildItem -LiteralPath $Dist -File -Filter '*.dll')

Write-Host 'CONTENIDO'
foreach ($f in (Get-ChildItem -LiteralPath $Dist -File | Sort-Object Name)) {
    $mb = [Math]::Round($f.Length / 1MB, 1)
    Write-Host ("   {0,-32} {1,8} MB" -f $f.Name, $mb)
}
Write-Host ''

$problemas = @()

if ($exes.Count -eq 0) {
    $problemas += 'No hay ningun .exe en la carpeta.'
} elseif ($exes.Count -gt 1) {
    Write-Host ('AVISO: hay {0} ejecutables. Se comprobaran todos.' -f $exes.Count) -ForegroundColor DarkYellow
    Write-Host ''
}

# ---- Chained dependencies ----------------------------------------------------
Write-Host 'DEPENDENCIAS'

$pendientes = New-Object System.Collections.Generic.Queue[string]
$vistos     = @{}
foreach ($f in ($exes + $dlls)) {
    $pendientes.Enqueue($f.FullName)
}

$faltan = @{}
while ($pendientes.Count -gt 0) {
    $ruta = $pendientes.Dequeue()
    $clave = $ruta.ToLower()
    if ($vistos.ContainsKey($clave)) { continue }
    $vistos[$clave] = $true

    $imps = @()
    try { $imps = @(Get-PeImports $ruta) } catch {
        $problemas += ("No pude leer la tabla de importaciones de {0}: {1}" -f
                       (Split-Path -Leaf $ruta), $_.Exception.Message)
        continue
    }

    foreach ($dep in $imps) {
        $d = $dep.ToLower()
        if ($d.StartsWith('api-ms-win-') -or $d.StartsWith('ext-ms-win-')) { continue }
        if ($deWindows -contains $d) { continue }
        if ($enCarpeta.ContainsKey($d)) {
            if (-not $vistos.ContainsKey($enCarpeta[$d].ToLower())) {
                $pendientes.Enqueue($enCarpeta[$d])
            }
            continue
        }
        if (-not $faltan.ContainsKey($d)) { $faltan[$d] = @() }
        $faltan[$d] += (Split-Path -Leaf $ruta)
    }
}

if ($faltan.Count -eq 0) {
    Write-Host '   [ok] Todo lo que importa esta en la carpeta o viene con Windows.' -ForegroundColor DarkGreen
} else {
    foreach ($d in ($faltan.Keys | Sort-Object)) {
        $quien = ($faltan[$d] | Sort-Object -Unique) -join ', '
        Write-Host ("   [!!] FALTA  {0}   (la pide: {1})" -f $d, $quien) -ForegroundColor Red
        $problemas += ("Falta {0}, que necesita {1}." -f $d, $quien)
    }
    Write-Host ''
    Write-Host '   Si son MSVCP140 o VCRUNTIME140, copialas desde tu Visual Studio:'
    Write-Host '     VC\Redist\MSVC\<version>\x64\Microsoft.VC143.CRT\'
}
Write-Host ''

# ---- ISO ----------------------------------------------------------------------
Write-Host 'ISO'
if ($isos.Count -eq 0) {
    Write-Host '   [  ] No hay ninguna. Hay que copiarla aqui antes de jugar.' -ForegroundColor DarkYellow
} else {
    foreach ($i in $isos) {
        Write-Host ("   [ok] {0}  ({1} GB)" -f $i.Name, [Math]::Round($i.Length/1GB,1))
    }
}
Write-Host ''

# ---- Absolute paths embedded in the executable -------------------------------
#
# Looks for strings like "C:\Users\..." embedded in the binaries. The
# compiler's debug paths show up here and are harmless, but if some data path
# ended up hardcoded, this is where it would show.
Write-Host 'RUTAS ABSOLUTAS INCRUSTADAS'
$sospechosas = @()
foreach ($f in $exes) {
    $txt = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($f.FullName))
    foreach ($m in [regex]::Matches($txt, '[A-Za-z]:\\[Uu]sers\\[^\x00"<>|*?]{2,80}')) {
        $sospechosas += $m.Value
    }
}
$sospechosas = @($sospechosas | Sort-Object -Unique | Select-Object -First 6)
if ($sospechosas.Count -eq 0) {
    Write-Host '   [ok] Ninguna ruta de usuario.' -ForegroundColor DarkGreen
} else {
    Write-Host '   [  ] Aparecen estas. Casi siempre son rutas de depuracion del'
    Write-Host '        compilador y no se usan al ejecutar, pero conviene mirarlas:'
    foreach ($s in $sospechosas) { Write-Host "        $s" }
}
Write-Host ''

# ---- Verdict ----------------------------------------------------------------
Write-Host '============================================'
if ($problemas.Count -eq 0) {
    Write-Host '  LA CARPETA ES AUTONOMA' -ForegroundColor Green
    Write-Host '============================================'
    Write-Host ''
    Write-Host '  Se puede copiar a un equipo sin Visual Studio, CMake, Ninja'
    Write-Host '  ni SDK y deberia arrancar con doble clic.'
    if ($isos.Count -eq 0) {
        Write-Host ''
        Write-Host '  Acuerdate de copiar tambien la ISO.'
    }
} else {
    Write-Host '  HAY PROBLEMAS' -ForegroundColor Red
    Write-Host '============================================'
    Write-Host ''
    foreach ($p in $problemas) { Write-Host "   - $p" }
}
Write-Host ''
