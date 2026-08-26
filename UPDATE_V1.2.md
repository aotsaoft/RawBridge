# RAW Bridge 1.2 — cập nhật

## Không thay đổi app xử lý RAW hiện tại

Bản này chỉ thay RAW Bridge + receiver trên PC.

## Tính năng mới

1. Nhập **Tên sự kiện**.
2. Nhập **Content sơ bộ**.
3. Chọn cả thư mục trên thẻ nhớ.
4. App quét toàn bộ file và gom theo đuôi:
   - ARW, CR2, CR3, DNG, NEF...
   - JPG/JPEG/HEIC/PNG...
   - MP4/MOV/AVI...
   - các đuôi khác vẫn hiện là KHÁC.
5. Có công tắc cho từng đuôi. Đuôi nào tích thì chỉ gửi đuôi đó.
6. Có nút nhanh:
   - RAW
   - ẢNH = RAW + ảnh JPG/HEIC...
   - VIDEO
   - TẤT CẢ
   - BỎ CHỌN
7. PC tự tách file:
   - PHOTO/RAW
   - PHOTO/JPG
   - PHOTO/HEIC...
   - VIDEO/MP4
   - VIDEO/MOV
   - OTHER/<EXT>
8. PC lưu:
   - EVENT/event.json
   - EVENT/UPLOAD_COMPLETE.json

## Ví dụ

Nếu thẻ có:

- 180 ARW
- 180 JPG
- 20 MP4
- 4 MOV

và trên app chỉ tích:

- ARW
- MP4

thì PC chỉ nhận:

RECEIVED/
  KHAI_GIANG/
    PHOTO/
      RAW/
        *.ARW
    VIDEO/
      MP4/
        *.MP4
    EVENT/
      event.json
      UPLOAD_COMPLETE.json

JPG và MOV không được truyền.

Nếu tích ARW + JPG thì nhận cả hai nhưng PC vẫn tự tách RAW và JPG.

## Content sơ bộ

Nội dung nhập trên iPhone nằm trong:

`EVENT/event.json`

trường:

`rough_content`

Sau này module AI chỉ cần đọc file này để tạo:

- caption/content Facebook
- voice script
- video caption

## UPLOAD_COMPLETE

`EVENT/UPLOAD_COMPLETE.json` chỉ xuất hiện khi toàn bộ file được chọn đã gửi xong.

Đây là dấu hiệu an toàn để connector sau này gọi app RAW hiện có, tránh xử lý khi file còn đang upload.

## Cập nhật lên GitHub

Thay toàn bộ project hiện tại bằng nội dung ZIP này hoặc upload các file thay đổi rồi commit.

GitHub Actions sẽ tự build lại IPA.

Sau khi build thành công:
- tải artifact IPA
- cài/refresh lại bằng Sideloadly

## Server PC

Dừng receiver cũ rồi chạy lại:

`Server/run_server.bat`

Health:

`http://100.120.33.35:8000/health`

Bản đúng trả version 1.2.
