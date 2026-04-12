#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Usage ─────────────────────────────────────────────────────────────────────

usage() {
    echo "Usage: release.sh [--local [--game] [--manager] [--tools]] [--public] [--version vX.Y.Z] [--notes \"...\"]"
    echo ""
    echo "  --local           Debug build: runs docker-build/build.sh locally via Docker."
    echo "                    Without subflags, builds all three targets (--release)."
    echo "    --game          Only compile the game binary."
    echo "    --manager       Only compile the mod manager."
    echo "    --tools         Only compile the world_tools applet."
    echo "  --public          Trigger a GitHub Actions build+release on GH infrastructure."
    echo "                    Requires --version. Watches the run live in the terminal."
    echo "  --version vX.Y.Z  Version tag for the GitHub Release (required with --public)"
    echo "  --notes \"...\"     Release notes body (optional, used with --public)"
    echo ""
    echo "Flags are composable: release.sh --local --public --version v1.0.0"
    echo "                      release.sh --local --game --manager"
}

# ── Parse flags ───────────────────────────────────────────────────────────────

DO_LOCAL=false
DO_PUBLIC=false
LOCAL_GAME=false
LOCAL_MANAGER=false
LOCAL_TOOLS=false
VERSION=""
NOTES=""

if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --local)   DO_LOCAL=true ;;
        --game)    LOCAL_GAME=true ;;
        --manager) LOCAL_MANAGER=true ;;
        --tools)   LOCAL_TOOLS=true ;;
        --public)  DO_PUBLIC=true ;;
        --version) VERSION="${2:-}"; shift ;;
        --notes)   NOTES="${2:-}"; shift ;;
        --help|-h) usage; exit 0 ;;
        *)
            echo "Unknown flag: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

if ! $DO_LOCAL && ! $DO_PUBLIC; then
    echo "Nothing to do. Specify --local and/or --public."
    exit 0
fi

if $DO_PUBLIC && [[ -z "$VERSION" ]]; then
    echo "Error: --public requires --version (e.g. --version v1.0.0)"
    exit 1
fi

# ── --local ───────────────────────────────────────────────────────────────────
# Runs the existing Docker-based build. For local debugging only — not for
# shipping. Public releases are built on GitHub Actions.

if $DO_LOCAL; then
    LOCAL_ARGS=()
    $LOCAL_GAME    && LOCAL_ARGS+=(--game)
    $LOCAL_MANAGER && LOCAL_ARGS+=(--manager)
    $LOCAL_TOOLS   && LOCAL_ARGS+=(--tools)
    if [[ ${#LOCAL_ARGS[@]} -eq 0 ]]; then
        LOCAL_ARGS=(--release)
    fi
    echo "==> [local] Running docker-build/build.sh ${LOCAL_ARGS[*]}..."
    "$PROJECT_DIR/docker-build/build.sh" "${LOCAL_ARGS[@]}"
    echo "==> [local] Done."
fi

# ── --public ──────────────────────────────────────────────────────────────────
# Triggers the GitHub Actions release workflow and watches it live.

if $DO_PUBLIC; then
    if ! command -v gh &>/dev/null; then
        echo "Error: 'gh' CLI not found. Install it from https://cli.github.com"
        exit 1
    fi

    REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
    if [[ -z "$REPO" ]]; then
        echo "Error: could not determine GitHub repo. Make sure you're in a git repo with a GitHub remote."
        exit 1
    fi

    echo "==> [public] Triggering release workflow for $VERSION on $REPO..."
    echo "             Notes: ${NOTES:-(none)}"
    echo ""

    # Capture the most recent run ID before triggering so we can detect the new one.
    OLD_RUN_ID=$(gh run list --workflow=release.yml --limit=1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")

    gh workflow run release.yml \
        --repo "$REPO" \
        -f version="$VERSION" \
        -f notes="$NOTES"

    echo "==> [public] Waiting for run to queue..."
    RUN_ID=""
    for i in $(seq 1 20); do
        sleep 3
        CANDIDATE=$(gh run list --workflow=release.yml --repo "$REPO" --limit=1 \
            --json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")
        if [[ -n "$CANDIDATE" && "$CANDIDATE" != "$OLD_RUN_ID" ]]; then
            RUN_ID="$CANDIDATE"
            break
        fi
    done

    if [[ -z "$RUN_ID" ]]; then
        echo "Error: timed out waiting for the workflow run to appear."
        echo "       Check manually: https://github.com/$REPO/actions"
        exit 1
    fi

    echo "==> [public] Run queued: https://github.com/$REPO/actions/runs/$RUN_ID"
    echo ""
    gh run watch "$RUN_ID" --repo "$REPO" --exit-status
fi
