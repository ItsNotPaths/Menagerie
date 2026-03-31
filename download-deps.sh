#!/usr/bin/env bash
# Fetches third-party source deps into vendor/.
# Run this once before building (dev or release).
# All downloaded directories are gitignored.
set -euo pipefail

VENDOR="$(cd "$(dirname "$0")" && pwd)/vendor"

SDL2_VERSION="2.30.11"
SDL2_TTF_VERSION="2.24.0"
SDL2_IMAGE_VERSION="2.8.8"
LUA_VERSION="5.4.7"

fetch() {
    local name="$1"
    local url="$2"
    local dest="$3"
    local strip="${4:-1}"
    local filter="${5:-}"

    if [ -d "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
        echo "  already present: $(basename "$dest")"
        return
    fi

    echo "  downloading $name..."
    mkdir -p "$dest"
    if [ -n "$filter" ]; then
        curl -fsSL "$url" | tar xz --strip-components="$strip" -C "$dest" --wildcards "$filter"
    else
        curl -fsSL "$url" | tar xz --strip-components="$strip" -C "$dest"
    fi
    echo "  done."
}

FONT="$VENDOR/fonts/SpaceMono-Regular.ttf"

echo "==> SpaceMono-Regular.ttf"
mkdir -p "$VENDOR/fonts"
if [ ! -f "$FONT" ]; then
    echo "  downloading..."
    curl -fsSL \
        "https://github.com/googlefonts/spacemono/raw/main/fonts/ttf/SpaceMono-Regular.ttf" \
        -o "$FONT"
    echo "  done."
else
    echo "  already present: SpaceMono-Regular.ttf"
fi

echo "==> SDL2 $SDL2_VERSION"
fetch "SDL2" \
    "https://github.com/libsdl-org/SDL/releases/download/release-${SDL2_VERSION}/SDL2-${SDL2_VERSION}.tar.gz" \
    "$VENDOR/sdl2 tarball"

echo "==> SDL2_ttf $SDL2_TTF_VERSION"
fetch "SDL2_ttf" \
    "https://github.com/libsdl-org/SDL_ttf/releases/download/release-${SDL2_TTF_VERSION}/SDL2_ttf-${SDL2_TTF_VERSION}.tar.gz" \
    "$VENDOR/sdl2.ttf tarball"

echo "==> SDL2_image $SDL2_IMAGE_VERSION"
fetch "SDL2_image" \
    "https://github.com/libsdl-org/SDL_image/releases/download/release-${SDL2_IMAGE_VERSION}/SDL2_image-${SDL2_IMAGE_VERSION}.tar.gz" \
    "$VENDOR/sdl2.image tarball"

echo "==> Lua $LUA_VERSION"
fetch "Lua" \
    "https://www.lua.org/ftp/lua-${LUA_VERSION}.tar.gz" \
    "$VENDOR/lua/src" \
    2 \
    "lua-*/src/*"

# onelua.c is not in the release tarball — fetch it from the Lua git repo.
# The tag matches the release version (v5.4.7 etc).
if [ ! -f "$VENDOR/lua/src/onelua.c" ]; then
    echo "  fetching onelua.c from lua/lua@v${LUA_VERSION}..."
    curl -fsSL \
        "https://raw.githubusercontent.com/lua/lua/v${LUA_VERSION}/onelua.c" \
        -o "$VENDOR/lua/src/onelua.c"
fi

echo ""
echo "All deps ready. You can now run ./docker-build/build.sh."
