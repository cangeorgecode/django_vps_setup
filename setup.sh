#!/usr/bin/env bash
# ============================================================
# setup.sh — All-in-one Django VPS deployment script
# Run as a sudo user on a fresh Ubuntu 22.04/24.04 VPS
# (self-elevates to root via sudo for privileged commands)
# Idempotent: safe to re-run if it fails halfway
# Usage: bash setup.sh
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

# --- Pre-flight: elevate to root via sudo if not already root ---
if [ "$EUID" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    info "Not root — re-running with sudo (enter your password when prompted)."
    exec sudo bash "$(readlink -f "$0")" "$@"
  else
    error "This script needs root. Install sudo, or run as root."
    exit 1
  fi
fi

echo "============================================================"
echo "  Django VPS Setup — All-in-one"
echo "  Idempotent: safe to re-run if it fails halfway"
echo "============================================================"
echo ""

# --- Prompt for config ---
step 1 "Gather configuration"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/.setup.conf"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"   # remember answers between runs

read -e -p "Project name (lowercase, no spaces, e.g. kanafay): " -i "${PROJECT_NAME:-}" PROJECT_NAME
if [ -z "$PROJECT_NAME" ]; then error "Project name required."; exit 1; fi

read -e -p "Domain name (e.g. kanafay.com, leave blank if no domain yet): " -i "${DOMAIN:-}" DOMAIN

read -e -p "Git repo SSH URL (e.g. git@github.com:user/repo.git): " -i "${REPO_URL:-}" REPO_URL
if [ -z "$REPO_URL" ]; then error "Repo URL required."; exit 1; fi

read -e -p "Django WSGI module name (default: config): " -i "${DJANGO_APP:-config}" DJANGO_APP
DJANGO_APP="${DJANGO_APP:-config}"

read -e -p "Your email (for Certbot SSL): " -i "${CERT_EMAIL:-}" CERT_EMAIL

# Save answers so a failed run doesn't re-prompt (fields are space-free)
cat > "$CONFIG_FILE" << EOF
PROJECT_NAME=${PROJECT_NAME}
DOMAIN=${DOMAIN}
REPO_URL=${REPO_URL}
DJANGO_APP=${DJANGO_APP}
CERT_EMAIL=${CERT_EMAIL}
EOF

APP_DIR="/var/www/$PROJECT_NAME"
VENV_DIR="$APP_DIR/venv"
SOCKET_FILE="$APP_DIR/$PROJECT_NAME.sock"
SERVICE_NAME="${PROJECT_NAME}_gunicorn"

echo ""
echo "  Project:  $PROJECT_NAME"
echo "  Domain:   ${DOMAIN:-(none)}"
echo "  Repo:     $REPO_URL"
echo "  WSGI:     $DJANGO_APP"
echo "  Email:    $CERT_EMAIL"
echo "  App dir:  $APP_DIR"
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

PACKAGES="python3 python3-venv python3-dev git nginx curl ufw build-essential libpq-dev libssl-dev libffi-dev certbot python3-certbot-nginx"

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

# Swap is virtual memory on disk. If your VPS has only 1GB RAM,
# pip install and Django can crash with out-of-memory errors.
# Swap gives breathing room by using disk space as overflow RAM.

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

# This is the VPS's key so it can clone from private GitHub repos.
# Different from your local machine's key (which lets you SSH into the VPS).

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
  # Clone into temp dir first, then move contents (git clone needs empty dir)
  if [ -d "$APP_DIR/.git" ]; then
    info "Git repo exists but manage.py missing. Pulling..."
    cd "$APP_DIR"
    git pull
  else
    git clone "$REPO_URL" "$APP_DIR"
  fi
fi

# ============================================================
# STEP 9: Virtualenv + install dependencies
# ============================================================
step 9 "Virtualenv and dependencies"

cd "$APP_DIR"

mkdir -p "$APP_DIR/logs"
info "Created logs directory: $APP_DIR/logs"

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
EnvironmentFile=-${APP_DIR}/.env
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

# Restart (in case config changed and service was already running)
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

if [ -n "$DOMAIN" ]; then
  SERVER_NAME="$DOMAIN www.$DOMAIN"
else
  SERVER_NAME="_"
fi

info "Writing Nginx config..."

cat > "$NGINX_SITE" << EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_NAME};

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

# Remove default Nginx site (causes "duplicate default server" error)
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
# STEP 14: SSL certificate
# ============================================================
step 14 "SSL certificate"

if [ -z "$DOMAIN" ]; then
  warn "No domain set. Skipping SSL."
  warn "Site accessible at: http://$(curl -s ifconfig.me)"
  warn "Set up a domain later and run: certbot --nginx -d yourdomain.com -d www.yourdomain.com"
else
  # Check if cert already exists
  if certbot certificates 2>/dev/null | grep -q "$DOMAIN"; then
    info "SSL certificate already exists for $DOMAIN. Skipping."
  else
    info "Requesting SSL certificate for $DOMAIN and www.$DOMAIN ..."
    certbot --nginx -d "$DOMAIN" -d "www.$DOMAIN" \
      --non-interactive --agree-tos \
      --redirect \
      -m "$CERT_EMAIL"

    if [ $? -eq 0 ]; then
      info "SSL certificate installed!"
    else
      warn "Certbot failed. Possible reasons:"
      warn "  - DNS not pointing to this VPS yet"
      warn "  - Domain not configured"
      warn "Run manually later: certbot --nginx -d $DOMAIN -d www.$DOMAIN"
    fi
  fi
fi

# ============================================================
# DONE
# ============================================================
echo ""
echo "============================================================"
echo "  DEPLOY COMPLETE"
echo "============================================================"
echo ""

if [ -n "$DOMAIN" ]; then
  echo "  Site live at:"
  echo "    https://${DOMAIN}"
  echo "    https://www.${DOMAIN}"
else
  VPS_IP=$(curl -s ifconfig.me)
  echo "  Site live at: http://${VPS_IP}"
fi

echo ""
echo "  Admin panel: https://${DOMAIN:-$VPS_IP}/admin/"
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
echo ""
echo "  View logs:"
echo "    journalctl -u $SERVICE_NAME -f"
echo "    tail -f /var/log/gunicorn/error.log"
echo "    tail -f /var/log/nginx/error.log"
echo ""
echo "============================================================"
