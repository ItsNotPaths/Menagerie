FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive

# ── Toolchain + SDL2 backend headers ─────────────────────────────────────────
# SDL2 dlopen's X11/Wayland/ALSA/Pulse at runtime — we only need the headers
# here so that SDL2's cmake enables those backends in the static lib it builds.
RUN apt-get update && apt-get install -y \
    build-essential cmake ninja-build curl git pkg-config \
    # X11 / Wayland display backends \
    libx11-dev libxext-dev libxrandr-dev libxinerama-dev \
    libxi-dev libxfixes-dev libxcursor-dev libxss-dev \
    libwayland-dev libxkbcommon-dev \
    # Audio backends \
    libasound2-dev libpulse-dev \
    # OpenGL / EGL (SDL2 needs headers even when drivers are runtime-loaded) \
    libgl1-mesa-dev libegl1-mesa-dev \
    # Input \
    libudev-dev \
    # SDL2_image codec static libs \
    libpng-dev libjpeg-turbo8-dev libwebp-dev \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# ── Build SDL2 (static only) ──────────────────────────────────────────────────
# Build context is the project root, so COPY paths are relative to it.
COPY ["vendor/sdl2 tarball/", "/tmp/SDL2/"]

RUN cmake -S /tmp/SDL2 -B /tmp/sdl2-build \
        -DCMAKE_BUILD_TYPE=Release \
        -DSDL_STATIC=ON \
        -DSDL_SHARED=OFF \
        -DSDL_TEST=OFF \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
    && cmake --build /tmp/sdl2-build --parallel \
    && cmake --install /tmp/sdl2-build \
    && rm -rf /tmp/SDL2 /tmp/sdl2-build

# ── Build SDL2_ttf (static, vendored freetype + harfbuzz) ────────────────────
# SDL2TTF_VENDORED=ON pulls freetype and harfbuzz from external/ inside the
# tarball. The vendored freetype has zlib/brotli/png disabled, so it has zero
# extra deps. The vendored harfbuzz won't find glib headers (not installed),
# so it builds without glib. Both .a files are installed alongside SDL2_ttf.a.
COPY ["vendor/sdl2.ttf tarball/", "/tmp/SDL2_ttf/"]

RUN cmake -S /tmp/SDL2_ttf -B /tmp/sdl2ttf-build \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DSDL2TTF_VENDORED=ON \
        -DSDL2TTF_HARFBUZZ=ON \
        -DSDL2TTF_INSTALL=ON \
        -DSDL2TTF_SAMPLES=OFF \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
    && cmake --build /tmp/sdl2ttf-build --parallel \
    && cmake --install /tmp/sdl2ttf-build \
    && rm -rf /tmp/SDL2_ttf /tmp/sdl2ttf-build

# ── Build SDL2_image (static, system codec libs, TIFF disabled) ───────────────
# TIFF is disabled to avoid the libtiff → Lerc/jbig/zstd/lzma dep chain.
# PNG, JPEG, WebP use the system static libs installed above.
COPY ["vendor/sdl2.image tarball/", "/tmp/SDL2_image/"]

RUN cmake -S /tmp/SDL2_image -B /tmp/sdl2img-build \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DSDL2IMAGE_SHARED=OFF \
        -DSDL2IMAGE_TIF=OFF \
        -DSDL2IMAGE_INSTALL=ON \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
    && cmake --build /tmp/sdl2img-build --parallel \
    && cmake --install /tmp/sdl2img-build \
    && rm -rf /tmp/SDL2_image /tmp/sdl2img-build

# ── Install Nim ───────────────────────────────────────────────────────────────
# choosenim itself requires glibc 2.33+ and won't run on Ubuntu 20.04 (glibc 2.31).
# Install Nim directly from the official release tarball instead.
ARG NIM_VERSION=2.2.4
RUN curl -L "https://nim-lang.org/download/nim-${NIM_VERSION}-linux_x64.tar.xz" \
    | tar xJ -C /opt \
    && ln -sf "/opt/nim-${NIM_VERSION}/bin/nim" /usr/local/bin/nim \
    && ln -sf "/opt/nim-${NIM_VERSION}/bin/nimble" /usr/local/bin/nimble

RUN nimble install sdl2 -y && nimble install zippy -y
