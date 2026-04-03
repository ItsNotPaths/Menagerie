#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE_DIR="$(cd "$PROJECT_DIR/.." && pwd)/menagerie-release"
IMAGE_NAME="menagerie-linux-build"

# ── Usage ─────────────────────────────────────────────────────────────────────

usage() {
    echo "Usage: build.sh [--game] [--manager] [--tools]"
    echo ""
    echo "  --game     Compile the game binary, verify deps, copy to release dir"
    echo "  --manager  Compile the mod manager, place it in the project root"
    echo "  --tools    (not yet implemented) World tools editor → world-tools/"
    echo ""
    echo "Flags are composable: build.sh --game --manager"
}

# ── Parse flags ───────────────────────────────────────────────────────────────

BUILD_GAME=false
BUILD_MANAGER=false
BUILD_TOOLS=false

if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

for arg in "$@"; do
    case "$arg" in
        --game)    BUILD_GAME=true ;;
        --manager) BUILD_MANAGER=true ;;
        --tools)   BUILD_TOOLS=true ;;
        --help|-h) usage; exit 0 ;;
        *)
            echo "Unknown flag: $arg"
            usage
            exit 1
            ;;
    esac
done

if $BUILD_TOOLS; then
    echo "==> --tools: world tools editor not yet implemented, skipping."
    BUILD_TOOLS=false
fi

if ! $BUILD_GAME && ! $BUILD_MANAGER; then
    echo "Nothing to build."
    exit 0
fi

# ── Build Docker image (once, shared by all targets) ─────────────────────────
# Build context is the project root so COPY can reach vendor/.
# Layer caching means this is fast on subsequent runs.

echo "==> Building Docker image (cached layers reused if unchanged)..."
docker build \
    -f "$PROJECT_DIR/docker-build/Dockerfile" \
    -t "$IMAGE_NAME" \
    "$PROJECT_DIR"

# ── Helper: fix ownership after container run ─────────────────────────────────
# Containers run as root; the output file comes out owned by root.

fix_owner() {
    sudo chown "$(id -u):$(id -g)" "$1"
}

# ── Helper: verify no SDL2 dynamic dependency ─────────────────────────────────

check_sdl2_static() {
    local bin="$1"
    if ldd "$bin" | grep -qi "libSDL2"; then
        echo ""
        echo "ERROR: libSDL2 appears as a dynamic dependency in $bin."
        echo "       Check that dynlibOverride is set for SDL2 in docker-build/nim.cfg."
        echo ""
        ldd "$bin"
        exit 1
    fi
    echo "Dynamic deps (should be only glibc, libm, libdl, libpthread, librt):"
    ldd "$bin"
    echo ""
}

# ── --game ────────────────────────────────────────────────────────────────────

if $BUILD_GAME; then
    echo "==> [game] Compiling release binary..."
    docker run --rm \
        -v "$PROJECT_DIR":/src \
        -v "$PROJECT_DIR/docker-build/nim.cfg":/src/nim.cfg:ro \
        -w /src \
        "$IMAGE_NAME" \
        sh -c "nim c -d:release -o:menagerie src/menagerie.nim && strip --strip-all menagerie"

    fix_owner "$PROJECT_DIR/menagerie"

    echo "==> [game] Verifying dynamic dependencies..."
    check_sdl2_static "$PROJECT_DIR/menagerie"

    echo "==> [game] Copying to release directory..."
    mkdir -p "$RELEASE_DIR"
    cp    "$PROJECT_DIR/menagerie"   "$RELEASE_DIR/menagerie"
    rm    "$PROJECT_DIR/menagerie"
    cp    "$PROJECT_DIR/settings.txt" "$RELEASE_DIR/settings.txt"
    cp -rf "$PROJECT_DIR/content"    "$RELEASE_DIR/content"
    cp -rf "$PROJECT_DIR/data"       "$RELEASE_DIR/data"

    echo "==> [game] Done: $RELEASE_DIR/menagerie"
fi

# ── --manager ─────────────────────────────────────────────────────────────────

if $BUILD_MANAGER; then
    echo "==> [manager] Compiling release binary..."
    docker run --rm \
        -v "$PROJECT_DIR":/src \
        -v "$PROJECT_DIR/docker-build/nim.cfg":/src/nim.cfg:ro \
        -w /src \
        "$IMAGE_NAME" \
        sh -c "nim c -d:release -o:mod_manager world-tools/mod_manager/mod_manager.nim && strip --strip-all mod_manager"

    fix_owner "$PROJECT_DIR/mod_manager"

    echo "==> [manager] Verifying dynamic dependencies..."
    check_sdl2_static "$PROJECT_DIR/mod_manager"

    echo "==> [manager] Copying to release directory..."
    mkdir -p "$RELEASE_DIR"
    cp    "$PROJECT_DIR/mod_manager"        "$RELEASE_DIR/mod_manager"
    rm    "$PROJECT_DIR/mod_manager"
    cp -rf "$PROJECT_DIR/world-tools/drivers" "$RELEASE_DIR/world-tools/drivers"

    echo "==> [manager] Done: $RELEASE_DIR/mod_manager"
fi

# ── --tools (future) ──────────────────────────────────────────────────────────
# When implemented:
#   - Compiles src/world_tools.nim
#   - Strips the binary
#   - Moves it to world-tools/world_tools  (next to world-tools/drivers/)

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "Build complete."
$BUILD_GAME    && echo "  game:    $RELEASE_DIR/menagerie"
$BUILD_MANAGER && echo "  manager: $RELEASE_DIR/mod_manager"
