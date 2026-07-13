#!/usr/bin/env bash
set -Eeuo pipefail

# Optimize disk usage for Tino n8n VPS.
# Default mode is DRY-RUN: show what can be cleaned, do not delete anything.
# Use --apply to perform safe cleanup.

APPLY=0
YES=0
PRUNE_MODE="dangling" # dangling | unused | none
JOURNAL_SIZE="100M"
KEEP_BACKUPS=1
CLEAN_APT=1
CLEAN_JOURNAL=1
CLEAN_BACKUPS=1

usage() {
  cat <<'EOF'
Tối ưu dung lượng VPS n8n an toàn.

Mặc định chỉ kiểm tra/dry-run, không xoá gì:
  bash optimize-n8n-vps-disk.sh

Dọn an toàn, có hỏi xác nhận:
  bash optimize-n8n-vps-disk.sh --apply

Dọn an toàn, không hỏi xác nhận:
  bash optimize-n8n-vps-disk.sh --apply --yes

Tuỳ chọn:
  --prune-dangling       Chỉ xoá Docker image dangling <none> (mặc định, an toàn nhất)
  --prune-unused         Xoá Docker image không container nào dùng (giải phóng nhiều hơn)
  --no-prune-images      Không dọn Docker image
  --journal-size 100M    Giới hạn systemd journal còn dung lượng này (mặc định 100M)
  --keep-backups N       Giữ N thư mục/tar backup n8n-agent mới nhất trong /root (mặc định 1)
  --no-clean-backups     Không xoá backup n8n-agent cũ
  --no-clean-apt         Không chạy apt clean/autoremove
  --no-clean-journal     Không vacuum journal
  -h, --help             Hiển thị hướng dẫn

Script KHÔNG xoá Docker volumes để tránh mất dữ liệu n8n/Postgres/Redis/NocoDB.
EOF
}

log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
run() {
  printf '\033[1;36m$ %s\033[0m\n' "$*"
  if [ "$APPLY" -eq 1 ]; then
    eval "$@"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --yes|-y) YES=1 ;;
    --prune-dangling) PRUNE_MODE="dangling" ;;
    --prune-unused) PRUNE_MODE="unused" ;;
    --no-prune-images) PRUNE_MODE="none" ;;
    --journal-size)
      shift
      JOURNAL_SIZE="${1:-}"
      if [ -z "$JOURNAL_SIZE" ]; then err "Thiếu giá trị cho --journal-size"; exit 1; fi
      ;;
    --keep-backups)
      shift
      KEEP_BACKUPS="${1:-}"
      if ! [[ "$KEEP_BACKUPS" =~ ^[0-9]+$ ]]; then err "--keep-backups phải là số"; exit 1; fi
      ;;
    --no-clean-backups) CLEAN_BACKUPS=0 ;;
    --no-clean-apt) CLEAN_APT=0 ;;
    --no-clean-journal) CLEAN_JOURNAL=0 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Tuỳ chọn không hợp lệ: $1"; usage; exit 1 ;;
  esac
  shift
done

if [ "$(id -u)" -ne 0 ]; then
  err "Vui lòng chạy bằng root."
  exit 1
fi

log "Chế độ: $([ "$APPLY" -eq 1 ] && echo APPLY || echo DRY-RUN)"
log "Docker image cleanup: $PRUNE_MODE"
log "Journal target size: $JOURNAL_SIZE"
log "Giữ backup n8n-agent mới nhất: $KEEP_BACKUPS"

echo
log "Dung lượng trước khi dọn"
df -hT /
echo
if command -v docker >/dev/null 2>&1; then
  docker system df || true
fi
echo
journalctl --disk-usage 2>/dev/null || true
echo

log "Top thư mục lớn"
for d in /var /var/lib /root /opt; do
  [ -d "$d" ] && { echo "--- $d ---"; du -xhd1 "$d" 2>/dev/null | sort -h | tail -20; }
done

echo
if [ "$APPLY" -eq 0 ]; then
  warn "Đây là dry-run. Chưa xoá gì hết. Muốn dọn thật chạy thêm --apply."
fi

if [ "$APPLY" -eq 1 ] && [ "$YES" -ne 1 ]; then
  echo
  warn "Script sẽ dọn Docker image theo mode '$PRUNE_MODE', apt cache, journal và backup cũ nếu bật."
  warn "Script KHÔNG xoá Docker volumes."
  read -r -p "Nhập YES để tiếp tục: " CONFIRM
  if [ "$CONFIRM" != "YES" ]; then
    err "Đã huỷ."
    exit 1
  fi
fi

echo
log "Dọn Docker images"
if command -v docker >/dev/null 2>&1; then
  case "$PRUNE_MODE" in
    dangling)
      run "docker image prune -f"
      ;;
    unused)
      warn "--prune-unused sẽ xoá image không container nào dùng, có thể phải pull lại khi rollback/update."
      run "docker image prune -a -f"
      ;;
    none)
      log "Bỏ qua dọn Docker image."
      ;;
  esac
else
  warn "Không thấy docker command, bỏ qua Docker cleanup."
fi

echo
log "Dọn apt cache"
if [ "$CLEAN_APT" -eq 1 ]; then
  if command -v apt-get >/dev/null 2>&1; then
    run "apt-get clean"
    run "apt-get autoremove -y"
  else
    warn "Không thấy apt-get, bỏ qua."
  fi
else
  log "Bỏ qua apt cleanup."
fi

echo
log "Dọn systemd journal"
if [ "$CLEAN_JOURNAL" -eq 1 ]; then
  if command -v journalctl >/dev/null 2>&1; then
    run "journalctl --vacuum-size=$JOURNAL_SIZE"
  else
    warn "Không thấy journalctl, bỏ qua."
  fi
else
  log "Bỏ qua journal cleanup."
fi

echo
log "Dọn backup n8n-agent cũ trong /root"
if [ "$CLEAN_BACKUPS" -eq 1 ]; then
  mapfile -t BACKUPS < <(find /root -maxdepth 1 \( -type d -o -type f \) -name 'n8n-agent-backup-*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk '{ $1=""; sub(/^ /, ""); print }')
  if [ "${#BACKUPS[@]}" -eq 0 ]; then
    log "Không có backup n8n-agent cũ."
  else
    log "Danh sách backup tìm thấy:"
    printf '  %s\n' "${BACKUPS[@]}"
    if [ "${#BACKUPS[@]}" -le "$KEEP_BACKUPS" ]; then
      log "Số backup <= KEEP_BACKUPS, không xoá."
    else
      for i in "${!BACKUPS[@]}"; do
        if [ "$i" -ge "$KEEP_BACKUPS" ]; then
          run "rm -rf -- '${BACKUPS[$i]}'"
        fi
      done
    fi
  fi
else
  log "Bỏ qua backup cleanup."
fi

echo
log "Dung lượng sau khi dọn / hoặc dự kiến sau dry-run"
df -hT /
echo
if command -v docker >/dev/null 2>&1; then
  docker system df || true
fi
echo
journalctl --disk-usage 2>/dev/null || true

echo
log "Hoàn tất. Gợi ý kiểm tra thêm:"
cat <<'EOF'
cd /opt/n8n
docker compose ps
docker compose exec -T n8n n8n --version
df -hT
docker system df
EOF
