# Shared by build-aarch64.sh and build-x86.sh (bash). Source tree: /src/mesa (read-only).

# Venus-only Mesa: no GL/EGL/GBM (the image keeps its own libgallium/zink), no LLVM,
# X11 + Wayland WSI. xlib-lease off to keep NEEDED in line with the image's Turnip
# (libX11-xcb only, no libX11/libXrandr).
MESA_OPTS=(
    --prefix=/usr
    --buildtype=release
    -Db_ndebug=true
    --wrap-mode=nodownload
    -Dvulkan-drivers=virtio
    -Dgallium-drivers=
    -Dplatforms=x11,wayland
    -Dllvm=disabled
    -Dvideo-codecs=
    -Dopengl=false
    -Dglx=disabled
    -Degl=disabled
    -Dgbm=disabled
    -Dgles1=disabled
    -Dgles2=disabled
    -Dvulkan-layers=
    -Dtools=
    -Dbuild-tests=false
    -Dvalgrind=disabled
    -Dlibunwind=disabled
    -Dlmsensors=disabled
    -Dxlib-lease=disabled
    -Dspirv-tools=disabled
    -Dzstd=enabled
    -Dzlib=enabled
    -Dexpat=enabled
    -Ddisplay-info=enabled
    -Dshader-cache=enabled
)

# build_venus <builddir> <libdir> <destdir> [meson args...]
build_venus() {
    local builddir=$1 libdir=$2 destdir=$3
    shift 3
    rm -rf "$builddir" "$destdir"
    meson setup "$builddir" /src/mesa "${MESA_OPTS[@]}" --libdir="$libdir" "$@"
    ninja -C "$builddir"
    DESTDIR="$destdir" meson install -C "$builddir" --strip --no-rebuild --tags runtime
}
