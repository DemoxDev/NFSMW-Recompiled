#!/bin/bash
# Linux equivalent of build-unified.sh (which refuses to run outside MSYS2): same meson options,
# same SDK layout. Incremental: re-running only rebuilds what changed, then re-stages the SDK.
# Runs inside the mesa-switch-nfsmw image with this checkout mounted at /project:
#
#   podman run --rm -v <mesa-switch checkout>:/project:z -w /project \
#       mesa-switch-nfsmw bash nfsmw-build/build.sh
set -euo pipefail
cd /project
JOBS=${JOBS:-8}
HOST_BUILD_DIR=builddir-native
BUILD_DIR=builddir-unified
DESTDIR=/project/mesa-unified-install
SDK_DIR=$DESTDIR/opt/devkitpro/portlibs/switch
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git show -s --format=%ct HEAD)}
export ZERO_AR_DATE=1 LC_ALL=C TZ=UTC

# Host tools (mesa_clc, vtn_bindgen2) used by the cross build's CL kernels.
if [[ ! -f $HOST_BUILD_DIR/build.ninja ]]; then
    meson setup "$HOST_BUILD_DIR" \
        --buildtype=release \
        -Dvulkan-drivers= -Dgallium-drivers= -Dshader-cache=disabled -Dplatforms= \
        -Dglx=disabled -Degl=disabled -Dopengl=false -Dgles1=disabled -Dgles2=disabled \
        -Dtools=[] -Dllvm=enabled -Dshared-llvm=enabled \
        -Dmesa-clc=enabled -Dprecomp-compiler=enabled -Dinstall-mesa-clc=true
fi
ninja -C "$HOST_BUILD_DIR" -j"$JOBS" src/compiler/clc/mesa_clc src/compiler/spirv/vtn_bindgen2

if [[ ! -f $BUILD_DIR/build.ninja ]]; then
    meson setup "$BUILD_DIR" \
        --cross-file nfsmw-build/cross.txt \
        --native-file nfsmw-build/native.txt \
        --default-library=static \
        --prefix=/opt/devkitpro/portlibs/switch \
        --libdir=lib \
        --buildtype=release \
        -Doptimization=2 \
        -Db_lto=false \
        -Db_ndebug=true \
        -Dvulkan-drivers=nouveau \
        -Dgallium-drivers=nouveau,zink \
        -Dgallium-rusticl=false \
        -Dplatforms=switch \
        -Degl-native-platform=switch \
        -Dglx=disabled \
        -Degl=enabled \
        -Dopengl=true \
        -Dgles1=enabled \
        -Dgles2=enabled \
        -Dvideo-codecs= \
        -Dshader-cache=enabled \
        -Dxmlconfig=enabled \
        -Dexpat=enabled \
        -Dtools=[] \
        -Dllvm=disabled \
        -Dshared-glapi=disabled \
        -Dshared-llvm=disabled \
        -Dmesa-clc=system \
        -Dprecomp-compiler=system \
        -Dcpp_rtti=false \
        -Dbuild-tests=false
fi
ninja -C "$BUILD_DIR" -j"$JOBS"

rm -rf -- "$DESTDIR"
meson install -C "$BUILD_DIR" --destdir "$DESTDIR" >/dev/null
for pc_file in "$SDK_DIR"/lib/pkgconfig/*.pc; do
    sed -i 's|^prefix=.*|prefix=${pcfiledir}/../..|' "$pc_file"
done

for f in lib/libEGL.a lib/libGL.a lib/libGLESv1_CM.a lib/libGLESv2.a lib/libglapi.a lib/libvulkan.a \
         lib/libnvk.a lib/libnak_rs.a lib/pkgconfig/vulkan.pc lib/cmake/Vulkan/VulkanConfig.cmake \
         include/vulkan/vulkan.h include/vulkan/vulkan_vi.h include/EGL/egl.h include/GLES2/gl2.h; do
    [[ -f $SDK_DIR/$f ]] || { echo "SDK is missing $f" >&2; exit 1; }
done
echo "SDK staged at $SDK_DIR"
ls -l "$SDK_DIR"/lib/*.a
