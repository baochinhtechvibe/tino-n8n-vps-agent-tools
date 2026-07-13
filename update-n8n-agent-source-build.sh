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
      ""|$'\n'|$'\r')
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

log "Patching n8n version update flow"
python3 - <<'PY'
from pathlib import Path
import re

p = Path('src/n8n/n8n.service.ts')
s = p.read_text()
orig = s

helper = """function getN8nBaseImage(version: string): string {
  if (version === 'latest') {
    return 'dockerhub.tino.org/library/n8nio/n8n:latest';
  }

  return `n8nio/n8n:${version}`;
}

"""
if 'function getN8nBaseImage(version: string): string' not in s:
    s = s.replace('function makeDockerfileInline(version: string): string {', helper + 'function makeDockerfileInline(version: string): string {')

s = re.sub(
    r'FROM dockerhub\.tino\.org/library/n8nio/n8n:\$\{version\}',
    r'FROM ${getN8nBaseImage(version)}',
    s,
)
s = s.replace("const command = 'docker compose exec n8n n8n --version';", "const command = 'docker compose exec -T n8n n8n --version';")

new_helpers = """  private repairKnownComposeIndentation(composeContent: string): string {
    const serviceBlockRegex = /(\\n  n8n-worker:\\n[\\s\\S]*?)(?=\\n  [a-zA-Z0-9_-]+:\\n|\\nvolumes:\\n|\\nnetworks:\\n|$)/g;

    return composeContent.replace(serviceBlockRegex, (serviceBlock) => {
      return serviceBlock.replace(
        /^(command|depends_on|environment|volumes):/gm,
        '    $1:',
      );
    });
  }

  private updateN8nServiceImagesInCompose(composeContent: string, version: string): string {
    const targetImage = getN8nBaseImage(version);

    return composeContent.replace(
      /^(\\s*image:\\s*)(?:dockerhub\\.tino\\.org\\/library\\/)?n8nio\\/n8n:[^\\s#]+(\\s*(?:#.*)?)$/gm,
      `$1${targetImage}$2`,
    );
  }

  private async composeUsesInlineBuild(): Promise<boolean> {
    const composePath = path.join(this.instancePath, 'docker-compose.yml');
    const composeContent = await fs.readFile(composePath, 'utf-8');
    return composeContent.includes('dockerfile_inline: |');
  }

"""
replacement_update_compose = """  private async updateDockerComposeVersion(version: string) {
    const composePath = path.join(this.instancePath, 'docker-compose.yml');
    const originalComposeContent = await fs.readFile(composePath, 'utf-8');
    let composeContent = originalComposeContent;

    composeContent = this.repairKnownComposeIndentation(composeContent);

    if (composeContent.includes('dockerfile_inline: |')) {
      const newInline = makeDockerfileInline(version);
      const inlineRegex = /dockerfile_inline: \\|[\\s\\S]*?(?=\\n    \\w|\\n  \\w)/g;
      const replacement = `dockerfile_inline: |\\n        ${newInline.split('\\n').join('\\n        ')}`;
      composeContent = composeContent.replace(inlineRegex, replacement);
    }

    composeContent = this.updateN8nServiceImagesInCompose(composeContent, version);

    if (composeContent !== originalComposeContent) {
      await fs.writeFile(composePath, composeContent);
    }
  }"""

s2, n = re.subn(
    r"  private async updateDockerComposeVersion\(version: string\) \{[\s\S]*?\n  \}\n\n  async getVersionInfo\(\)",
    lambda _m: replacement_update_compose + "\n\n  async getVersionInfo()",
    s,
    count=1,
)
s = s2

if 'private updateN8nServiceImagesInCompose(' not in s:
    s = s.replace('  async getVersionInfo() {', new_helpers + '  async getVersionInfo() {')

