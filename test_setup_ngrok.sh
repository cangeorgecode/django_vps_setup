#!/usr/bin/env bash
# ============================================================
# test_setup_ngrok.sh — Dry-run setup_ngrok.sh in a fake VPS
# Creates a temp dir as fake root, stubs system commands,
# runs the real script with automated input, and reports errors.
# Usage: bash test_setup_ngrok.sh
# ============================================================

set -eo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; ERRORS=$((ERRORS + 1)); }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

ERRORS=0

# --- Setup fake VPS root ---
FAKE_ROOT=$(mktemp -d)
trap "rm -rf $FAKE_ROOT" EXIT

echo "============================================================"
echo "  Test stub: setup_ngrok.sh"
echo "  Fake root: $FAKE_ROOT"
echo "============================================================"
echo ""

# --- Create fake directory structure ---
# Simulates what setup.sh already created on a real VPS
FAKE_APP_DIR="$FAKE_ROOT/var/www/testproject"
mkdir -p "$FAKE_APP_DIR"

# Create a fake .env with existing ALLOWED_HOSTS
cat > "$FAKE_APP_DIR/.env" << 'EOF'
DJANGO_DEBUG=False
DJANGO_SECRET_KEY=test-secret-key
ALLOWED_HOSTS=localhost,127.0.0.1
EOF

# Create fake apt dirs
mkdir -p "$FAKE_ROOT/etc/apt/trusted.gpg.d"
mkdir -p "$FAKE_ROOT/etc/apt/sources.list.d"
mkdir -p "$FAKE_ROOT/etc/systemd/system"

# Create fake /usr/bin and /usr/local/bin
mkdir -p "$FAKE_ROOT/usr/bin"
mkdir -p "$FAKE_ROOT/usr/local/bin"

# --- Create stub commands in a temp bin dir ---
STUB_BIN="$FAKE_ROOT/stub-bin"
mkdir -p "$STUB_BIN"

# Stub: ngrok (pretends to be installed)
cat > "$STUB_BIN/ngrok" << 'STUB'
#!/usr/bin/env bash
case "$1" in
  version) echo "ngrok version 3.39.7" ;;
  config)  echo "[stub] ngrok config $*" ;;
  start)   echo "[stub] ngrok start $*" ; sleep 60 ;;
  *)       echo "[stub] ngrok $*" ;;
esac
STUB
chmod +x "$STUB_BIN/ngrok"

# Stub: apt (no-op)
cat > "$STUB_BIN/apt" << 'STUB'
#!/usr/bin/env bash
echo "[stub] apt $*"
exit 0
STUB
chmod +x "$STUB_BIN/apt"

# Stub: systemctl (no-op, reports active)
cat > "$STUB_BIN/systemctl" << 'STUB'
#!/usr/bin/env bash
case "$1" in
  is-active) exit 0 ;;
  *) echo "[stub] systemctl $*" ;;
esac
STUB
chmod +x "$STUB_BIN/systemctl"

# Stub: curl (returns 200 for ngrok domain, does real download for ngrok.asc)
cat > "$STUB_BIN/curl" << 'STUB'
#!/usr/bin/env bash
# Check if this is the tunnel verification call
for arg in "$@"; do
  if [[ "$arg" == *"ngrok.app"* ]]; then
    echo "200"
    exit 0
  fi
done
# For ngrok.asc GPG key download, create a dummy file
for arg in "$@"; do
  if [[ "$arg" == *"ngrok.asc"* ]]; then
    echo "fake-gpg-key"
    exit 0
  fi
done
echo "[stub] curl $*"
exit 0
STUB
chmod +x "$STUB_BIN/curl"

# Stub: tee (actually write files since we need to check them)
# Use real tee but redirect paths through FAKE_ROOT
cat > "$STUB_BIN/tee" << STUB
#!/usr/bin/env bash
# Rewrite absolute paths to use FAKE_ROOT
REAL_TEE=$(which -a tee | grep -v "$STUB_BIN" | head -1)
exec \$REAL_TEE "\$@"
STUB
chmod +x "$STUB_BIN/tee"

