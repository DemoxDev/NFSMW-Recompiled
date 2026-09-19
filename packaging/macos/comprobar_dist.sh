#!/bin/bash
# Verifies the dist is self-contained and carries no game data.
# Usage: comprobar_dist.sh <dist-dir> ; exits non-zero on the first problem.
set -euo pipefail
DIST="$1"; cd "$DIST"
shopt -s nullglob

# 1. Game data must not travel (mirror of comprobar_dist.ps1).
for bad in *.iso *.xex *.xexp default.xex NFS Movies; do
    for hit in $bad; do
        [ -e "$hit" ] || continue
        echo "[ERROR] game data in the dist: $hit"; exit 1
    done
done

# 2. Every @rpath reference resolves inside the folder; nothing that should
#    be relocatable is left with an absolute path. The general rule: every
#    dependency either resolves via @rpath to a dylib we ship, or is a system
#    dylib (/usr/lib or /System/Library). ANY other absolute path -including
#    references to other shipped dylibs that skipped the relink- is fatal:
#    it would break the moment the folder moves to another machine.
check_file() {
    local f="$1" dep name rc=0
    while IFS= read -r dep; do
        name=$(basename "$dep")
        case "$dep" in
            @rpath/*)
                [ -f "lib/$name" ] || { echo "[ERROR] $f: missing $dep"; rc=1; } ;;
            *librexruntime*|*librexgpu*|*libSDL3*|*libMoltenVK*|*libvulkan*|*libSPIRV*|*libTracyClient*)
                echo "[ERROR] $f: not relocatable: $dep"; rc=1 ;;
            */usr/lib/system/*|*/usr/lib/libSystem*|*/usr/lib/libc++*|*/usr/lib/libobjc*|/System/Library/*)
                : ;;
            *)
                echo "[ERROR] $f: dependency is neither @rpath nor a system dylib: $dep"; rc=1 ;;
        esac
    done < <(otool -L "$f" | awk 'NR>2 {print $1}')
    return $rc
}
check_file nfsmw
check_file librexgpu-xenos.dylib
for f in lib/*.dylib; do check_file "$f"; done

# 3. The binary is arm64.
lipo -archs nfsmw | grep -q arm64 || { echo "[ERROR] nfsmw is not arm64"; exit 1; }

echo "Comprobar_dist: OK ($(pwd))"