old_update = """  updateToVersion(version: string): string {
    this.lockOperation('updateToVersion');
    const task = this.tasksService.create(`Updating n8n to version ${version}`);
    this.executeInBackground('updateToVersion', task.id, async () => {
      await this.checkInstanceExists(true);
      await this.updateDockerComposeVersion(version);
      await this.shellService.execute('docker compose down', this.instancePath);
      await this.shellService.execute('docker compose build --no-cache', this.instancePath);
      const { stdout } = await this.shellService.execute('docker compose up -d', this.instancePath);
      return {
        message: `Update to version ${version} completed.`,
        log: stdout,
      };
    });
    return task.id;
  }
"""
new_update = """  updateToVersion(version: string): string {
    this.lockOperation('updateToVersion');
    const task = this.tasksService.create(`Updating n8n to version ${version}`);
    this.executeInBackground('updateToVersion', task.id, async () => {
      await this.checkInstanceExists(true);
      await this.updateDockerComposeVersion(version);
      await this.shellService.execute('docker compose config -q', this.instancePath);

      const usesInlineBuild = await this.composeUsesInlineBuild();
      if (usesInlineBuild) {
        await this.shellService.execute(
          'docker compose build --pull --no-cache n8n n8n-worker',
          this.instancePath,
        );
      } else {
        await this.shellService.execute('docker compose pull n8n n8n-worker', this.instancePath);
      }

      const { stdout } = await this.shellService.execute(
        'docker compose up -d --force-recreate n8n n8n-worker',
        this.instancePath,
      );
      const current = await this.getCurrentVersion();

      if (current !== version) {
        throw new Error(`Update failed: expected n8n ${version}, but container is running ${current}`);
      }

      return {
        message: `Update to version ${version} completed.`,
        current,
        log: stdout,
      };
    });
    return task.id;
  }
"""
if old_update in s:
    s = s.replace(old_update, new_update)

old_upgrade = """  upgrade(): string {
    this.lockOperation('upgrade');
    const task = this.tasksService.create('Upgrading n8n to latest version');
    this.executeInBackground('upgrade', task.id, async () => {
      await this.checkInstanceExists(true);
      await this.updateDockerComposeVersion('latest');
      await this.shellService.execute('docker compose down', this.instancePath);
      await this.shellService.execute('docker compose build --no-cache', this.instancePath);
      const { stdout } = await this.shellService.execute('docker compose up -d', this.instancePath);
      return { message: 'Upgrade completed.', log: stdout };
    });
    return task.id;
  }
"""
new_upgrade = """  upgrade(): string {
    this.lockOperation('upgrade');
    const task = this.tasksService.create('Upgrading n8n to latest version');
    this.executeInBackground('upgrade', task.id, async () => {
      await this.checkInstanceExists(true);
      const available = await this.getAvailableVersions();
      const latestVersion = available.latest?.version;

      if (!latestVersion) {
        throw new Error('Could not determine latest n8n version.');
      }

      await this.updateDockerComposeVersion(latestVersion);
      await this.shellService.execute('docker compose config -q', this.instancePath);

      const usesInlineBuild = await this.composeUsesInlineBuild();
      if (usesInlineBuild) {
        await this.shellService.execute(
          'docker compose build --pull --no-cache n8n n8n-worker',
          this.instancePath,
        );
      } else {
        await this.shellService.execute('docker compose pull n8n n8n-worker', this.instancePath);
      }

      const { stdout } = await this.shellService.execute(
        'docker compose up -d --force-recreate n8n n8n-worker',
        this.instancePath,
      );
      const current = await this.getCurrentVersion();

      if (current !== latestVersion) {
        throw new Error(
          `Upgrade failed: expected n8n ${latestVersion}, but container is running ${current}`,
        );
      }

      return { message: `Upgrade to version ${latestVersion} completed.`, current, log: stdout };
    });
    return task.id;
  }
"""
if old_upgrade in s:
    s = s.replace(old_upgrade, new_upgrade)

required_markers = [
    'function getN8nBaseImage(version: string): string',
    'FROM ${getN8nBaseImage(version)}',
    'private repairKnownComposeIndentation(',
    'private updateN8nServiceImagesInCompose(',
    'docker compose config -q',
    'docker compose exec -T n8n n8n --version',
]
missing = [marker for marker in required_markers if marker not in s]
if missing:
    raise SystemExit('n8n upgrade patch incomplete; missing markers: ' + ', '.join(missing))

if s == orig:
    print('n8n upgrade flow already patched')
else:
    p.write_text(s)
    print('Patched src/n8n/n8n.service.ts')
PY

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
