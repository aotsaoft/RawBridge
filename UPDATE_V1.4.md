# RAW Bridge 1.4

## 1. Trộn nguồn trong cùng một phiên
- Có hai nút độc lập:
  - THÊM TỪ THẺ / FILES
  - THÊM TỪ CAMERA ROLL
- Thêm nguồn thứ hai sẽ cộng vào danh sách hiện có, không xóa nguồn thứ nhất.
- Có bộ đếm riêng Thẻ/Files, Camera Roll và Tổng.

## 2. Khôi phục tốc độ truyền
Trong lúc upload hiển thị:
- MB/s
- Mbps
- ETA còn lại
Tốc độ dùng smoothing để đỡ nhảy số.

## 3. Phiên gửi mới
Sau khi hoàn tất xuất hiện:
- TẠO PHIÊN GỬI MỚI
Không cần force-close/tắt mở app.
Server URL và trạng thái kết nối được giữ lại.

## 4. Kiểm tra kết nối
Nút kiểm tra kết nối có trạng thái riêng ngay trong card:
- đang kiểm tra
- kết nối thành công + tên/version server nếu có
- timeout / không mở cổng / mất mạng / HTTP lỗi

## 5. Mixed-source background upload
- Camera Roll đã nằm trong app sandbox.
- File từ thẻ/Files được copy vào staging trước background upload.
- Hai loại được gộp chung vào một queue upload.
