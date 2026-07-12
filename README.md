# Tino n8n VPS Agent Tools

Bộ script hỗ trợ quản lý và cập nhật `n8n-agent` trên các VPS n8n của Tino Group.

## Mục đích

Repo này dùng để lưu các script hỗ trợ bảo trì n8n VPS agent.

Script hiện tại được thiết kế để:

- Backup service `n8n-agent`, binary cũ, source build cũ và các file môi trường cần thiết trước khi thay đổi.
- Giữ `AGENT_API_KEY` trong file riêng `/etc/n8n-agent.env` để tránh mất key khi cập nhật service.
- Lấy source mới nhất từ repo `tinovn/n8n-manage`.
- Build backend `n8n-agent` trực tiếp trên VPS.
- Chuyển systemd service `n8n-agent` sang chạy bản source đã build.
- Restart và kiểm tra lại API của `n8n-agent`.
- In hướng dẫn rollback sau mỗi lần chạy.

## Script hiện có

### `update-n8n-agent-source-build.sh`

Script này build và chạy source mới nhất từ `tinovn/n8n-manage` dưới dạng service `n8n-agent` local trên VPS.

Dùng trong trường hợp binary đóng gói ở repo `tinovn/n8n-agent` chưa được build/release lại, nhưng VPS cần nhận các bản sửa mới từ `n8n-manage`.

Ví dụ lỗi từng gặp:

```json
{
  "current": "2.29.10",
  "latest": null,
  "all": []
}
```

Nguyên nhân thường là binary `n8n-agent` cũ vẫn đang dùng logic Docker Hub tags cũ, ví dụ chỉ lấy `page_size=15`, dẫn tới danh sách version bị rỗng.

## Cách sử dụng nhanh trên VPS n8n

SSH vào VPS n8n bằng quyền `root`, sau đó chạy:

```bash
curl -fsSL https://raw.githubusercontent.com/baochinhtechvibe/tino-n8n-vps-agent-tools/main/update-n8n-agent-source-build.sh \
  -o /root/update-n8n-agent-source-build.sh

chmod +x /root/update-n8n-agent-source-build.sh
bash -n /root/update-n8n-agent-source-build.sh
bash /root/update-n8n-agent-source-build.sh
```

Sau khi chạy, script sẽ hỏi:

```text
Nhập API Key của N8N-Agent:
```

Khi anh nhập API key, terminal sẽ hiển thị dạng `****` để dễ biết mình đang nhập, nhưng không hiện key thật.

> Không commit API key thật vào repo. Chỉ nhập khi chạy script hoặc lưu ở `/etc/n8n-agent.env` trên VPS.

## Cách script xử lý API key

Mặc định khi chạy trực tiếp:

```bash
bash /root/update-n8n-agent-source-build.sh
```

script sẽ hỏi nhập API key và hiển thị ký tự `*` khi nhập.

Nếu anh không nhập gì rồi bấm Enter, script sẽ thử dùng key cũ trong các file sau:

```text
/etc/n8n-agent.env
/opt/n8n-agent/.env
/opt/n8n/.env
```

Nếu vẫn không tìm thấy key, script sẽ dừng và báo lỗi.

Ngoài ra vẫn có thể truyền key bằng biến môi trường nếu cần chạy tự động:

```bash
AGENT_API_KEY='YOUR_SECRET_KEY' bash /root/update-n8n-agent-source-build.sh
```

Cách này phù hợp cho automation, nhưng khi thao tác thủ công nên chạy `bash /root/update-n8n-agent-source-build.sh` để script hỏi key.

## Script sẽ thay đổi gì?

Trước khi chạy, service thường dùng binary đóng gói:

```text
/opt/n8n-agent/n8n-agent
```

Sau khi chạy, service sẽ chuyển sang chạy bản source build:

```text
/usr/bin/node /opt/n8n-agent-src/dist/main.js
```

Systemd unit sẽ load biến môi trường từ:

```text
/etc/n8n-agent.env
```

File này dùng để giữ secret runtime, ví dụ:

```bash
AGENT_API_KEY=...
```

và nên có quyền:

