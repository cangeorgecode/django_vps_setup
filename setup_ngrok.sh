#!/usr/bin/env bash
# ============================================================
# setup_ngrok.sh — Install and configure ngrok tunnel
# Run as root on the VPS AFTER setup.sh has completed
# Usage: bash setup_ngrok.sh
# ============================================================

set -e

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
step()  { echo -e "\n${CYAN}=== STEP $1: $2 ===${NC}"; }

# --- Pre-flight ---
if [ "$EUID" -ne 0 ]; then
  error "Run this script as root: sudo bash setup_ngrok.sh"
  exit 1
fi

echo "============================================================"
echo "  Ngrok VPS Setup"
echo "============================================================"
echo ""

# --- Config ---
step 1 "Gather configuration"

read -p "Project name (must match setup.sh, e.g. eczemaschool): " PROJECT_NAME
if [ -z "$PROJECT_NAME" ]; then error "Project name required."; exit 1; fi

read -p "Ngrok static domain (e.g. eczemaschool.ngrok.app): " NGROK_DOMAIN
if [ -z "$NGROK_DOMAIN" ]; then error "Ngrok domain required."; exit 1; fi

read -p "Ngrok authtoken (from https://dashboard.ngrok.com/authtoken): " NGROK_AUTHTOKEN
if [ -z "$NGROK_AUTHTOKEN" ]; then error "Authtoken required."; exit 1; fi

APP_DIR="/var/www/$PROJECT_NAME"
ENV_FILE="$APP_DIR/.env"
SERVICE_NAME="ngrok_${PROJECT_NAME}"

echo ""
echo "  Project:  $PROJECT_NAME"
echo "  Domain:   $NGROK_DOMAIN"
echo "  App dir:  $APP_DIR"
echo ""
read -p "Continue? (y/N): " confirm
if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then echo "Aborted."; exit 0; fi

# ============================================================
# STEP 2: Install ngrok
# ============================================================
step 2 "Install ngrok"

if command -v ngrok &>/dev/null; then
  info "ngrok already installed: $(ngrok version)"
else
  info "Installing ngrok..."
  curl -sSL https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz -o /tmp/ngrok.tgz
  tar -xzf /tmp/ngrok.tgz -C /usr/local/bin
  rm -f /tmp/ngrok.tgz
  info "Installed: $(ngrok version)"
fi

# ============================================================
# STEP 3: Configure ngrok authtoken
# ============================================================
step 3 "Configure ngrok authtoken"

ngrok config add-authtoken "$NGROK_AUTHTOKEN"
info "Authtoken saved to ngrok config."

# ============================================================
# STEP 6: Add ngrok domain to Django ALLOWED_HOSTS
# ============================================================
step 4 "Update Django ALLOWED_HOSTS"

if [ -f "$ENV_FILE" ]; then
  if grep -q "$NGROK_DOMAIN" "$ENV_FILE"; then
    info "ALLOWED_HOSTS already includes $NGROK_DOMAIN"
  elif grep -q "ALLOWED_HOSTS=" "$ENV_FILE"; then
    # Append ngrok domain to existing ALLOWED_HOSTS (before closing quote or end of line)
    sed -i "s/ALLOWED_HOSTS=\(.*\)/ALLOWED_HOSTS=\1,$NGROK_DOMAIN/" "$ENV_FILE"
    info "Added $NGROK_DOMAIN to ALLOWED_HOSTS in $ENV_FILE"
  else
    echo "ALLOWED_HOSTS=$NGROK_DOMAIN" >> "$ENV_FILE"
    info "Added ALLOWED_HOSTS=$NGROK_DOMAIN to $ENV_FILE"
  fi
else
  warn ".env file not found at $ENV_FILE"
  warn "You must add $NGROK_DOMAIN to ALLOWED_HOSTS manually in your Django settings."
fi

# ============================================================
# STEP 5: Create systemd service
# ============================================================
step 5 "Create ngrok systemd service"

SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

info "Writing ngrok service file..."
cat > "$SERVICE_PATH" << EOF
[Unit]
Description=Ngrok tunnel for ${PROJECT_NAME}
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ngrok http --domain=${NGROK_DOMAIN} 80
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

info "Enabling and starting ngrok..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

sleep 3

if systemctl is-active --quiet "$SERVICE_NAME"; then
  info "ngrok is running."
else
  error "ngrok failed to start."
  error "Check: systemctl status $SERVICE_NAME"
  error "Logs: journalctl -u $SERVICE_NAME -f"
  exit 1
fi

# ============================================================
# STEP 6: Verify tunnel
# ============================================================
step 6 "Verify tunnel"

info "Testing tunnel reachability..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://${NGROK_DOMAIN}" --max-time 10 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ]; then
  info "Tunnel is live! Got HTTP $HTTP_CODE from https://${NGROK_DOMAIN}"
else
  warn "Tunnel may not be ready yet (HTTP $HTTP_CODE)."
  warn "Give it a moment, then try: curl -I https://${NGROK_DOMAIN}"
  warn "Check logs: journalctl -u ${SERVICE_NAME} -f"
fi

# ============================================================
# DONE
# ============================================================
echo ""
echo "============================================================"
echo "  NGROK SETUP COMPLETE"
echo "============================================================"
echo ""
echo "  Your app is publicly accessible at:"
echo "    https://${NGROK_DOMAIN}"
echo ""
echo "  Manage the tunnel:"
echo "    systemctl status ${SERVICE_NAME}"
echo "    systemctl restart ${SERVICE_NAME}"
echo "    journalctl -u ${SERVICE_NAME} -f"
echo ""
echo "  Ngrok dashboard (inspect requests):"
echo "    http://localhost:4040"
echo ""
echo "============================================================"