#!/usr/bin/env bash
# build.sh — First-time setup on Ubuntu VPS
# Run once: installs Go, clones repo, builds binary, configures PM2

set -euo pipefail

APP_DIR="$HOME/CLIProxyAPI"
CONFIG_DIR="$HOME/.cli-proxy-api"
SERVICE_NAME="cli-proxy-api"
GO_VERSION="1.24.4"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── 1. System dependencies ──────────────────────────────────────────────────
info "Installing system dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq curl git wget tar

# ── 2. Install Go ────────────────────────────────────────────────────────────
if command -v go &>/dev/null && [[ "$(go version)" == *"go${GO_VERSION}"* ]]; then
    info "Go ${GO_VERSION} already installed, skipping."
else
    info "Installing Go ${GO_VERSION}..."
    ARCH=$(dpkg --print-architecture)
    case "$ARCH" in
        amd64)  GO_ARCH="amd64" ;;
        arm64)  GO_ARCH="arm64" ;;
        *)      error "Unsupported architecture: $ARCH" ;;
    esac
    wget -q "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -O /tmp/go.tar.gz
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz

    # Add Go to PATH permanently
    if ! grep -q '/usr/local/go/bin' "$HOME/.profile" 2>/dev/null; then
        echo 'export PATH=$PATH:/usr/local/go/bin' >> "$HOME/.profile"
    fi
    export PATH=$PATH:/usr/local/go/bin
fi
go version

# ── 3. Install Node.js + PM2 ─────────────────────────────────────────────────
if ! command -v node &>/dev/null; then
    info "Installing Node.js (LTS)..."
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt-get install -y -qq nodejs
fi

if ! command -v pm2 &>/dev/null; then
    info "Installing PM2..."
    sudo npm install -g pm2
fi
pm2 --version

# ── 4. Clone repository ──────────────────────────────────────────────────────
if [[ -d "$APP_DIR/.git" ]]; then
    warn "Repo already exists at $APP_DIR. Use deploy.sh to update."
else
    info "Cloning repository..."
    git clone https://github.com/router-for-me/CLIProxyAPI.git "$APP_DIR"
fi

cd "$APP_DIR"

# ── 5. Build binary ──────────────────────────────────────────────────────────
info "Building binary..."
VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo "dev")
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "none")
BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

CGO_ENABLED=0 go build \
    -ldflags="-s -w -X 'main.Version=${VERSION}' -X 'main.Commit=${COMMIT}' -X 'main.BuildDate=${BUILD_DATE}'" \
    -o ./cli-proxy-api \
    ./cmd/server/

info "Build complete: $(./cli-proxy-api --version 2>/dev/null || echo "${VERSION}")"

# ── 6. Setup config ──────────────────────────────────────────────────────────
mkdir -p "$CONFIG_DIR"

if [[ ! -f "$APP_DIR/config.yaml" ]]; then
    cp "$APP_DIR/config.example.yaml" "$APP_DIR/config.yaml"
    warn "Config created at $APP_DIR/config.yaml"
    warn ">>> EDIT config.yaml before starting the service! <<<"
    warn "    - Set your api-keys"
    warn "    - Set remote-management.secret-key"
    warn "    - Configure provider keys as needed"
fi

if [[ ! -f "$APP_DIR/.env" && -f "$APP_DIR/.env.example" ]]; then
    cp "$APP_DIR/.env.example" "$APP_DIR/.env"
    info ".env created from example (optional, only needed for remote storage)"
fi

# ── 7. Create PM2 ecosystem config ───────────────────────────────────────────
cat > "$APP_DIR/ecosystem.config.js" << 'EOF'
module.exports = {
  apps: [
    {
      name: "cli-proxy-api",
      script: "./cli-proxy-api",
      cwd: __dirname,
      args: "-config ./config.yaml",
      interpreter: "none",
      autorestart: true,
      watch: false,
      max_memory_restart: "512M",
      env: {
        TZ: "Asia/Ho_Chi_Minh",
      },
      error_file: "./logs/pm2-error.log",
      out_file:   "./logs/pm2-out.log",
      log_date_format: "YYYY-MM-DD HH:mm:ss",
    },
  ],
};
EOF

mkdir -p "$APP_DIR/logs"
info "PM2 ecosystem config written to $APP_DIR/ecosystem.config.js"

# ── 8. Register PM2 startup (persist across reboots) ─────────────────────────
info "Configuring PM2 to start on system boot..."
pm2 startup systemd -u "$USER" --hp "$HOME" | tail -1 | grep -E '^sudo' | bash || \
    warn "Run the 'pm2 startup' command above manually if it failed."

# ── 9. Done ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN} Build complete!${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo "Next steps:"
echo "  1. Edit config:  nano $APP_DIR/config.yaml"
echo "  2. Start:        cd $APP_DIR && pm2 start ecosystem.config.js"
echo "  3. Save PM2:     pm2 save"
echo "  4. View logs:    pm2 logs $SERVICE_NAME"
echo ""
