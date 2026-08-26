import SwiftUI

struct ContentView: View {
    @StateObject private var model = TransferModel()
    @State private var showFolderPicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    headerCard
                    connectionCard
                    folderCard
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

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SỰ KIỆN")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            TextField("Ví dụ: Khai giảng 2026", text: $model.eventName)
                .textFieldStyle(.roundedBorder)

            Text("App chỉ truyền file. RAW/video gốc không bị đổi định dạng.")
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

            TextField("http://100.x.x.x:8000", text: $model.serverURL)
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
            Text("THẺ NHỚ / THƯ MỤC")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            HStack {
                Image(systemName: "folder")
                VStack(alignment: .leading) {
                    Text(model.selectedFolderName)
                        .font(.headline)
                    Text(model.scanning ? "Đang quét ở nền..." : "Chọn một thư mục trên SD/Files")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Button {
                showFolderPicker = true
            } label: {
                Label("Chọn thư mục", systemImage: "externaldrive")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.uploading || model.scanning)

            if model.scanning {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }

            HStack(spacing: 10) {
                stat(title: "RAW", value: "\(model.rawCount)")
                stat(title: "VIDEO", value: "\(model.videoCount)")
                stat(title: "TỔNG", value: model.totalSizeText)
            }
        }
        .cardStyle()
    }

    private var transferCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TRUYỀN VỀ PC")
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
                    Label("Gửi tất cả về PC", systemImage: "arrow.up.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.items.isEmpty || model.scanning)
            }
        }
        .cardStyle()
    }

    private func stat(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}
