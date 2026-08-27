# RAW Bridge 1.3.2 BUILD FIX

Lỗi exit code 74 của bản trước là do project.pbxproj đã chứa ký tự literal `\t`
thay vì tab/whitespace thật, khiến Xcode không đọc được project.

Bản này:
- dựng lại project.pbxproj từ project v1.2.1 đã từng build thành công;
- dùng whitespace thật, không còn literal `\t`;
- thêm đúng BackgroundUploadManager, ImportSource, PhotoPicker,
  PhotoLibraryScanner và Assets.xcassets;
- Assets chỉ nằm trong Resources;
- bỏ RawFileUploader cũ khỏi target;
- giữ Camera Roll, background upload, Pause/Resume, icon;
- gộp server hotfix WinError32;
- workflow có bước Validate Xcode project trước Build.
