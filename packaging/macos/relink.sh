#!/bin/bash
# Rewrites the dist's dylib references to @rpath and ad-hoc re-signs everything.
# Usage: relink.sh <dist-dir>
set -euo pipefail
DIST="$1"; cd "$DIST"
shopt -s nullglob
libs=(nfsmw lib/*.dylib)

# 1. IDs: every shipped dylib answers to @rpath/<name>.
for f in lib/*.dylib; do
    install_name_tool -id "@rpath/$(basename "$f")" "$f"
done

# 2. Deps: a reference to a dylib we ship becomes @rpath/<name>.
#    System dylibs (not shipped) keep their absolute paths: they exist on
#    every mac. The guard is "is there a file of that name in lib/".
rewrite_deps() {
    local f="$1" dep name
    otool -L "$f" | awk 'NR>2 {print $1}' | while IFS= read -r dep; do
        name=$(basename "$dep")
        [ -f "lib/$name" ] || continue
        install_name_tool -change "$dep" "@rpath/$name" "$f"
    done
}
for f in "${libs[@]}"; do rewrite_deps "$f"; done

# 3. RPATH: dylibs find each other via @loader_path, the binary via
#    @executable_path/lib (this macOS dyld only tries the rpath PREFIX, so a
#    plain @executable_path never reaches the lib/ subfolder).
for f in lib/*.dylib; do
    install_name_tool -add_rpath "@loader_path" "$f" 2>/dev/null || true
done
install_name_tool -add_rpath "@executable_path" nfsmw 2>/dev/null || true
install_name_tool -add_rpath "@executable_path/lib" nfsmw 2>/dev/null || true

# 4. Re-sign ad hoc. Apple Silicon refuses modified binaries with stale
#    signatures: without this the game dies at exec.
codesign -f -s - nfsmw lib/*.dylib
