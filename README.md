# Tino n8n VPS Agent Tools

Bộ script hỗ trợ quản lý và cập nhật `n8n-agent` trên các VPS n8n của Tino Group.

## Cách sử dụng nhanh

SSH vào VPS n8n bằng quyền `root`, sau đó chạy một lệnh duy nhất:

```bash
curl -fsSL https://raw.githubusercontent.com/baochinhtechvibe/tino-n8n-vps-agent-tools/main/run-update-n8n-agent.sh | bash
```

Sau đó script sẽ hỏi:

```text
Nhập API Key của N8N-Agent:
```

Khi anh nhập API key, terminal sẽ hiển thị dạng `********` để biết đang nhập, nhưng **không hiện key thật**.

## Script một dòng sẽ làm gì?

Lệnh trên tải và chạy wrapper:

```text
run-update-n8n-agent.sh
```

Wrapper này sẽ tự động:

1. Kiểm tra đang chạy bằng user `root`.
2. Kiểm tra VPS có `bash` và `curl`.
3. Khi chạy qua `curl | bash`, tự chuyển phần nhập API key về terminal thật (`/dev/tty`) để anh vẫn nhập được key tương tác.
4. Tải script chính về:

```text
/root/update-n8n-agent-source-build.sh
```

5. Kiểm tra cú pháp script chính bằng:

```bash
bash -n /root/update-n8n-agent-source-build.sh
```

6. Nếu cú pháp OK, chạy script chính:

```bash
bash /root/update-n8n-agent-source-build.sh
```

Vì vậy khi dùng cách một dòng, anh không cần tự chạy các lệnh sau nữa:

```bash
chmod +x /root/update-n8n-agent-source-build.sh
bash -n /root/update-n8n-agent-source-build.sh
bash /root/update-n8n-agent-source-build.sh
```

## Script hiện có

### `run-update-n8n-agent.sh`

Wrapper dùng cho kỹ thuật chạy nhanh trên VPS n8n.

Chức năng:

- Tải script chính từ GitHub raw.
- Lưu vào `/root/update-n8n-agent-source-build.sh`.
- Kiểm tra cú pháp script chính.
- Chạy script chính.

### `update-n8n-agent-source-build.sh`

Script chính dùng để build và chạy source mới nhất từ `tinovn/n8n-manage` dưới dạng service `n8n-agent` local trên VPS.

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

## Cách script xử lý API key

Mặc định khi chạy bằng lệnh một dòng:

```bash
curl -fsSL https://raw.githubusercontent.com/baochinhtechvibe/tino-n8n-vps-agent-tools/main/run-update-n8n-agent.sh | bash
```

script chính sẽ hỏi nhập API key và hiển thị ký tự `*` khi nhập.

Nếu anh không nhập gì rồi bấm Enter, script sẽ thử dùng key cũ trong các file sau:

```text
/etc/n8n-agent.env
/opt/n8n-agent/.env
/opt/n8n/.env
```

Nếu vẫn không tìm thấy key, script sẽ dừng và báo lỗi.

Ngoài ra vẫn có thể truyền key bằng biến môi trường nếu cần chạy tự động:

```bash
curl -fsSL https://raw.githubusercontent.com/baochinhtechvibe/tino-n8n-vps-agent-tools/main/run-update-n8n-agent.sh | AGENT_API_KEY='YOUR_SECRET_KEY' bash
```

Cách này phù hợp cho automation. Khi thao tác thủ công, nên chạy lệnh một dòng bình thường để script hỏi key.

## Script chính sẽ thay đổi gì trên VPS?

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

## Quy trình script chính thực hiện

Script `update-n8n-agent-source-build.sh` sẽ chạy theo thứ tự:

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