# --- Patch setup_ngrok.sh to use FAKE_ROOT ---
PATCHED_SCRIPT="$FAKE_ROOT/setup_ngrok.sh"
sed \
  -e "s|/etc/apt/trusted.gpg.d|$FAKE_ROOT/etc/apt/trusted.gpg.d|g" \
  -e "s|/etc/apt/sources.list.d|$FAKE_ROOT/etc/apt/sources.list.d|g" \
  -e "s|/etc/systemd/system|$FAKE_ROOT/etc/systemd/system|g" \
  -e "s|/root/.config/ngrok|$FAKE_ROOT/root/.config/ngrok|g" \
  -e "s|/usr/bin/ngrok|$STUB_BIN/ngrok|g" \
  -e "s|/var/www/|$FAKE_ROOT/var/www/|g" \
  -e "s|read -s -p|read -p|g" \
  -e 's|if \[ "\$EUID" -ne 0 \]; then|if false; then|' \
  ~/Projects/psy_deploy/django_vps_setup/setup_ngrok.sh > "$PATCHED_SCRIPT"
chmod +x "$PATCHED_SCRIPT"

# --- Run the patched script with automated input ---
echo "Running setup_ngrok.sh with automated input..."
echo ""

# Input: project name, domain, authtoken, confirm
INPUT="testproject
testproject.ngrok.app
fake-authtoken-12345
y"

# Prepend stub bin to PATH so our stubs are found first
export PATH="$STUB_BIN:$PATH"

OUTPUT=$(echo "$INPUT" | bash "$PATCHED_SCRIPT" 2>&1) || true

echo "--- Script output ---"
echo "$OUTPUT"
echo "--- End output ---"
echo ""

# ============================================================
# VERIFY RESULTS
# ============================================================
echo "============================================================"
echo "  Verification"
echo "============================================================"
echo ""

# 1. ngrok.yml was created
NGROK_YML="$FAKE_ROOT/root/.config/ngrok/ngrok.yml"
if [ -f "$NGROK_YML" ]; then
  pass "ngrok.yml created at $NGROK_YML"
else
  fail "ngrok.yml NOT created"
fi

# 2. ngrok.yml has correct content
if [ -f "$NGROK_YML" ]; then
  if grep -q 'authtoken: fake-authtoken-12345' "$NGROK_YML"; then
    pass "ngrok.yml contains authtoken"
  else
    fail "ngrok.yml missing authtoken"
  fi

  if grep -q 'testproject.ngrok.app' "$NGROK_YML"; then
    pass "ngrok.yml contains domain"
  else
    fail "ngrok.yml missing domain"
  fi

  if grep -q 'addr: 80' "$NGROK_YML"; then
    pass "ngrok.yml contains addr: 80"
  else
    fail "ngrok.yml missing addr: 80"
  fi

  # 3. Check file permissions (600)
  PERMS=$(stat -c "%a" "$NGROK_YML" 2>/dev/null || echo "unknown")
  if [ "$PERMS" = "600" ]; then
    pass "ngrok.yml permissions are 600"
  else
    fail "ngrok.yml permissions are $PERMS (expected 600)"
  fi
fi

# 4. .env was updated with ALLOWED_HOSTS
ENV_FILE="$FAKE_APP_DIR/.env"
if grep -qF 'testproject.ngrok.app' "$ENV_FILE"; then
  pass ".env has testproject.ngrok.app in ALLOWED_HOSTS"
else
  fail ".env missing testproject.ngrok.app in ALLOWED_HOSTS"
fi

if grep -qF 'https://testproject.ngrok.app' "$ENV_FILE"; then
  pass ".env has CSRF_TRUSTED_ORIGINS with https://testproject.ngrok.app"
else
  fail ".env missing CSRF_TRUSTED_ORIGINS"
fi

# 5. systemd service was created
SERVICE_FILE="$FAKE_ROOT/etc/systemd/system/ngrok_testproject.service"
if [ -f "$SERVICE_FILE" ]; then
  pass "systemd service file created"
else
  fail "systemd service file NOT created"
fi

# 6. Service file references config and tunnel name
if [ -f "$SERVICE_FILE" ]; then
  if grep -qF -- '--config=' "$SERVICE_FILE"; then
    pass "service uses --config flag"
  else
    fail "service missing --config flag"
  fi

  if grep -q 'testproject' "$SERVICE_FILE"; then
    pass "service references tunnel name"
  else
    fail "service missing tunnel name"
  fi
fi

# 7. Check no errors in output
if echo "$OUTPUT" | grep -qi "error"; then
  fail "Script output contains 'error'"
else
  pass "No errors in script output"
fi

# ============================================================
# SUMMARY
# ============================================================
echo ""
echo "============================================================"
if [ "$ERRORS" -eq 0 ]; then
  echo -e "  ${GREEN}ALL CHECKS PASSED${NC}"
else
  echo -e "  ${RED}$ERRORS CHECK(S) FAILED${NC}"
fi
echo "============================================================"

exit "$ERRORS"
