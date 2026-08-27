# RAW Bridge 1.3.1 BUILD FIX

Sửa lỗi build Xcode/GitHub Actions của v1.3:
- Assets.xcassets được đưa về đúng Resources phase.
- Khai báo đầy đủ PBXFileReference cho Swift/assets.
- Thêm Combine cho ObservableObject/@Published.
- MediaCategory conform Codable để MediaRef Codable compile được.
- App icon xuất lại RGB, không có alpha.
- Workflow thêm bước Validate Xcode project và nâng checkout/upload-artifact.
- Gộp server hotfix v1.2.2 chống WinError 32.

Chức năng v1.3 vẫn giữ nguyên: Camera Roll + background URLSession queue + icon.
