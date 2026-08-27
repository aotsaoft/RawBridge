import Foundation
import Photos

enum PhotoLibraryImportError:
    LocalizedError {

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
    static let shared =
        PhotoLibraryScanner()

    func requestAccess() async -> Bool {
        let status =
            PHPhotoLibrary
                .authorizationStatus(
                    for: .readWrite
                )

        if status == .authorized ||
            status == .limited {

            return true
        }

        return await withCheckedContinuation {
            (
                continuation:
                    CheckedContinuation<
                        Bool,
                        Never
                    >
            ) in

            PHPhotoLibrary
                .requestAuthorization(
                    for: .readWrite
                ) {
                    newStatus in

                    continuation.resume(
                        returning:
                            newStatus ==
                                .authorized ||
                            newStatus ==
                                .limited
                    )
                }
        }
    }

    func importAssets(
        assetIDs: [String]
    ) async throws
        -> [TransferModel.MediaRef] {

        guard await requestAccess()
        else {
            throw PhotoLibraryImportError
                .permissionDenied
        }

        let support =
            FileManager.default.urls(
                for:
                    .applicationSupportDirectory,
                in: .userDomainMask
            ).first!

        let exportDir =
            support
                .appendingPathComponent(
                    "RawBridge/PhotoCache",
                    isDirectory: true
                )
                .appendingPathComponent(
                    UUID().uuidString,
                    isDirectory: true
                )

        try FileManager.default
            .createDirectory(
                at: exportDir,
                withIntermediateDirectories:
                    true
            )

        let fetch =
            PHAsset.fetchAssets(
                withLocalIdentifiers:
                    assetIDs,
                options: nil
            )

        var assetsByID:
            [String: PHAsset] = [:]

        fetch.enumerateObjects {
            asset,
            _,
            _ in

            assetsByID[
                asset.localIdentifier
            ] = asset
        }

        var refs:
            [TransferModel.MediaRef] = []

        // Mỗi mục mà người dùng chọn trong Photos
        // -> lấy 1 resource chính.
        // Không bắt người dùng tick đuôi thêm lần nữa.
        for assetID in assetIDs {
            guard let asset =
                assetsByID[assetID]
            else {
                continue
            }

            let resources =
                PHAssetResource
                    .assetResources(
                        for: asset
                    )

            guard let resource =
                Self.primaryResource(
                    for: asset,
                    resources: resources
                )
            else {
                continue
            }

            let originalName =
                resource.originalFilename

            let ext =
                (originalName as NSString)
                    .pathExtension
                    .lowercased()

            guard !ext.isEmpty else {
                continue
            }

            let safeAsset =
                assetID
                    .replacingOccurrences(
                        of: "/",
                        with: "_"
                    )
                    .replacingOccurrences(
                        of: ":",
                        with: "_"
                    )

            let localName =
                "\(safeAsset)_\(originalName)"

            let outURL =
                exportDir
                    .appendingPathComponent(
                        localName
                    )

            try await writeResource(
                resource,
                to: outURL
            )

            let attrs =
                try? FileManager.default
                    .attributesOfItem(
                        atPath:
                            outURL.path
                    )

            let size =
                (attrs?[.size]
                    as? NSNumber)?
                    .int64Value ?? 0

            refs.append(
                TransferModel.MediaRef(
                    url: outURL,
                    fileName:
                        originalName,
                    relativePath:
                        "CameraRoll/\(originalName)",
                    size: size,
                    ext: ext,
                    category:
                        TransferModel
                            .category(
                                for: ext
                            ),
                    origin:
                        .cameraRoll,
                    cleanupAfterUpload:
                        true
                )
            )
        }

        guard !refs.isEmpty else {
            throw PhotoLibraryImportError
                .noResources
        }

        return refs.sorted {
            $0.relativePath
                .localizedStandardCompare(
                    $1.relativePath
                )
                == .orderedAscending
        }
    }

    private func writeResource(
        _ resource: PHAssetResource,
        to url: URL
    ) async throws {
        try await
            withCheckedThrowingContinuation {
                (
                    continuation:
                        CheckedContinuation<
                            Void,
                            Error
                        >
                ) in

                let options =
                    PHAssetResourceRequestOptions()

                // Nếu mục chỉ ở iCloud,
                // cho phép tải resource gốc về.
                options.isNetworkAccessAllowed =
                    true

                PHAssetResourceManager
                    .default()
                    .writeData(
                        for: resource,
                        toFile: url,
                        options: options
                    ) {
                        error in

                        if let error {
                            continuation
                                .resume(
                                    throwing:
                                        error
                                )
                        } else {
                            continuation
                                .resume()
                        }
                    }
            }
    }

    private static func primaryResource(
        for asset: PHAsset,
        resources: [PHAssetResource]
    ) -> PHAssetResource? {

        switch asset.mediaType {
        case .image:
            // Ưu tiên resource ảnh gốc.
            return resources.first {
                $0.type == .photo
            }
            ?? resources.first {
                $0.type ==
                    .fullSizePhoto
            }
            ?? resources.first {
                $0.type ==
                    .alternatePhoto
            }

        case .video:
            return resources.first {
                $0.type == .video
            }
            ?? resources.first {
                $0.type ==
                    .fullSizeVideo
            }

        default:
            return nil
        }
    }
}
