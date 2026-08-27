import SwiftUI

struct ContentView: View {
    @StateObject private var model = TransferModel()
    @ObservedObject private var uploader =
        RawBackgroundUploadManager.shared

    @State private var showFolderPicker = false
    @State private var showPhotoPicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    eventCard
                    sourceCard
                    connectionCard
                    pickerCard

                    if !model.extensionStats.isEmpty {
                        extensionPickerCard
                    }

                    transferCard
                }
                .padding()
            }
            .navigationTitle("RAW Bridge")
            .sheet(isPresented: $showFolderPicker) {
                FolderPicker { url in
                    showFolderPicker = false
                    model.scanFilesFolder(url)
                }
            }
            .sheet(isPresented: $showPhotoPicker) {
                PhotoPicker { assetIDs in
                    showPhotoPicker = false
                    model.importCameraRoll(assetIDs: assetIDs)
                }
            }
        }
    }

    private var eventCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("1 • THÔNG TIN SỰ KIỆN")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            TextField(
                "Tên sự kiện, ví dụ: Khai giảng 2026",
                text: $model.eventName
            )
            .textFieldStyle(.roundedBorder)

            Text("CONTENT SƠ BỘ")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)

            TextEditor(text: $model.roughContent)
                .frame(minHeight: 110)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.20))
                )

            Text(
                "Nội dung này được lưu vào event.json để dùng cho AI viết content/caption và voice."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("2 • NGUỒN DỮ LIỆU")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            Picker(
                "Nguồn dữ liệu",
                selection: $model.importSource
            ) {
                ForEach(ImportSource.allCases) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .pickerStyle(.segmented)

            Text(
                model.importSource == .files
                    ? "Thẻ SD, đầu đọc thẻ hoặc thư mục trong Files."
                    : "Chọn nhiều ảnh/video trực tiếp trong ứng dụng Ảnh."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("3 • PC QUA TAILSCALE")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            TextField(
                "http://100.x.x.x:8000",
                text: $model.serverURL
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .textFieldStyle(.roundedBorder)

            Button {
                Task { await model.testConnection() }
            } label: {
                Label(
                    "Kiểm tra kết nối",
                    systemImage: "network"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .cardStyle()
    }

    private var pickerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("4 • CHỌN DỮ LIỆU")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            HStack {
                Image(
                    systemName:
                        model.importSource == .files
                        ? "externaldrive"
                        : "photo.on.rectangle.angled"
                )
                .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selectedFolderName)
                        .font(.headline)

                    Text(
                        model.scanning
                        ? "Đang đọc dữ liệu..."
                        : "\(model.items.count) file • \(model.totalSizeText)"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Button {
                if model.importSource == .files {
                    showFolderPicker = true
                } else {
                    showPhotoPicker = true
                }
            } label: {
                Label(
                    model.importSource == .files
                        ? "Chọn thư mục"
                        : "Chọn ảnh / video",
                    systemImage:
                        model.importSource == .files
                        ? "folder.badge.plus"
                        : "photo.stack"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                model.scanning ||
                model.preparing ||
                uploader.isUploading
            )

            if model.scanning || model.preparing {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }

            if model.preparing {
                Text(
                    "Đang sao chép file đã chọn vào vùng an toàn của app để iOS có thể upload khi app chạy nền."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private var extensionPickerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("5 • TÍCH ĐUÔI FILE CẦN GỬI")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            Divider()

            ForEach(model.extensionStats) { stat in
                Toggle(
                    isOn: Binding(
                        get: {
                            model.isSelected(stat.ext)
                        },
                        set: {
                            model.setSelected(stat.ext, $0)
                        }
                    )
                ) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(".\(stat.ext.uppercased())")
                                .font(.headline.monospaced())

                            Text(categoryText(stat.category))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(stat.count) file")
                                .font(.subheadline)

                            Text(stat.sizeText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.switch)

                if stat.id != model.extensionStats.last?.id {
                    Divider()
                }
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ĐÃ CHỌN")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text("\(model.selectedCount) file")
                        .font(.headline)
                }

                Spacer()

                Text(model.selectedSizeText)
                    .font(.headline.monospacedDigit())
            }
        }
        .cardStyle()
    }

    private var transferCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("6 • GỬI VỀ PC")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            if !uploader.currentFile.isEmpty {
                Text(uploader.currentFile)
                    .font(.footnote.monospaced())
                    .lineLimit(2)
            }

            ProgressView(value: uploader.overallProgress)
                .progressViewStyle(.linear)

            HStack {
                Text(
                    "\(uploader.completedFiles)/\(uploader.totalFiles) file"
                )
                Spacer()
                Text(
                    "\(Int(uploader.overallProgress * 100))%"
                )
            }
            .font(.footnote.monospacedDigit())
            .foregroundStyle(.secondary)

            Text(
                uploader.isUploading ||
                uploader.completedFiles > 0
                    ? uploader.statusText
                    : model.status
            )
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)

            if uploader.isUploading {
                if uploader.isPaused {
                    Button {
                        uploader.resume()
                    } label: {
                        Label(
                            "TIẾP TỤC",
                            systemImage: "play.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        uploader.pause()
                    } label: {
                        Label(
                            "TẠM DỪNG",
                            systemImage: "pause.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Text(
                    "Có thể chuyển sang app khác hoặc khóa màn hình sau khi phần chuẩn bị hoàn tất. Nếu force-quit RAW Bridge, file đang gửi có thể phải gửi lại, nhưng queue các file đã xong vẫn được giữ."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
                Button {
                    Task {
                        await model.startUpload()
                    }
                } label: {
                    Label(
                        "Gửi \(model.selectedCount) file về PC",
                        systemImage: "arrow.up.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    model.selectedCount == 0 ||
                    model.scanning ||
                    model.preparing ||
                    model.eventName
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                        .isEmpty
                )
            }
        }
        .cardStyle()
    }

    private func categoryText(
        _ category: MediaCategory
    ) -> String {
        switch category {
        case .raw: return "ẢNH RAW"
        case .photo: return "ẢNH"
        case .video: return "VIDEO"
        case .other: return "KHÁC"
        }
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .padding()
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 18)
            )
    }
}
