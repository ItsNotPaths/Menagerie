#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE_DIR="$(cd "$PROJECT_DIR/.." && pwd)/menagerie-proto-release"
IMAGE_NAME="menagerie-linux-build"
BINARY="menagerie"

# ── Build the Docker image ────────────────────────────────────────────────────
# Build context is the project root so COPY can reach vendor/.
# Docker layer caching means this is fast on subsequent runs unless the
# Dockerfile or a vendored tarball changed.
echo "==> Building Docker image (cached layers reused if unchanged)..."
docker build \
    -f "$PROJECT_DIR/docker-build/Dockerfile" \
    -t "$IMAGE_NAME" \
    "$PROJECT_DIR"

# ── Compile inside the container ──────────────────────────────────────────────
# The project root is mounted at /src. The compiled binary is written there,
# which means it appears in your actual project directory when the container exits.
echo "==> Compiling and stripping release binary..."
docker run --rm \
    -v "$PROJECT_DIR":/src \
    -v "$PROJECT_DIR/docker-build/nim.cfg":/src/nim.cfg:ro \
    -w /src \
    "$IMAGE_NAME" \
    sh -c "nim c -d:release -o:$BINARY src/menagerie.nim && strip --strip-all $BINARY"

# Fix ownership — container runs as root, so the binary comes out owned by root.
sudo chown "$(id -u):$(id -g)" "$PROJECT_DIR/$BINARY"

# ── Verify no SDL2 dynamic dep sneaked in ────────────────────────────────────
echo "==> Verifying dynamic dependencies..."
if ldd "$PROJECT_DIR/$BINARY" | grep -qi "libSDL2"; then
    echo ""
    echo "ERROR: libSDL2 appears as a dynamic dependency."
    echo "       Check that dynlibOverride is set for SDL2 in docker-build/nim.cfg."
    echo ""
    ldd "$PROJECT_DIR/$BINARY"
    exit 1
fi

echo ""
echo "Dynamic deps (should be only glibc, libm, libdl, libpthread, librt):"
ldd "$PROJECT_DIR/$BINARY"
echo ""

# ── Copy to release directory ─────────────────────────────────────────────────
echo "==> Copying to release directory..."
mkdir -p "$RELEASE_DIR"
cp "$PROJECT_DIR/$BINARY" "$RELEASE_DIR/$BINARY"
rm "$PROJECT_DIR/$BINARY"
cp -r "$PROJECT_DIR/content" "$RELEASE_DIR/content"
cp -r "$PROJECT_DIR/data" "$RELEASE_DIR/data"

echo ""
echo "Done. Release output:"
ls -lh "$RELEASE_DIR/$BINARY"
echo "  $RELEASE_DIR/"
