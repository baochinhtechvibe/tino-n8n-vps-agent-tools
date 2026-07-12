#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/n8n-agent"
SRC_DIR="/opt/n8n-agent-src"
ENV_FILE="/etc/n8n-agent.env"
UNIT_FILE="/etc/systemd/system/n8n-agent.service"
REPO_URL="https://github.com/tinovn/n8n-manage"
BRANCH="main"
PORT="7071"
TS="$(date +%F-%H%M%S)"
BACKUP_DIR="/root/n8n-agent-backup-$TS"

log(){ echo "[$(date '+%F %T')] $*"; }
fail(){ echo "[ERROR] $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || fail "Please run as root"

log "Creating backup: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
[ -f "$UNIT_FILE" ] && cp -a "$UNIT_FILE" "$BACKUP_DIR/n8n-agent.service"
[ -d "$APP_DIR" ] && cp -a "$APP_DIR" "$BACKUP_DIR/opt-n8n-agent"
[ -d "$SRC_DIR" ] && cp -a "$SRC_DIR" "$BACKUP_DIR/opt-n8n-agent-src"
[ -f "$ENV_FILE" ] && cp -a "$ENV_FILE" "$BACKUP_DIR/n8n-agent.env"
[ -f /opt/n8n/.env ] && cp -a /opt/n8n/.env "$BACKUP_DIR/opt-n8n.env"
tar -C /root -czf "$BACKUP_DIR.tar.gz" "$(basename "$BACKUP_DIR")"
log "Backup archive: $BACKUP_DIR.tar.gz"

log "Preparing API key env file"

get_agent_api_key_from_file() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk -F= '$1 == "AGENT_API_KEY" { value=$0; sub(/^AGENT_API_KEY=/, "", value); print value }' "$file" | tail -n1
}

read_api_key_masked() {
  local prompt="$1"
  local value=""
  local char=""

  printf '%s' "$prompt" >&2
  while IFS= read -r -s -n1 char; do
    case "$char" in
      $'\n'|$'\r')
        printf '\n' >&2
        break
        ;;
      $'\177'|$'\b')
        if [ -n "$value" ]; then
          value="${value%?}"
          printf '\b \b' >&2
        fi
        ;;
      *)
        value="${value}${char}"
        printf '*' >&2
        ;;
    esac
  done

  printf '%s' "$value"
}

EXISTING_KEY=""
[ -z "$EXISTING_KEY" ] && EXISTING_KEY="$(get_agent_api_key_from_file "$ENV_FILE")"
[ -z "$EXISTING_KEY" ] && EXISTING_KEY="$(get_agent_api_key_from_file "$APP_DIR/.env")"
[ -z "$EXISTING_KEY" ] && EXISTING_KEY="$(get_agent_api_key_from_file "/opt/n8n/.env")"

if [ -n "${AGENT_API_KEY:-}" ]; then
  FINAL_KEY="$AGENT_API_KEY"
else
  FINAL_KEY="$(read_api_key_masked 'Nhập API Key của N8N-Agent: ')"
  if [ -z "$FINAL_KEY" ] && [ -n "$EXISTING_KEY" ]; then
    log "Không nhập API key mới, sử dụng API key hiện có trong env file."
    FINAL_KEY="$EXISTING_KEY"
  fi
fi

[ -n "$FINAL_KEY" ] || fail "AGENT_API_KEY is required"
TMP_ENV="$(mktemp)"
[ -f "$ENV_FILE" ] && grep -v '^AGENT_API_KEY=' "$ENV_FILE" > "$TMP_ENV" 2>/dev/null || true
printf 'AGENT_API_KEY=%s\n' "$FINAL_KEY" >> "$TMP_ENV"
install -m 600 "$TMP_ENV" "$ENV_FILE"
rm -f "$TMP_ENV"

