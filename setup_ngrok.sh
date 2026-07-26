#!/usr/bin/env bash
# ============================================================
# setup_ngrok.sh — All-in-one Django VPS deployment with ngrok
# Run as root on a fresh Ubuntu 22.04/24.04 VPS
# Idempotent: safe to re-run if it fails halfway
# No domain required — uses ngrok for public HTTPS access
# Usage: bash setup_ngrok.sh
# ============================================================

set -eo pipefail

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
echo "  Django VPS Setup with Ngrok"
echo "  Idempotent: safe to re-run if it fails halfway"
echo "============================================================"
echo ""

# ============================================================
# STEP 1: Gather configuration
# ============================================================
step 1 "Gather configuration"

read -p "Project name (lowercase, no spaces, e.g. eczemaschool): " PROJECT_NAME
if [ -z "$PROJECT_NAME" ]; then error "Project name required."; exit 1; fi

read -p "Git repo SSH URL (e.g. git@github.com:user/repo.git): " REPO_URL
if [ -z "$REPO_URL" ]; then error "Repo URL required."; exit 1; fi

read -p "Django WSGI module name (default: config): " DJANGO_APP
DJANGO_APP="${DJANGO_APP:-config}"

read -p "Ngrok static domain (e.g. eczemaschool.ngrok.app): " NGROK_DOMAIN
if [ -z "$NGROK_DOMAIN" ]; then error "Ngrok domain required."; exit 1; fi

read -s -p "Ngrok authtoken (from https://dashboard.ngrok.com/authtoken): " NGROK_AUTHTOKEN
echo ""
if [ -z "$NGROK_AUTHTOKEN" ]; then error "Authtoken required."; exit 1; fi

APP_DIR="/var/www/$PROJECT_NAME"
VENV_DIR="$APP_DIR/venv"
SOCKET_FILE="$APP_DIR/$PROJECT_NAME.sock"
SERVICE_NAME="${PROJECT_NAME}_gunicorn"
NGROK_SERVICE_NAME="ngrok_${PROJECT_NAME}"

echo ""
echo "  Project:     $PROJECT_NAME"
echo "  Repo:        $REPO_URL"
echo "  WSGI:        $DJANGO_APP"
echo "  Ngrok:       https://$NGROK_DOMAIN"
echo "  App dir:     $APP_DIR"
echo ""
read -p "Continue? (y/N): " confirm
if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then echo "Aborted."; exit 0; fi

# ============================================================
# STEP 2: System update
# ============================================================
step 2 "System update"

info "Updating packages..."
apt update -y
apt upgrade -y

# ============================================================
# STEP 3: Install system packages
# ============================================================
step 3 "Install system packages"

PACKAGES="python3 python3-venv python3-dev git nginx curl ufw build-essential libpq-dev libssl-dev libffi-dev"

NEED_INSTALL=0
for pkg in $PACKAGES; do
  if ! dpkg -s "$pkg" &>/dev/null; then
    NEED_INSTALL=1
    break
  fi
done

if [ "$NEED_INSTALL" -eq 1 ]; then
  info "Installing missing packages..."
  apt install -y $PACKAGES
else
  info "All packages already installed."
fi

# ============================================================
# STEP 4: Firewall
# ============================================================
step 4 "Check firewall"

if ufw status | grep -q "Status: active"; then
  info "Firewall already active."
  ufw status | head -10
else
  info "Enabling firewall..."
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow OpenSSH
  ufw allow 'Nginx Full'
  yes | ufw enable
  info "Firewall enabled."
fi

# ============================================================
# STEP 5: Swap (for low-RAM VPS like Linode Nanode 1GB)
# ============================================================
step 5 "Check swap"

TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
CURRENT_SWAP=$(free -m | awk '/^Swap:/{print $2}')

if [ "$TOTAL_RAM" -lt 2048 ] && [ "$CURRENT_SWAP" -eq 0 ]; then
  info "Low RAM (${TOTAL_RAM}MB) and no swap. Creating 2GB swap..."
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  if ! grep -q '/swapfile' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
  info "Swap created."
else
  info "RAM: ${TOTAL_RAM}MB, Swap: ${CURRENT_SWAP}MB — OK."
fi

# ============================================================
# STEP 6: Create project directory
# ============================================================
step 6 "Create project directory"

if [ -d "$APP_DIR" ]; then
  info "Directory already exists: $APP_DIR"
else
  info "Creating: $APP_DIR"
  mkdir -p "$APP_DIR"
fi

# ============================================================
# STEP 7: VPS → GitHub SSH key
# ============================================================
step 7 "Check VPS GitHub SSH key"

