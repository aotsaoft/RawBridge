# RAW Bridge — Build IPA bằng GitHub, không cần Mac

## Mục tiêu

Bạn không cần máy Mac và chưa cần Apple Developer trả phí.

Quy trình:

1. Đưa project này lên GitHub.
2. GitHub Actions chạy trên máy macOS của GitHub.
3. GitHub build ra `RawBridge-unsigned.ipa`.
4. Tải IPA về Windows.
5. Dùng Sideloadly ký IPA bằng Apple ID miễn phí và cài vào iPhone.

> IPA do GitHub tạo là **chưa ký**. Đây là chủ ý. Sideloadly sẽ ký lại khi cài.

---

## A. Đưa project lên GitHub

### Cách dễ nhất

1. Tạo một repository mới trên GitHub, ví dụ `RawBridge`.
2. Giải nén ZIP này.
3. **Upload toàn bộ nội dung bên trong thư mục `RawBridge` lên thư mục gốc của repository.**

Sau khi upload, GitHub phải nhìn thấy trực tiếp:

- `RawBridge.xcodeproj`
- thư mục `RawBridge`
- thư mục `Server`
- `.github/workflows/build-ipa.yml`
- `README.md`

Không để thành:

`RawBridge/RawBridge/RawBridge.xcodeproj`

nếu repository của bạn đã có tên RawBridge.

---

## B. Chạy build IPA

1. Mở repository trên GitHub.
2. Chọn tab **Actions**.
3. Chọn workflow **Build RawBridge IPA**.
4. Chọn **Run workflow**.
5. Chờ build hoàn thành.

Workflow cũng tự chạy khi push lên nhánh `main` hoặc `master`.

---

## C. Tải IPA về Windows

Khi workflow hiện dấu tích xanh:

1. Mở lần chạy đó.
2. Kéo xuống phần **Artifacts**.
3. Tải:
   `RawBridge-unsigned-IPA`
4. Giải nén artifact.

Bên trong có:

`RawBridge-unsigned.ipa`

---

## D. Cài bằng Sideloadly

1. Cài Sideloadly trên Windows.
2. Kết nối iPhone với PC.
3. Tin cậy máy tính nếu iPhone hỏi.
4. Kéo `RawBridge-unsigned.ipa` vào Sideloadly.
5. Nhập Apple ID.
6. Bấm Start.

Với Apple ID miễn phí, app thường phải được ký lại sau khoảng 7 ngày.

---

## E. Sau khi cài app

Trên PC:

1. Bật Tailscale.
2. Vào `Server`.
3. Chạy `run_server.bat`.

Trên iPhone:

1. Bật Tailscale.
2. Mở RAW Bridge.
3. Server mặc định:
   `http://100.120.33.35:8000`
4. Bấm **Kiểm tra kết nối**.
5. Cắm thẻ SD vào iPhone.
6. Bấm **Chọn thư mục**.
7. Chọn thư mục trên thẻ.
8. App quét RAW/video.
9. Nhập tên sự kiện.
10. Bấm **Gửi tất cả về PC**.

File về PC tại:

`Server\RECEIVED\<Tên sự kiện>\RAW`

và:

`Server\RECEIVED\<Tên sự kiện>\VIDEO`

---

## F. Nếu GitHub build báo lỗi

Mở:

Actions → Build RawBridge IPA → build-ios

Sau đó copy phần log màu đỏ gửi lại để sửa.

---

## Giới hạn bản MVP

- Chưa có resume theo chunk khi mất mạng giữa một file.
- Chưa nhớ thư mục SD qua lần mở app sau.
- Chưa có Telegram/AI workflow.
- Chưa xác thực server bằng token riêng.
- HTTP hiện chỉ dùng để test trong Tailnet.

Các phần này nên thêm sau khi xác nhận app cài được, quét được cả thư mục và truyền file ổn định.


## Bản 1.3
- Có thêm Camera Roll và background upload.
