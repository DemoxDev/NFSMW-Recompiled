# NFSMW Recomp - bootstrap (Windows)
# Checks prerequisites, clones the ReXGlue SDK, and builds and installs it.
# Usage:  .\tools\bootstrap.ps1

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

function Test-Cmd($name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

Write-Host "== Verificando prerequisitos ==" -ForegroundColor Cyan

$missing = @()
foreach ($t in @("git", "cmake", "ninja", "clang", "python")) {
    if (Test-Cmd $t) {
        $v = (& $t --version 2>&1 | Select-Object -First 1)
        Write-Host ("  [ok] {0,-8} {1}" -f $t, $v)
    } else {
        Write-Host ("  [--] {0,-8} NO ENCONTRADO" -f $t) -ForegroundColor Red
        $missing += $t
    }
}

if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Host "Faltan: $($missing -join ', ')" -ForegroundColor Red
    Write-Host "Instala Visual Studio 2022 con el workload 'Desktop development with C++'"
    Write-Host "y los componentes individuales:"
    Write-Host "  - C++ Clang Compiler for Windows (20.x o superior)"
    Write-Host "  - MSBuild support for LLVM (clang-cl) toolset"
    exit 1
}

# Clang must be 20+
$clangVer = (clang --version | Select-String -Pattern '(\d+)\.\d+\.\d+' | ForEach-Object { $_.Matches[0].Groups[1].Value })
if ([int]$clangVer -lt 20) {
    Write-Host "Clang $clangVer detectado; ReXGlue necesita 20 o superior." -ForegroundColor Red
    Write-Host "MSVC y GCC no estan soportados: el codigo generado depende de intrinsics de Clang."
    exit 1
}

Write-Host ""
Write-Host "== ReXGlue SDK ==" -ForegroundColor Cyan

$sdk = Join-Path (Split-Path -Parent $root) "rexglue-sdk"

if (Test-Path $sdk) {
    Write-Host "  Ya existe en $sdk - actualizando"
    Push-Location $sdk
    git pull --ff-only
    git submodule update --init --recursive
    Pop-Location
} else {
    Write-Host "  Clonando en $sdk"
    git clone --recursive https://github.com/rexglue/rexglue-sdk.git $sdk
}

Push-Location $sdk
Write-Host ""
Write-Host "== Compilando (win-amd64) ==" -ForegroundColor Cyan
cmake --preset win-amd64
cmake --build out/build/win-amd64 --target install
Pop-Location

Write-Host ""
Write-Host "Listo." -ForegroundColor Green
Write-Host "Comprueba que el CLI esta accesible:  rexglue --help"
Write-Host "Si no lo encuentra, anade al PATH:  $sdk\out\install\win-amd64\bin"
Write-Host ""
Write-Host "Siguiente paso: docs\01-extraccion-xex.md"
