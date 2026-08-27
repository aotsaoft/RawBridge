import Foundation
import Photos

enum PhotoLibraryImportError: LocalizedError {
    case permissionDenied
    case noResources

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Chưa được cấp quyền truy cập thư viện Ảnh."
        case .noResources:
            return "Không tìm thấy file gốc trong các mục đã chọn."
        }
    }
}

final class PhotoLibraryScanner {
    static let shared = PhotoLibraryScanner()

    func requestAccess() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)

        if status == .authorized || status == .limited {
            return true
        }

        return await withCheckedContinuation {
            (continuation: CheckedContinuation<Bool, Never>) in

            PHPhotoLibrary.requestAuthorization(for: .readWrite) {
                newStatus in

                continuation.resume(
                    returning:
                        newStatus == .authorized ||
                        newStatus == .limited
                )
            }
        }
    }

    func importAssets(
        assetIDs: [String]
    ) async throws -> [TransferModel.MediaRef] {
        guard await requestAccess() else {
            throw PhotoLibraryImportError.permissionDenied
        }

        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let exportDir = support
            .appendingPathComponent("RawBridge/PhotoCache", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        try FileManager.default.createDirectory(
            at: exportDir,
            withIntermediateDirectories: true
        )

        let fetch = PHAsset.fetchAssets(
            withLocalIdentifiers: assetIDs,
            options: nil
        )

        var assetsByID: [String: PHAsset] = [:]
        fetch.enumerateObjects { asset, _, _ in
            assetsByID[asset.localIdentifier] = asset
        }

        var refs: [TransferModel.MediaRef] = []

        for assetID in assetIDs {
            guard let asset = assetsByID[assetID] else { continue }

            let resources = PHAssetResource.assetResources(for: asset)
            var seenNames: Set<String> = []

            for (index, resource) in resources.enumerated() {
                guard Self.shouldExport(resource.type) else { continue }

                let originalName = resource.originalFilename
                let ext = (originalName as NSString)
                    .pathExtension
                    .lowercased()

                guard !ext.isEmpty else { continue }
                guard !seenNames.contains(originalName) else { continue }
                seenNames.insert(originalName)

                let safeAsset = assetID
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: ":", with: "_")

                let localName =
                    "\(safeAsset)_\(index)_\(originalName)"

                let outURL = exportDir.appendingPathComponent(localName)

                try await writeResource(resource, to: outURL)

                let attrs = try? FileManager.default.attributesOfItem(
                    atPath: outURL.path
                )

                let size =
                    (attrs?[.size] as? NSNumber)?.int64Value ?? 0

                refs.append(
                    TransferModel.MediaRef(
                        url: outURL,
                        fileName: originalName,
                        relativePath: "CameraRoll/\(originalName)",
                        size: size,
                        ext: ext,
                        category: TransferModel.category(for: ext),
                        cleanupAfterUpload: true
                    )
                )
            }
        }

        guard !refs.isEmpty else {
            throw PhotoLibraryImportError.noResources
        }

        return refs.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath)
                == .orderedAscending
        }
    }

    private func writeResource(
        _ resource: PHAssetResource,
        to url: URL
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in

            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true

            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: url,
                options: options
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private static func shouldExport(
        _ type: PHAssetResourceType
    ) -> Bool {
        switch type {
        case .photo,
             .video,
             .alternatePhoto,
             .fullSizePhoto,
             .fullSizeVideo,
             .pairedVideo:
            return true

        default:
            return false
        }
    }
}
