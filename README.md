# RAW Bridge 1.2

Bản mới: content sơ bộ + quét/tích từng đuôi file + PC tự tách PHOTO/VIDEO + event metadata.

Xem `UPDATE_V1.2.md`.

---

# RAW Bridge

Bản MVP iPhone native truyền RAW/video từ thẻ SD về PC qua Tailscale.

**Không có Mac / không có Apple Developer trả phí:** xem hướng dẫn:

`GITHUB_BUILD_WINDOWS.md`

GitHub Actions đã được cấu hình để tự build `RawBridge-unsigned.ipa`.

---

# RAW Bridge

Bản MVP iPhone native để:

1. Cắm thẻ SD vào iPhone.
2. Chọn cả thư mục bằng trình chọn thư mục của iOS.
3. App tự quét RAW/video ở tác vụ nền, không bắt trình duyệt dựng danh sách hàng trăm file.
4. Gửi từng file trực tiếp về PC qua địa chỉ Tailscale.
5. Hiển thị tiến độ, tốc độ trung bình và ETA.
6. PC tự phân loại thành `RAW` và `VIDEO`.

## Server PC

Chạy:

`Server\run_server.bat`

Địa chỉ mặc định trong app:

`http://100.120.33.35:8000`

File nhận được:

`Server\RECEIVED\<Tên sự kiện>\RAW\...`

`Server\RECEIVED\<Tên sự kiện>\VIDEO\...`

Server ghi file đang nhận với hậu tố `.part`, chỉ đổi thành tên thật khi nhận xong. Tool xử lý RAW sau này có thể bỏ qua `.part`.

## Mở project iPhone

Mở:

`RawBridge.xcodeproj`

Trong Xcode:

1. Chọn target **RawBridge**.
2. Signing & Capabilities -> chọn Apple Team của bạn.
3. Nếu Xcode yêu cầu, đổi Bundle Identifier `com.aotasoft.RawBridge` thành một ID duy nhất.
4. Cắm iPhone vào Mac, chọn iPhone làm Run Destination.
5. Bấm Run để cài thử.

## Lưu ý quan trọng

- Xcode và ký app iOS cần macOS/Xcode. Source code này không thể tạo `.ipa` đã ký ngay trên Windows.
- Bản MVP giữ quyền truy cập thư mục trong phiên app hiện tại. Bản sau có thể lưu security-scoped bookmark để nhớ thư mục.
- Bản này truyền tuần tự từng file và chưa resume giữa một file khi mất mạng. Bản production nên thêm upload theo chunk/resume.
- HTTP chỉ dùng trong Tailnet để test. Khi hoàn thiện nên chuyển receiver sang HTTPS hoặc cơ chế xác thực riêng.
