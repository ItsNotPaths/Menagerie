#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE_DIR="$(cd "$PROJECT_DIR/.." && pwd)/menagerie-release"
IMAGE_NAME="menagerie-linux-build"

# ── Usage ─────────────────────────────────────────────────────────────────────

usage() {
    echo "Usage: build.sh [--game] [--manager] [--tools] [--files]"
    echo ""
    echo "  --game     Compile the game binary, verify deps, copy to release dir"
    echo "  --manager  Compile the mod manager, place it in the project root"
    echo "  --tools    Compile world tools editor → world-tools/world_tools"
    echo "  --files    Copy README files to release dir and clear game.log"
    echo ""
    echo "Flags are composable: build.sh --game --manager"
}

# ── Parse flags ───────────────────────────────────────────────────────────────

BUILD_GAME=false
BUILD_MANAGER=false
BUILD_TOOLS=false
COPY_FILES=false

if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

for arg in "$@"; do
    case "$arg" in
        --game)    BUILD_GAME=true ;;
        --manager) BUILD_MANAGER=true ;;
        --tools)   BUILD_TOOLS=true ;;
        --files)   COPY_FILES=true ;;
        --help|-h) usage; exit 0 ;;
        *)
            echo "Unknown flag: $arg"
            usage
            exit 1
            ;;
    esac
done

  # no early-out; handled below

if ! $BUILD_GAME && ! $BUILD_MANAGER && ! $BUILD_TOOLS && ! $COPY_FILES; then
    echo "Nothing to build."
    exit 0
fi

# ── Build Docker image (once, shared by all targets) ─────────────────────────
# Build context is the project root so COPY can reach vendor/.
# Layer caching means this is fast on subsequent runs.

if $BUILD_GAME || $BUILD_MANAGER || $BUILD_TOOLS; then
    echo "==> Building Docker image (cached layers reused if unchanged)..."
    docker build \
        -f "$PROJECT_DIR/docker-build/Dockerfile" \
        -t "$IMAGE_NAME" \
        "$PROJECT_DIR"
fi

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

# ── --tools ───────────────────────────────────────────────────────────────────

if $BUILD_TOOLS; then
    echo "==> [tools] Compiling release binary..."
    docker run --rm \
        -v "$PROJECT_DIR":/src \
        -v "$PROJECT_DIR/docker-build/nim.cfg":/src/nim.cfg:ro \
        -w /src \
        "$IMAGE_NAME" \
        sh -c "nim c -d:release -o:world_tools world-tools/tools/main.nim && strip --strip-all world_tools"

    fix_owner "$PROJECT_DIR/world_tools"

    echo "==> [tools] Verifying dynamic dependencies..."
    check_sdl2_static "$PROJECT_DIR/world_tools"

    echo "==> [tools] Copying to release directory..."
    mkdir -p "$RELEASE_DIR/world-tools"
    cp    "$PROJECT_DIR/world_tools"          "$RELEASE_DIR/world-tools/world_tools"
    rm    "$PROJECT_DIR/world_tools"

    echo "==> [tools] Done: $RELEASE_DIR/world-tools/world_tools"
fi

# ── --files ───────────────────────────────────────────────────────────────────

if $COPY_FILES; then
    echo "==> [files] Copying READMEs to release directory..."
    mkdir -p "$RELEASE_DIR"
    for f in "$PROJECT_DIR"/README*.md; do
        cp "$f" "$RELEASE_DIR/"
        echo "       copied: $(basename "$f")"
    done

    echo "==> [files] Clearing game.log..."
    > "$RELEASE_DIR/game.log"

    echo "==> [files] Removing saves and content directories..."
    rm -rf "$RELEASE_DIR/saves" "$RELEASE_DIR/content"

    echo "==> [files] Done."
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "Build complete."
$BUILD_GAME    && echo "  game:    $RELEASE_DIR/menagerie"
$BUILD_MANAGER && echo "  manager: $RELEASE_DIR/mod_manager"
$BUILD_TOOLS   && echo "  tools:   $RELEASE_DIR/world-tools/world_tools"
$COPY_FILES    && echo "  files:   READMEs copied, game.log cleared"