```bash
chmod 600 /etc/n8n-agent.env
```

## Quy trình script thực hiện

Script sẽ chạy theo thứ tự:

1. Kiểm tra đang chạy bằng user `root`.
2. Backup service, app cũ, source cũ và env file.
3. Đảm bảo `AGENT_API_KEY` được lưu trong `/etc/n8n-agent.env`.
4. Cài các package build cần thiết nếu VPS chưa có.
5. Clone hoặc cập nhật source từ `tinovn/n8n-manage` vào `/opt/n8n-agent-src`.
6. Nếu source vẫn còn URL cũ `page_size=15`, script sẽ patch local sang `page_size=100`.
7. Chạy `npm ci` và `npm run build`.
8. Ghi lại systemd unit `n8n-agent.service` để chạy `/opt/n8n-agent-src/dist/main.js`.
9. Restart `n8n-agent`.
10. Gọi API `/api/n8n/version` để xác minh `latest` và `all` đã có dữ liệu.
11. Test API kèm header `tng-api-key`.
12. In đường dẫn backup và lệnh rollback.

## Kiểm tra sau khi chạy

Kiểm tra service:

```bash
systemctl status n8n-agent --no-pager -l
```

Kiểm tra API version:

```bash
curl -sS http://127.0.0.1:7071/api/n8n/version | python3 -m json.tool
```

Kết quả mong đợi:

```json
{
  "statusCode": 200,
  "message": "Successfully retrieved version info.",
  "data": {
    "current": "...",
    "latest": {
      "version": "..."
    },
    "all": [
      {
        "version": "..."
      }
    ]
  }
}
```

## Backup và rollback

Trước khi thay đổi, script tạo backup dạng:

```text
/root/n8n-agent-backup-YYYY-MM-DD-HHMMSS
/root/n8n-agent-backup-YYYY-MM-DD-HHMMSS.tar.gz
```

Cuối quá trình chạy, script sẽ in lệnh rollback tương ứng với backup vừa tạo.

Ví dụ rollback thủ công:

```bash
cp -a /root/n8n-agent-backup-YYYY-MM-DD-HHMMSS/n8n-agent.service /etc/systemd/system/n8n-agent.service
rm -rf /opt/n8n-agent
cp -a /root/n8n-agent-backup-YYYY-MM-DD-HHMMSS/opt-n8n-agent /opt/n8n-agent

if [ -f /root/n8n-agent-backup-YYYY-MM-DD-HHMMSS/n8n-agent.env ]; then
  cp -a /root/n8n-agent-backup-YYYY-MM-DD-HHMMSS/n8n-agent.env /etc/n8n-agent.env
fi

systemctl daemon-reload
systemctl restart n8n-agent
```

## Lưu ý bảo mật

Không commit secret vào repo này.

Không được commit các thông tin sau:

- `AGENT_API_KEY`
- File `.env`
- Mật khẩu VPS
- GitHub token
- SSH private key

Secret runtime nên đặt trên từng VPS tại:

```text
/etc/n8n-agent.env
```

với quyền:

```bash
chmod 600 /etc/n8n-agent.env
```

## Khi nào nên dùng script này?

Dùng script này khi:

- VPS đang chạy `n8n-agent` binary cũ.
- Repo `tinovn/n8n-agent` chưa có binary mới.
- Cần cập nhật VPS nhanh để nhận fix từ `tinovn/n8n-manage`.
- API `/api/n8n/version` trả `latest: null` hoặc `all: []` dù n8n container vẫn có `current`.

Không nên xem đây là flow release dài hạn.

## Flow dài hạn nên dùng

Script này là workaround phía VPS khi binary ở `tinovn/n8n-agent` chưa được update.

Flow chuẩn lâu dài nên là:

```text
tinovn/n8n-manage source
→ build packaged n8n-agent binary
→ push binary mới sang tinovn/n8n-agent
→ VPS chạy /opt/n8n-agent/update-agent.sh
```

Khi binary ở `tinovn/n8n-agent` đã được cập nhật, các VPS có thể quay lại flow chuẩn:

```bash
bash /opt/n8n-agent/update-agent.sh
```
