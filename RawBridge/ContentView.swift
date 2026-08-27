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
                    mediaSourceCard
                    connectionCard

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
                    model.addFilesFolder(url)
                }
            }
            .sheet(isPresented: $showPhotoPicker) {
                PhotoPicker { assetIDs in
                    showPhotoPicker = false
                    model.addCameraRoll(assetIDs: assetIDs)
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
                .frame(minHeight: 105)
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
                "Lưu vào event.json để dùng tiếp cho AI viết content/caption và voice."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var mediaSourceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("2 • THÊM MEDIA")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            Text(
                "Có thể thêm cả hai nguồn trong cùng một phiên."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            Button {
                showFolderPicker = true
            } label: {
                Label(
                    "THÊM TỪ THẺ / FILES",
                    systemImage: "externaldrive.badge.plus"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                model.scanning ||
                model.preparing ||
                uploader.isUploading
            )

            Button {
                showPhotoPicker = true
            } label: {
                Label(
                    "THÊM TỪ CAMERA ROLL",
                    systemImage: "photo.stack"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(
                model.scanning ||
                model.preparing ||
                uploader.isUploading
            )

            HStack(spacing: 12) {
                mediaCount(
                    title: "THẺ / FILES",
                    value: model.filesSourceCount
                )

                Divider()

                mediaCount(
                    title: "CAMERA ROLL",
                    value: model.cameraRollCount
                )

                Divider()

                mediaCount(
                    title: "TỔNG",
                    value: model.items.count
                )
            }
            .frame(maxWidth: .infinity)

            if !model.items.isEmpty && !uploader.isUploading {
                Button(role: .destructive) {
                    model.clearMediaSelection()
                } label: {
                    Label(
                        "Xóa danh sách media",
                        systemImage: "trash"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if model.scanning || model.preparing {
                ProgressView()
                    .frame(maxWidth: .infinity)

                Text(model.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if !model.items.isEmpty {
                Text(
                    "\(model.items.count) file • \(model.totalSizeText)"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
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
                Task {
                    await model.testConnection()
                }
            } label: {
                HStack {
                    if model.isTestingConnection {
                        ProgressView()
                    } else {
                        Image(systemName: "network")
                    }

                    Text(
                        model.isTestingConnection
                            ? "Đang kiểm tra..."
                            : "Kiểm tra kết nối"
                    )
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.isTestingConnection)

            HStack(alignment: .top, spacing: 8) {
                Image(
                    systemName: connectionIcon
                )
                .foregroundStyle(connectionColor)

                Text(model.connectionStatus)
                    .font(.footnote)
                    .foregroundStyle(
                        model.connectionOK == nil
                            ? Color.secondary
                            : connectionColor
                    )
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
            }
        }
        .cardStyle()
    }

    private var extensionPickerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("4 • TÍCH ĐUÔI FILE CẦN GỬI")
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
            Text("5 • GỬI VỀ PC")
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

            if uploader.isUploading && !uploader.isPaused {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("TỐC ĐỘ")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Text(
                            String(
                                format: "%.2f MB/s",
                                uploader.speedMBs
                            )
                        )
                        .font(.headline.monospacedDigit())

                        Text(
                            String(
                                format: "%.1f Mbps",
                                uploader.speedMbps
                            )
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("CÒN LẠI")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Text(uploader.etaText)
                            .font(.headline.monospacedDigit())
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.08))
                )
            }

            Text(
                uploader.isUploading ||
                uploader.sessionCompleted ||
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
                    "Sau khi bước chuẩn bị hoàn tất, có thể chuyển app hoặc khóa màn hình. Force-quit có thể làm file đang truyền phải gửi lại, nhưng các file đã hoàn tất vẫn được ghi nhớ."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

            } else if uploader.sessionCompleted {
                Button {
                    model.newTransferSession()
                } label: {
                    Label(
                        "TẠO PHIÊN GỬI MỚI",
                        systemImage: "plus.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Text(
                    "Dùng để gửi sự kiện/lần thứ 2 mà không cần tắt rồi mở lại app."
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

    private func mediaCount(
        title: String,
        value: Int
    ) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text("\(value)")
                .font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity)
    }

    private var connectionIcon: String {
        if model.isTestingConnection {
            return "clock"
        }

        switch model.connectionOK {
        case true:
            return "checkmark.circle.fill"
        case false:
            return "xmark.circle.fill"
        case nil:
            return "circle.dashed"
        }
    }

    private var connectionColor: Color {
        switch model.connectionOK {
        case true:
            return .green
        case false:
            return .red
        case nil:
            return .secondary
        }
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