if [ -f ~/.ssh/id_ed25519 ]; then
  info "SSH key already exists: ~/.ssh/id_ed25519"
  info "Public key (add to GitHub → Settings → SSH keys if not done):"
  echo ""
  cat ~/.ssh/id_ed25519.pub
  echo ""
else
  info "Generating SSH key for VPS..."
  ssh-keygen -t ed25519 -C "${PROJECT_NAME}-vps" -f ~/.ssh/id_ed25519 -N ""
  info "SSH key generated."
  echo ""
  info "Public key — add this to GitHub → Settings → SSH and GPG keys → New SSH key:"
  echo ""
  cat ~/.ssh/id_ed25519.pub
  echo ""
fi

# Test GitHub connection
info "Testing GitHub connection..."
if ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
  info "GitHub SSH connection works."
elif ssh -T git@github.com 2>&1 | grep -q "Permission denied"; then
  warn "GitHub doesn't recognize this VPS key yet."
  warn "Add the public key above to your GitHub account, then re-run this script."
  warn "The script will skip already-completed steps and continue from here."
  exit 1
else
  warn "Could not verify GitHub connection (first connect shows host key prompt)."
  warn "Proceeding — if git clone fails later, add the key to GitHub and re-run."
fi

# ============================================================
# STEP 8: Clone repo
# ============================================================
step 8 "Clone repository"

if [ -f "$APP_DIR/manage.py" ]; then
  info "Repo already cloned (manage.py found). Skipping."
else
  info "Cloning $REPO_URL into $APP_DIR ..."
  if [ -d "$APP_DIR/.git" ]; then
    info "Git repo exists but manage.py missing. Pulling..."
    cd "$APP_DIR"
    git pull
  else
    git clone "$REPO_URL" "$APP_DIR"
  fi
fi

mkdir -p "$APP_DIR/logs"
info "Created logs directory: $APP_DIR/logs"

# ============================================================
# STEP 9: Virtualenv + install dependencies
# ============================================================
step 9 "Virtualenv and dependencies"

cd "$APP_DIR"

if [ -d "$VENV_DIR" ]; then
  info "Virtualenv already exists."
else
  info "Creating virtualenv..."
  python3 -m venv venv
fi

source "$VENV_DIR/bin/activate"

# Install requirements.txt
if [ -f requirements.txt ]; then
  info "Installing requirements.txt..."
  pip install -r requirements.txt
else
  warn "No requirements.txt found. Skipping."
fi

# Install gunicorn if not already
if ! pip show gunicorn &>/dev/null; then
  info "Installing gunicorn..."
  pip install gunicorn
else
  info "Gunicorn already installed."
fi

# Install psycopg2 if using PostgreSQL
if ! pip show psycopg2-binary &>/dev/null; then
  info "Installing psycopg2-binary..."
  pip install psycopg2-binary
else
  info "psycopg2-binary already installed."
fi

# ============================================================
# STEP 10: .env file
# ============================================================
step 10 "Create .env file"

if [ -f "$APP_DIR/.env" ]; then
  info ".env already exists. Skipping."
else
  if [ -f "$APP_DIR/.env.example" ]; then
    info "Copying .env.example to .env..."
    cp .env.example .env
    warn "Review and edit .env before going live:"
    warn "  nano $APP_DIR/.env"
    warn "Set DJANGO_DEBUG=False, DJANGO_SECRET_KEY, ALLOWED_HOSTS, etc."
    echo ""
    read -p "Edit .env now? (y/N): " edit_env
    if [ "$edit_env" = "y" ] || [ "$edit_env" = "Y" ]; then
      ${EDITOR:-nano} "$APP_DIR/.env"
    fi
  else
    warn "No .env.example found. You'll need to create .env manually:"
    warn "  nano $APP_DIR/.env"
    echo ""
    read -p "Create .env manually now? (y/N): " edit_env
    if [ "$edit_env" = "y" ] || [ "$edit_env" = "Y" ]; then
      ${EDITOR:-nano} "$APP_DIR/.env"
    fi
  fi
fi

# ============================================================
# STEP 11: Django commands
# ============================================================
step 11 "Django commands (migrate, collectstatic, createsuperuser)"

source "$VENV_DIR/bin/activate"
cd "$APP_DIR"

info "Running migrations..."
python manage.py migrate --noinput

info "Collecting static files..."
python manage.py collectstatic --noinput

