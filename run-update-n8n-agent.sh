#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_URL="https://raw.githubusercontent.com/baochinhtechvibe/tino-n8n-vps-agent-tools/main/update-n8n-agent-source-build.sh"
SCRIPT_PATH="/root/update-n8n-agent-source-build.sh"

log() {
  echo "[$(date '+%F %T')] $*"
}

fail() {
  echo "[ERROR] $*" >&2
  exit 1
}

if [ "$(id -u)" != "0" ]; then
  fail "Vui lòng chạy bằng user root. Ví dụ: sudo bash hoặc đăng nhập root trước khi chạy."
fi

command -v bash >/dev/null 2>&1 || fail "Thiếu bash trên hệ thống."
command -v curl >/dev/null 2>&1 || fail "Thiếu curl. Hãy cài curl trước rồi chạy lại."

log "Tải script cập nhật n8n-agent về $SCRIPT_PATH"
curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_PATH"

log "Kiểm tra cú pháp script chính"
bash -n "$SCRIPT_PATH"

log "Chạy script cập nhật n8n-agent"
bash "$SCRIPT_PATH"