log "Installing build dependencies if needed"
NEED_APT=0
command -v git >/dev/null 2>&1 || NEED_APT=1
command -v curl >/dev/null 2>&1 || NEED_APT=1
command -v node >/dev/null 2>&1 || NEED_APT=1
command -v npm >/dev/null 2>&1 || NEED_APT=1
if [ "$NEED_APT" = "1" ]; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y git curl nodejs npm build-essential ca-certificates
fi
log "Node version: $(node -v)"
log "NPM version: $(npm -v)"

log "Fetching source: $REPO_URL"
if [ ! -d "$SRC_DIR/.git" ]; then
  rm -rf "$SRC_DIR"
  git clone "$REPO_URL" "$SRC_DIR"
fi
cd "$SRC_DIR"
git fetch origin "$BRANCH"
git checkout "$BRANCH"
git reset --hard "origin/$BRANCH"
log "Source commit: $(git rev-parse --short HEAD) $(git log -1 --pretty=%s)"

if grep -q 'registry.hub.docker.com/v2/repositories/n8nio/n8n/tags?page_size=15' src/n8n/n8n.service.ts; then
  log "Patching page_size=15 to page_size=100"
  python3 - <<'PY'
from pathlib import Path
p = Path('src/n8n/n8n.service.ts')
s = p.read_text()
s = s.replace('https://registry.hub.docker.com/v2/repositories/n8nio/n8n/tags?page_size=15','https://registry.hub.docker.com/v2/repositories/n8nio/n8n/tags?page_size=100')
p.write_text(s)
PY
fi

log "Installing npm dependencies"
npm ci
log "Building source"
npm run build
[ -f "$SRC_DIR/dist/main.js" ] || fail "Build failed: dist/main.js not found"

log "Writing systemd unit"
cat > "$UNIT_FILE" <<EOFUNIT
[Unit]
Description=N8N Agent Service source build
After=network.target docker.service

[Service]
ExecStart=/usr/bin/node $SRC_DIR/dist/main.js
Restart=always
User=root
Environment=NODE_ENV=production
EnvironmentFile=$ENV_FILE
WorkingDirectory=$SRC_DIR

[Install]
WantedBy=multi-user.target
EOFUNIT

systemctl daemon-reload
systemctl enable n8n-agent >/dev/null 2>&1
log "Restarting n8n-agent"
systemctl restart n8n-agent
sleep 6
systemctl status n8n-agent --no-pager -l | sed -n '1,80p'
systemctl is-active --quiet n8n-agent || fail "n8n-agent is not active after restart"

log "Testing version API"
curl -sS --max-time 45 "http://127.0.0.1:$PORT/api/n8n/version" > /tmp/n8n-agent-version-check.json
python3 - <<'PY'
import json
p = '/tmp/n8n-agent-version-check.json'
d = json.load(open(p))
data = d.get('data') or {}
print('current =', data.get('current'))
print('latest =', data.get('latest'))
print('all_count =', len(data.get('all') or []))
if not data.get('latest') or not data.get('all'):
    raise SystemExit('latest/all is empty')
PY

log "Testing API with key header"
KEY="$(grep '^AGENT_API_KEY=' "$ENV_FILE" | tail -n1 | cut -d= -f2-)"
HEADER_NAME="tng-api-key"
curl -sS -i --max-time 45 -H "$HEADER_NAME: $KEY" "http://127.0.0.1:$PORT/api/n8n/version" | sed -n '1,12p'

cat <<EOF

==================== SUMMARY ====================
Done.
Backup dir: $BACKUP_DIR
Backup tar: $BACKUP_DIR.tar.gz
Source/build path: $SRC_DIR
Systemd unit: $UNIT_FILE
Env file: $ENV_FILE

Rollback:
  cp -a "$BACKUP_DIR/n8n-agent.service" "$UNIT_FILE"
  rm -rf "$APP_DIR"
  cp -a "$BACKUP_DIR/opt-n8n-agent" "$APP_DIR"
  [ -f "$BACKUP_DIR/n8n-agent.env" ] && cp -a "$BACKUP_DIR/n8n-agent.env" "$ENV_FILE"
  systemctl daemon-reload
  systemctl restart n8n-agent
=================================================
EOF
