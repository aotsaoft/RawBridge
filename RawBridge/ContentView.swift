import SwiftUI

struct ContentView: View {
    @StateObject private var model = TransferModel()
    @State private var showFolderPicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    eventCard
                    connectionCard
                    folderCard

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
                    model.selectFolder(url)
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
                .frame(minHeight: 120)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.20))
                )

            Text("Phần này sẽ được lưu vào event.json để sau đó đưa cho AI viết caption/content và voice script.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PC QUA TAILSCALE")
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
                Label("Kiểm tra kết nối", systemImage: "network")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.uploading)
        }
        .cardStyle()
    }

    private var folderCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("2 • CHỌN THƯ MỤC / THẺ NHỚ")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            HStack {
                Image(systemName: "externaldrive")
                    .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selectedFolderName)
                        .font(.headline)

                    Text(
                        model.scanning
                        ? "Đang quét ở nền..."
                        : "\(model.items.count) file • \(model.totalSizeText)"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Button {
                showFolderPicker = true
            } label: {
                Label("Chọn thư mục", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.uploading || model.scanning)

            if model.scanning {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        }
        .cardStyle()
    }

    private var extensionPickerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("3 • TÍCH ĐUÔI FILE CẦN GỬI")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                quickButton("RAW", action: model.selectRawOnly)
                quickButton("ẢNH", action: model.selectPhotoAndRaw)
                quickButton("VIDEO", action: model.selectVideoOnly)
            }

            HStack(spacing: 8) {
                quickButton("TẤT CẢ", action: model.selectAll)
                quickButton("BỎ CHỌN", action: model.clearSelection)
            }

            Divider()

            ForEach(model.extensionStats) { stat in
                Toggle(
                    isOn: Binding(
                        get: { model.isSelected(stat.ext) },
                        set: { model.setSelected(stat.ext, $0) }
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
            .padding(.top, 4)
        }
        .cardStyle()
    }

    private var transferCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("4 • GỬI VỀ PC")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            if !model.currentFile.isEmpty {
                Text(model.currentFile)
                    .font(.footnote.monospaced())
                    .lineLimit(2)
            }

            ProgressView(value: model.overallProgress)
                .progressViewStyle(.linear)

            HStack {
                Text("\(Int(model.overallProgress * 100))%")
                Spacer()
                Text(String(format: "%.2f MB/s", model.averageSpeedMBs))
                Spacer()
                Text("Còn \(model.etaText)")
            }
            .font(.footnote.monospacedDigit())
            .foregroundStyle(.secondary)

            Text(model.status)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)

            if model.uploading {
                Button(role: .destructive) {
                    model.stopUpload()
                } label: {
                    Label("Dừng", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    Task { await model.startUpload() }
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
                    model.eventName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .cardStyle()
    }

    private func quickButton(
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .font(.caption.bold())
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
    }

    private func categoryText(_ category: MediaCategory) -> String {
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
