# Tino n8n VPS Agent Tools

Script hỗ trợ cập nhật `n8n-agent` trên các VPS n8n của Tino Group bằng cách build source mới nhất từ `tinovn/n8n-manage` và chuyển service sang chạy bản build local.

## Sử dụng nhanh

SSH vào VPS n8n bằng quyền `root`, sau đó chạy:

```bash
curl -fsSL https://raw.githubusercontent.com/baochinhtechvibe/tino-n8n-vps-agent-tools/main/run-update-n8n-agent.sh | bash
```

Script sẽ hỏi API key:

```text
Nhập API Key của N8N-Agent:
```

Khi nhập, terminal hiển thị dạng `********` và không hiện key thật.

## Script thực hiện gì?

Wrapper `run-update-n8n-agent.sh` sẽ:

1. Tải script chính về `/root/update-n8n-agent-source-build.sh`.
2. Kiểm tra cú pháp script chính bằng `bash -n`.
3. Chạy script chính với stdin nối vào terminal thật để nhập API key.

Script chính `update-n8n-agent-source-build.sh` sẽ:

1. Backup các file/thư mục cần thiết.
2. Lưu `AGENT_API_KEY` vào `/etc/n8n-agent.env` với quyền `600`.
3. Clone/cập nhật source `tinovn/n8n-manage` vào `/opt/n8n-agent-src`.
4. Patch local `page_size=15` sang `page_size=100` nếu source vẫn còn logic cũ.
5. Patch local flow nâng cấp n8n để:
   - VPS khởi tạo ban đầu vẫn dùng `dockerhub.tino.org/library/n8nio/n8n:latest`.
   - Khi nâng cấp version cụ thể, compose đổi sang `n8nio/n8n:<version>` để pull từ Docker Hub gốc.
   - Hỗ trợ cả compose mới dùng `dockerfile_inline` và compose cũ dùng `image:` cho `n8n`/`n8n-worker`.
   - Tự sửa lỗi indent phổ biến ở block `n8n-worker` như `depends_on:` hoặc `command:` bị tụt ra đầu dòng.
   - Không `docker compose down` trước khi build/pull.
   - Verify version thật bằng `docker compose exec -T n8n n8n --version`.
6. Chạy `npm ci` và `npm run build`.
7. Ghi lại systemd unit `n8n-agent.service` để chạy:

```text
/usr/bin/node /opt/n8n-agent-src/dist/main.js
```

8. Restart service và kiểm tra API `/api/n8n/version`.

## Kiểm tra sau khi chạy

Kiểm tra service:

```bash
systemctl status n8n-agent --no-pager -l
```

Kiểm tra API version:

```bash
curl -sS http://127.0.0.1:7071/api/n8n/version | python3 -m json.tool
```

Kết quả cần có `latest` và `all`, không còn dạng:

```json
{
  "current": "...",
  "latest": null,
  "all": []
}
```

## Tối ưu dung lượng VPS n8n

Script `optimize-n8n-vps-disk.sh` dùng để kiểm tra và dọn dung lượng VPS n8n an toàn. Mặc định chỉ dry-run, không xoá gì:

```bash
curl -fsSL -o /root/optimize-n8n-vps-disk.sh https://raw.githubusercontent.com/baochinhtechvibe/tino-n8n-vps-agent-tools/main/optimize-n8n-vps-disk.sh
bash /root/optimize-n8n-vps-disk.sh
```

Dọn thật mức an toàn nhất, chỉ xoá Docker image dangling, apt cache, journal và backup n8n-agent cũ:

```bash
bash /root/optimize-n8n-vps-disk.sh --apply
```

Dọn mạnh hơn, xoá Docker image không container nào dùng, giải phóng nhiều dung lượng hơn nhưng khi rollback/update có thể phải pull lại image:

```bash
bash /root/optimize-n8n-vps-disk.sh --apply --prune-unused
```

Script **không xoá Docker volumes** để tránh mất dữ liệu n8n/Postgres/Redis/NocoDB.

## Backup

Mỗi lần chạy, script tạo backup tại:

```text
/root/n8n-agent-backup-YYYY-MM-DD-HHMMSS
/root/n8n-agent-backup-YYYY-MM-DD-HHMMSS.tar.gz
```

Các thành phần được backup nếu tồn tại:

```text
/etc/systemd/system/n8n-agent.service
/opt/n8n-agent
/opt/n8n-agent-src
/etc/n8n-agent.env
/opt/n8n/.env
```

## Rollback

Thay `YYYY-MM-DD-HHMMSS` bằng timestamp backup thực tế mà script in ra cuối quá trình chạy.

```bash
BACKUP_DIR="/root/n8n-agent-backup-YYYY-MM-DD-HHMMSS"

cp -a "$BACKUP_DIR/n8n-agent.service" /etc/systemd/system/n8n-agent.service

if [ -d "$BACKUP_DIR/opt-n8n-agent" ]; then
  rm -rf /opt/n8n-agent
  cp -a "$BACKUP_DIR/opt-n8n-agent" /opt/n8n-agent
fi

if [ -f "$BACKUP_DIR/n8n-agent.env" ]; then
  cp -a "$BACKUP_DIR/n8n-agent.env" /etc/n8n-agent.env
  chmod 600 /etc/n8n-agent.env
fi

systemctl daemon-reload
systemctl restart n8n-agent
systemctl status n8n-agent --no-pager -l
```

## Lưu ý bảo mật

Không commit secret vào repo này, bao gồm:

- `AGENT_API_KEY`
- File `.env`
- Mật khẩu VPS
- GitHub token
- SSH private key

Secret runtime nên đặt trong:

```text
/etc/n8n-agent.env
```

với quyền:

```bash
chmod 600 /etc/n8n-agent.env
```

## Khi nào dùng script này?

Dùng khi VPS đang chạy binary `n8n-agent` cũ, repo `tinovn/n8n-agent` chưa có binary mới, nhưng cần nhận nhanh các fix từ source `tinovn/n8n-manage`.

Flow release dài hạn vẫn nên là:

```text
tinovn/n8n-manage source
→ build packaged n8n-agent binary
→ push binary mới sang tinovn/n8n-agent
→ VPS chạy /opt/n8n-agent/update-agent.sh
```
