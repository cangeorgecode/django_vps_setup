# Django VPS Deployment Walkthrough

Complete walkthrough for deploying a Django app to a fresh Linode Ubuntu VPS.

## Prerequisites

- A Linode (or any Ubuntu 22.04/24.04 VPS)
- Your domain's A record pointing to your VPS IP
- Your domain's www CNAME pointing to your domain
- SSH key set up on your local machine

## Quick Start

Copy both scripts to your VPS, then run them in order:

```bash
# From your local machine, copy the scripts to the VPS
scp setup.sh deploy_config.sh root@YOUR_VPS_IP:/root/

# SSH into the VPS
ssh root@YOUR_VPS_IP

# Step 1: Run system setup (as root)
bash setup.sh

# Step 2: Switch to deploy user and set up the app
su - deploy
cd /var/www/kanafay

# Clone your repo (SSH URL — set up SSH key for deploy user first if needed)
git clone git@github.com:youruser/your-repo.git .

# Create virtualenv
python3 -m venv venv
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt
pip install gunicorn psycopg2-binary

# Create .env file (see template below)
nano .env

# Run Django commands
python manage.py migrate
python manage.py collectstatic --noinput
python manage.py createsuperuser

# Exit back to root
exit

# Step 3: Configure Gunicorn + Nginx + SSL (as root)
bash deploy_config.sh
```

Your site should now be live at `https://yourdomain.com`.

---

## What setup.sh does

1. Updates all system packages
2. Installs Python, Nginx, Git, UFW, and build tools
3. Creates a non-root `deploy` user (security best practice)
4. Creates `/var/www/kanafay/` directory
5. Configures UFW firewall (only SSH + Nginx ports open)
6. Hardens SSH (disables password login, disables root login)
7. Enables automatic security updates
8. Installs fail2ban (brute-force protection)
9. Creates 2GB swap if VPS has less than 2GB RAM
10. Copies your SSH keys to the deploy user

## What deploy_config.sh does

1. Creates a Gunicorn systemd service (auto-restarts, starts on boot)
2. Creates an Nginx config with static/media serving + security headers
3. Sets correct file permissions
4. Installs Certbot and provisions SSL certificate

---

## .env template (production)

Create this file at `/var/www/kanafay/.env`:

```env
# Django
DJANGO_SECRET_KEY=generate-a-50-char-random-key-here
DJANGO_DEBUG=False
DJANGO_ALLOWED_HOSTS=kanafay.com,www.kanafay.com
DJANGO_CSRF_TRUSTED_ORIGINS=https://kanafay.com,https://www.kanafay.com

# Database (SQLite for simple sites, PostgreSQL for production)
# DATABASE_URL=postgres://user:password@localhost:5432/dbname

# Email (if needed)
EMAIL_BACKEND=django.core.mail.backends.smtp.EmailBackend
EMAIL_HOST=smtp.gmail.com
EMAIL_PORT=587
EMAIL_USE_TLS=True
EMAIL_HOST_USER=raymondwongautomation@gmail.com
EMAIL_HOST_PASSWORD=your-app-password-here
DEFAULT_FROM_EMAIL=raymondwongautomation@gmail.com

# Admin
DJANGO_ADMIN_USERNAME=admin
DJANGO_ADMIN_PASSWORD=your-strong-password
```

### Generate a secret key:

```bash
python3 -c "import secrets; print(secrets.token_urlsafe(50))"
```

---

## Post-deploy: Updating your code

Every time you push changes to GitHub and want to update the live site:

```bash
# SSH into VPS
ssh deploy@YOUR_VPS_IP

# Pull latest code
cd /var/www/kanafay
git pull

# Activate venv and run migrations if needed
source venv/bin/activate
python manage.py migrate
python manage.py collectstatic --noinput

# Restart Gunicorn
sudo systemctl restart kanafay_gunicorn
```

---

## Troubleshooting

### Check Gunicorn status
```bash
sudo systemctl status kanafay_gunicorn
```

### Check Nginx status
```bash
sudo systemctl status nginx
sudo nginx -t
```

### View Gunicorn logs
```bash
sudo journalctl -u kanafay_gunicorn -f
```

### View Nginx error log
```bash
sudo tail -f /var/log/nginx/error.log
```

### Test Gunicorn manually
```bash
cd /var/www/kanafay
source venv/bin/activate
gunicorn --bind unix:/var/www/kanafay/kanafay.sock config.wsgi:application
```

### Nginx not serving static files
- Ensure `collectstatic` was run (files should be in `/var/www/kanafay/staticfiles/`)
- Check Nginx config `location /static/` points to `staticfiles/` (not `static/`)
- Check permissions: `sudo chown -R deploy:www-data /var/www/kanafay/staticfiles/`

### 502 Bad Gateway
- Gunicorn isn't running or socket file doesn't exist
- Check: `sudo systemctl status kanafay_gunicorn`
- Check: `ls -la /var/www/kanafay/kanafay.sock`

### SSL certificate renewal
- Certbot auto-renews. Test with: `sudo certbot renew --dry-run`

---

## What NOT to do

- Don't run the app as root
- Don't leave DEBUG=True in production
- Don't use the dev secret key in production
- Don't open port 8000 in the firewall (Gunicorn uses a Unix socket, not a port)
- Don't forget to run `collectstatic` after every deploy

## Security checklist

- [x] Non-root deploy user (setup.sh creates this)
- [x] SSH password auth disabled (setup.sh does this)
- [x] Root SSH login disabled (setup.sh does this)
- [x] UFW firewall enabled, only SSH + 80/443 open
- [x] fail2ban installed
- [x] Automatic security updates enabled
- [x] DEBUG=False in production
- [x] SSL via Certbot
- [x] Security headers in Nginx (X-Frame-Options, X-Content-Type-Options)
