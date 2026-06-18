#!/usr/bin/env bash
# deploy.sh — Pull latest code, rebuild binary, restart PM2 service
# Usage: ./deploy.sh [--branch <branch>] [--skip-restart]

set -euo pipefail

APP_DIR="$HOME/CLIProxyAPI"
SERVICE_NAME="cli-proxy-api"
BRANCH="main"
SKIP_RESTART=false

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Parse args ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --branch)       BRANCH="$2"; shift 2 ;;
        --skip-restart) SKIP_RESTART=true; shift ;;
        *) error "Unknown option: $1" ;;
    esac
done

# ── Verify environment ───────────────────────────────────────────────────────
[[ -d "$APP_DIR/.git" ]] || error "Repo not found at $APP_DIR. Run build.sh first."
command -v go  &>/dev/null || export PATH=$PATH:/usr/local/go/bin
command -v go  &>/dev/null || error "Go not found. Run build.sh first."
command -v pm2 &>/dev/null || error "PM2 not found. Run build.sh first."

cd "$APP_DIR"

# ── 1. Pull latest code ──────────────────────────────────────────────────────
info "Fetching latest code from branch '${BRANCH}'..."
git fetch origin
git checkout "$BRANCH"
git pull origin "$BRANCH"

CURRENT_COMMIT=$(git rev-parse --short HEAD)
info "Now at commit: ${CURRENT_COMMIT}"

# ── 2. Build binary ──────────────────────────────────────────────────────────
info "Building binary..."
VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo "dev")
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "none")
BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Build to a temp file first so the running binary is not replaced mid-flight
CGO_ENABLED=0 go build \
    -ldflags="-s -w -X 'main.Version=${VERSION}' -X 'main.Commit=${COMMIT}' -X 'main.BuildDate=${BUILD_DATE}'" \
    -o ./cli-proxy-api.new \
    ./cmd/server/

mv -f ./cli-proxy-api.new ./cli-proxy-api
info "Build complete: ${VERSION} (${COMMIT})"

# ── 3. Restart PM2 service ───────────────────────────────────────────────────
if [[ "$SKIP_RESTART" == "true" ]]; then
    warn "Skipping restart (--skip-restart). Run: pm2 restart ${SERVICE_NAME}"
else
    if pm2 list | grep -q "$SERVICE_NAME"; then
        info "Restarting PM2 service '${SERVICE_NAME}'..."
        pm2 restart "$SERVICE_NAME"
    else
        info "Service not running. Starting '${SERVICE_NAME}'..."
        pm2 start ecosystem.config.js
    fi

    pm2 save
    info "PM2 process list:"
    pm2 list
fi

echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN} Deploy complete: ${VERSION} (${COMMIT})${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo "  View logs:   pm2 logs ${SERVICE_NAME}"
echo "  Status:      pm2 status"
echo ""
