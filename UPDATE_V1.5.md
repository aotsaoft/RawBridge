# RAW Bridge 1.5

## Background upload - sửa kiến trúc
Bản cũ chỉ tạo 1 URLSessionUploadTask mỗi lần. Khi app bị suspend,
iOS có thể hoàn tất file hiện tại nhưng app không còn chạy để tạo file kế tiếp.

Bản 1.5:
- tạo TẤT CẢ background upload tasks ngay khi bắt đầu phiên;
- iOS background transfer service tự quản lý hàng đợi;
- tối đa 2 kết nối tới PC chạy song song;
- queue và completed job IDs được lưu;
- app bị system suspend/terminate vẫn có thể reconnect cùng background session;
- mỗi file có job_id idempotent để retry không tạo file trùng;
- server tự tạo UPLOAD_COMPLETE.json khi đã nhận đủ expected_file_count;
- không cần app thức để gọi complete-event.

LƯU Ý iOS:
- chuyển sang app khác / về Home / khóa màn hình: background URLSession được thiết kế để tiếp tục;
- nếu người dùng vuốt force-quit RAW Bridge khỏi App Switcher, iOS hủy background transfers.
  Đây là giới hạn của iOS, app không thể override.

## Camera Roll
- file do người dùng chọn trong Photos được AUTO SELECT;
- không cần tick đuôi lần nữa;
- tick extension chỉ còn áp dụng cho media từ thẻ / Files;
- mỗi mục Photos chọn lấy một resource chính (ảnh hoặc video).

## Tốc độ
- bỏ Mbps;
- chỉ hiển thị MB/s + ETA.

Version 1.5
Build 10
Server 1.5
