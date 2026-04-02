#!/bin/bash
set -e

SCUMMVM_VERSION="${SCUMMVM_VERSION:-v2026.1.0}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"

echo "=== Building ScummVM ${SCUMMVM_VERSION} for A30 (armhf) ==="

if [ ! -d "scummvm" ]; then
  git clone --depth 1 --branch "$SCUMMVM_VERSION" https://github.com/scummvm/scummvm.git
fi

cd scummvm

for dir in /patches/common /patches/a30; do
  if [ -d "$dir" ] && ls "$dir"/*.patch >/dev/null 2>&1; then
    for patch in "$dir"/*.patch; do
      echo "Applying: $(basename "$patch")"
      git apply "$patch"
    done
  fi
done

python3 <<'PYEOF'
from pathlib import Path

p = Path("backends/graphics/surfacesdl/surfacesdl-graphics.cpp")
code = p.read_text()

old = """\tgetWindowSizeFromSdl(&_windowWidth, &_windowHeight);
\thandleResize(_windowWidth, _windowHeight);"""
new = """\tgetWindowSizeFromSdl(&_windowWidth, &_windowHeight);
\tif (SDL_getenv("DISPLAY_ROTATION") && (SDL_atoi(SDL_getenv("DISPLAY_ROTATION")) % 180 != 0)) {
\t\tint tmp = _windowWidth;
\t\t_windowWidth = _windowHeight;
\t\t_windowHeight = tmp;
\t}
\thandleResize(_windowWidth, _windowHeight);"""
assert old in code, "Could not find getWindowSizeFromSdl/handleResize block"
code = code.replace(old, new)

old = """void SurfaceSdlGraphicsManager::notifyResize(const int width, const int height) {
#if SDL_VERSION_ATLEAST(2, 0, 0)
\thandleResize(width, height);"""
new = """void SurfaceSdlGraphicsManager::notifyResize(const int width, const int height) {
#if SDL_VERSION_ATLEAST(2, 0, 0)
\tif (SDL_getenv("DISPLAY_ROTATION") && (SDL_atoi(SDL_getenv("DISPLAY_ROTATION")) % 180 != 0))
\t\thandleResize(height, width);
\telse
\t\thandleResize(width, height);"""
assert old in code, "Could not find notifyResize"
code = code.replace(old, new)

old = """\t/* Destination rectangle represents the texture before rotation */
\tif (_rotationMode == Common::kRotation90 || _rotationMode == Common::kRotation270) {"""
new = """\t/* Destination rectangle represents the texture before rotation */
\tint _effectiveRotation = (int)_rotationMode;
\tif (_effectiveRotation == 0 && SDL_getenv("DISPLAY_ROTATION"))
\t\t_effectiveRotation = SDL_atoi(SDL_getenv("DISPLAY_ROTATION"));
\tif (_effectiveRotation != (int)_rotationMode
\t\t&& (_effectiveRotation == 90 || _effectiveRotation == 270)) {
\t\tviewport.w = drawRect.width();
\t\tviewport.h = drawRect.height();
\t\tviewport.x = (_windowHeight - viewport.w) / 2;
\t\tviewport.y = (_windowWidth - viewport.h) / 2;
\t} else if (_rotationMode == Common::kRotation90 || _rotationMode == Common::kRotation270) {"""
assert old in code, "Could not find viewport rotation check"
code = code.replace(old, new)

old = """\tint rotangle = (int)_rotationMode;"""
new = """\tint rotangle = _effectiveRotation;"""
assert old in code, "Could not find rotangle assignment"
code = code.replace(old, new)

p.write_text(code)
PYEOF

echo "Patched surfacesdl for display rotation without rotation_mode"

python3 <<'PYEOF'
from pathlib import Path

p = Path("backends/graphics/sdl/sdl-graphics.cpp")
code = p.read_text()

old = """\tmouse.x = (int)(mouse.x * dpiScale + 0.5f);
\tmouse.y = (int)(mouse.y * dpiScale + 0.5f);"""
new = """\tmouse.x = (int)(mouse.x * dpiScale + 0.5f);
\tmouse.y = (int)(mouse.y * dpiScale + 0.5f);
\tif (SDL_getenv("DISPLAY_ROTATION") && (SDL_atoi(SDL_getenv("DISPLAY_ROTATION")) % 180 != 0)) {
\t\tmouse.x = (mouse.x * _windowWidth + _windowHeight / 2) / _windowHeight;
\t}"""
assert old in code, "Could not find dpiScale mouse assignment in sdl-graphics.cpp"
code = code.replace(old, new)

old = """void SdlGraphicsManager::setSystemMousePosition(const int x, const int y) {
\tassert(_window);
\tif (!_window->warpMouseInWindow(x, y)) {"""
new = """void SdlGraphicsManager::setSystemMousePosition(const int x, const int y) {
\tassert(_window);
\tint warpX = x;
\tif (SDL_getenv("DISPLAY_ROTATION") && (SDL_atoi(SDL_getenv("DISPLAY_ROTATION")) % 180 != 0)) {
\t\twarpX = (x * _windowHeight + _windowWidth / 2) / _windowWidth;
\t}
\tif (!_window->warpMouseInWindow(warpX, y)) {"""
assert old in code, "Could not find setSystemMousePosition in sdl-graphics.cpp"
code = code.replace(old, new)

p.write_text(code)
PYEOF

echo "Patched sdl-graphics for mouse X scaling on rotated display"

TOOLCHAIN=/opt/a30
SYSROOT=$TOOLCHAIN/arm-a30-linux-gnueabihf/sysroot
CROSS=arm-a30-linux-gnueabihf

export PATH="$TOOLCHAIN/bin:$PATH"
export CCACHE_DIR="${CCACHE_DIR:-/ccache}"
export CC="ccache ${CROSS}-gcc"
export CXX="ccache ${CROSS}-g++"
export AR="${CROSS}-ar"
export AS="${CROSS}-as"
export LD="${CROSS}-ld"
export RANLIB="${CROSS}-ranlib"
export STRIP="${CROSS}-strip"

export PKG_CONFIG="${CROSS}-pkg-config"
export PKG_CONFIG_PATH="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"

export CFLAGS="--sysroot=$SYSROOT -march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard -O2"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="--sysroot=$SYSROOT -L$SYSROOT/usr/lib -static-libstdc++"

rm -f "$SYSROOT/usr/lib/libfontconfig"* "$SYSROOT/usr/lib/pkgconfig/fontconfig.pc"

echo "=== Checking FluidSynth in sysroot ==="
find "$SYSROOT/usr/include" -maxdepth 3 \( -name 'fluidsynth.h' -o -path '*/fluidsynth/fluidsynth.h' \) -print || true
find "$SYSROOT/usr/lib/pkgconfig" -maxdepth 1 -name 'fluidsynth.pc' -print || true
find "$SYSROOT/usr/lib" -maxdepth 2 -name 'libfluidsynth.so*' -print || true

./configure \
  --host=arm-linux-gnueabihf \
  --backend=sdl \
  --enable-optimizations \
  --enable-release \
  --disable-debug \
  --disable-eventrecorder \
  --with-sdl-prefix="$SYSROOT/usr" \
  --enable-fluidsynth \
  --with-fluidsynth-prefix="$SYSROOT/usr" \
  --with-mad-prefix="$SYSROOT/usr" \
  --with-theoradec-prefix="$SYSROOT/usr" \
  --disable-alsa \
  --disable-sndio \
  --disable-mt32emu
  
make -j"$(nproc)"

mkdir -p "$OUTPUT_DIR"

cp scummvm "$OUTPUT_DIR/scummvm.a30"
${CROSS}-strip "$OUTPUT_DIR/scummvm.a30"

cp -av "$SYSROOT/usr/lib/libtheoradec.so"* "$OUTPUT_DIR/" || true
cp -av "$SYSROOT/usr/lib/libSDL2_net-2.0.so"* "$OUTPUT_DIR/" || true
cp -av "$SYSROOT/usr/lib/libfluidsynth.so"* "$OUTPUT_DIR/" || true
cp -av "$SYSROOT/usr/lib/libsndfile.so"* "$OUTPUT_DIR/" || true
cp -av "$SYSROOT/usr/lib/libglib-2.0.so"* "$OUTPUT_DIR/" || true
cp -av "$SYSROOT/usr/lib/libgthread-2.0.so"* "$OUTPUT_DIR/" || true
cp -av "$SYSROOT/usr/lib/libgobject-2.0.so"* "$OUTPUT_DIR/" || true
cp -av "$SYSROOT/usr/lib/libgio-2.0.so"* "$OUTPUT_DIR/" || true
cp -av "$SYSROOT/usr/lib/libgmodule-2.0.so"* "$OUTPUT_DIR/" || true
cp -av "$SYSROOT/usr/lib/libffi.so"* "$OUTPUT_DIR/" || true

cat > /tmp/fixjoy.c <<'FIXJOY'
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <linux/input.h>
#include <sys/ioctl.h>

int main(int argc, char **argv) {
    const char *dev = argc > 1 ? argv[1] : "/dev/input/event4";
    int range = argc > 2 ? atoi(argv[2]) : 128;
    int fd = open(dev, O_RDWR);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    for (int i = 0; i < 6; i++) {
        struct input_absinfo info;
        if (ioctl(fd, EVIOCGABS(i), &info) == 0) {
            printf("axis %d: val=%d min=%d max=%d fuzz=%d flat=%d\n",
                   i, info.value, info.minimum, info.maximum, info.fuzz, info.flat);
            if (info.minimum < -range || info.maximum > range) {
                printf(" -> fixing range to [%d, %d]\n", -range, range);
                info.minimum = -range;
                info.maximum = range;
                info.fuzz = 0;
                info.flat = 0;
                ioctl(fd, EVIOCSABS(i), &info);
            }
        }
    }

    close(fd);
    return 0;
}
FIXJOY

${CROSS}-gcc -static -o "$OUTPUT_DIR/fixjoy" /tmp/fixjoy.c
${CROSS}-strip "$OUTPUT_DIR/fixjoy"

echo "Built fixjoy helper"
echo "Output contents:"
ls -lah "$OUTPUT_DIR"
echo "=== Build complete: ${OUTPUT_DIR}/scummvm.a30 ==="