# Create superuser (skip if exists)
SUPERUSER_EXISTS=$(python manage.py shell -c "
from django.contrib.auth import get_user_model
User = get_user_model()
print(User.objects.filter(is_superuser=True).exists())
" 2>/dev/null | tail -1)

if [ "$SUPERUSER_EXISTS" = "True" ]; then
  info "Superuser already exists. Skipping."
else
  info "No superuser found. Creating one..."
  python manage.py createsuperuser
fi

# ============================================================
# STEP 12: Gunicorn service
# ============================================================
step 12 "Configure Gunicorn service"

SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
GUNICORN_BIN="$VENV_DIR/bin/gunicorn"
LOG_DIR="/var/log/gunicorn"

# Create log directory
mkdir -p "$LOG_DIR"
touch "$LOG_DIR/error.log" "$LOG_DIR/access.log"
chmod 644 "$LOG_DIR/error.log" "$LOG_DIR/access.log"

info "Writing Gunicorn service file..."

cat > "$SERVICE_PATH" << EOF
[Unit]
Description=Gunicorn instance to serve ${PROJECT_NAME}
After=network.target

[Service]
User=root
Group=www-data
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
ExecStart=${GUNICORN_BIN} \\
  --workers 3 \\
  --bind unix:${SOCKET_FILE} \\
  ${DJANGO_APP}.wsgi:application \\
  --timeout 120 \\
  --worker-class sync \\
  --log-level info \\
  --error-logfile ${LOG_DIR}/error.log \\
  --access-logfile ${LOG_DIR}/access.log \\
  --capture-output

[Install]
WantedBy=multi-user.target
EOF

info "Enabling and starting Gunicorn..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

sleep 2
if systemctl is-active --quiet "$SERVICE_NAME"; then
  info "Gunicorn is running."
else
  error "Gunicorn failed to start."
  error "Check: systemctl status $SERVICE_NAME"
  error "Logs: tail -f $LOG_DIR/error.log"
  exit 1
fi

# Verify socket file exists
if [ -S "$SOCKET_FILE" ]; then
  info "Socket file exists: $SOCKET_FILE"
else
  warn "Socket file not found yet. Check Gunicorn logs."
fi

# ============================================================
# STEP 13: Nginx config
# ============================================================
step 13 "Configure Nginx"

NGINX_SITE="/etc/nginx/sites-available/${PROJECT_NAME}"
NGINX_ENABLED="/etc/nginx/sites-enabled/${PROJECT_NAME}"

info "Writing Nginx config..."

cat > "$NGINX_SITE" << EOF
server {
    listen 80;
    listen [::]:80;
    server_name _;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    # Max upload size
    client_max_body_size 10M;

    # Static files (collected by collectstatic)
    location /static/ {
        alias ${APP_DIR}/staticfiles/;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }

    # Media files (user-uploaded)
    location /media/ {
        alias ${APP_DIR}/media/;
        expires 7d;
    }

    # Django app via Gunicorn
    location / {
        proxy_pass http://unix:${SOCKET_FILE};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# Enable site
ln -sf "$NGINX_SITE" "$NGINX_ENABLED"

# Remove default Nginx site
if [ -f /etc/nginx/sites-enabled/default ]; then
  info "Removing default Nginx site..."
  rm -f /etc/nginx/sites-enabled/default
fi

# Test and restart Nginx
info "Testing Nginx config..."
if nginx -t; then
  info "Nginx config valid."
  systemctl restart nginx
  systemctl enable nginx
  info "Nginx restarted."
else
  error "Nginx config test failed."
  error "Check: nginx -t"
  exit 1
fi

# ============================================================
# STEP 14: Install ngrok
# ============================================================
step 14 "Install ngrok"

if command -v ngrok &>/dev/null; then
  info "ngrok already installed: $(ngrok version)"
else
  info "Installing ngrok via apt..."
  curl -sSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc | tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null
  echo "deb https://ngrok-agent.s3.amazonaws.com buster main" | tee /etc/apt/sources.list.d/ngrok.list >/dev/null
  apt update -y
  apt install -y ngrok
  info "Installed: $(ngrok version)"
fi

# ============================================================
# STEP 15: Write ngrok config
# ============================================================
step 15 "Write ngrok config"

NGROK_CONFIG_DIR="/root/.config/ngrok"
NGROK_CONFIG_FILE="$NGROK_CONFIG_DIR/ngrok.yml"

mkdir -p "$NGROK_CONFIG_DIR"

cat > "$NGROK_CONFIG_FILE" << EOF
version: "3"
agent:
  authtoken: ${NGROK_AUTHTOKEN}
tunnels:
  ${PROJECT_NAME}:
    proto: http
    addr: 80
    domain: ${NGROK_DOMAIN}
EOF

chmod 600 "$NGROK_CONFIG_FILE"
info "Wrote ngrok config to $NGROK_CONFIG_FILE"

# ============================================================
# STEP 16: Update Django ALLOWED_HOSTS + CSRF_TRUSTED_ORIGINS
# ============================================================
step 16 "Update Django ALLOWED_HOSTS and CSRF_TRUSTED_ORIGINS"

ENV_FILE="$APP_DIR/.env"

if [ -f "$ENV_FILE" ]; then
  # --- ALLOWED_HOSTS ---
  if grep -qF "$NGROK_DOMAIN" "$ENV_FILE"; then
    info "ALLOWED_HOSTS already includes $NGROK_DOMAIN"
  elif grep -q "ALLOWED_HOSTS=" "$ENV_FILE"; then
    sed -i "s/ALLOWED_HOSTS=\(.*\)/ALLOWED_HOSTS=\1,$NGROK_DOMAIN/" "$ENV_FILE"
    info "Added $NGROK_DOMAIN to ALLOWED_HOSTS"
  else
    echo "ALLOWED_HOSTS=$NGROK_DOMAIN" >> "$ENV_FILE"
    info "Added ALLOWED_HOSTS=$NGROK_DOMAIN"
  fi

  # --- CSRF_TRUSTED_ORIGINS (Django 4.0+ requires scheme + domain) ---
  NGROK_ORIGIN="https://${NGROK_DOMAIN}"
  if grep -qF "$NGROK_ORIGIN" "$ENV_FILE"; then
    info "CSRF_TRUSTED_ORIGINS already includes $NGROK_ORIGIN"
  elif grep -q "CSRF_TRUSTED_ORIGINS=" "$ENV_FILE"; then
    sed -i "s/CSRF_TRUSTED_ORIGINS=\(.*\)/CSRF_TRUSTED_ORIGINS=\1,$NGROK_ORIGIN/" "$ENV_FILE"
    info "Added $NGROK_ORIGIN to CSRF_TRUSTED_ORIGINS"
  else
    echo "CSRF_TRUSTED_ORIGINS=$NGROK_ORIGIN" >> "$ENV_FILE"
    info "Added CSRF_TRUSTED_ORIGINS=$NGROK_ORIGIN"
  fi
else
  warn ".env file not found at $ENV_FILE"
  warn "You must manually add to your Django settings:"
  warn "  ALLOWED_HOSTS += ['$NGROK_DOMAIN']"
  warn "  CSRF_TRUSTED_ORIGINS += ['https://$NGROK_DOMAIN']"
fi

# ============================================================
# STEP 17: Create ngrok systemd service
# ============================================================
step 17 "Create ngrok systemd service"

SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

# Dynamically locate the ngrok binary to prevent status=203/EXEC issues
NGROK_BIN=$(command -v ngrok || echo "/usr/bin/ngrok")

info "Writing ngrok service file (using binary: ${NGROK_BIN})..."

cat > "$SERVICE_PATH" << EOF
[Unit]
Description=Ngrok tunnel for ${PROJECT_NAME}
After=network.target

[Service]
Type=simple
ExecStart=${NGROK_BIN} start --config=${NGROK_CONFIG_FILE} ${PROJECT_NAME}
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
# STEP 18: Verify tunnel
# ============================================================
step 18 "Verify tunnel"

info "Testing tunnel reachability..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://${NGROK_DOMAIN}" --max-time 10 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ]; then
  info "Tunnel is live! Got HTTP $HTTP_CODE from https://${NGROK_DOMAIN}"
else
  warn "Tunnel may not be ready yet (HTTP $HTTP_CODE)."
  warn "Give it a moment, then try: curl -I https://${NGROK_DOMAIN}"
  warn "Check logs: journalctl -u ${NGROK_SERVICE_NAME} -f"
fi

# ============================================================
# DONE
# ============================================================
echo ""
echo "============================================================"
echo "  DEPLOY COMPLETE"
echo "============================================================"
echo ""
echo "  Site live at:"
echo "    https://${NGROK_DOMAIN}"
echo ""
echo "  Admin panel:"
echo "    https://${NGROK_DOMAIN}/admin/"
echo ""
echo "  Update code after changes:"
echo "    cd $APP_DIR"
echo "    git pull"
echo "    source venv/bin/activate"
echo "    python manage.py migrate"
echo "    python manage.py collectstatic --noinput"
echo "    systemctl restart $SERVICE_NAME"
echo ""
echo "  Check status:"
echo "    systemctl status $SERVICE_NAME"
echo "    systemctl status nginx"
echo "    systemctl status $NGROK_SERVICE_NAME"
echo ""
echo "  View logs:"
echo "    journalctl -u $SERVICE_NAME -f"
echo "    journalctl -u $NGROK_SERVICE_NAME -f"
echo "    tail -f /var/log/gunicorn/error.log"
echo "    tail -f /var/log/nginx/error.log"
echo ""
echo "  Ngrok dashboard (inspect requests):"
echo "    http://localhost:4040"
echo ""
echo "============================================================"
