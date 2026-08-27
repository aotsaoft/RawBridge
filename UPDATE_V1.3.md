# RAW Bridge 1.3

Cập nhật lớn:
- Thêm nguồn dữ liệu **Ảnh chụp / Camera Roll**.
- Giữ nguồn **Thẻ nhớ / Files**.
- App quét Camera Roll, export tài nguyên gốc để upload:
  - JPG / HEIC / PNG
  - MOV / MP4
  - DNG / RAW nếu có trong Photos
- Upload chuyển sang **Background URLSession**.
- Queue upload được lưu lại trên máy, mở lại app sẽ tiếp tục queue còn lại thay vì phải chọn lại toàn bộ từ đầu.
- Thêm icon app mới.

Lưu ý:
- Bản này cải thiện rất nhiều việc ra khỏi app / mở lại app.
- Nếu force quit (vuốt tắt hẳn app) giữa lúc upload, iOS có thể dừng một số tác vụ nền; khi mở app lại queue vẫn còn để chạy tiếp.
- Đây là hướng đúng hơn nhiều so với bản upload foreground trước.
