import Foundation
import Photos

enum PhotoLibraryImportError: Error {
    case permissionDenied
}

final class PhotoLibraryScanner {
    static let shared = PhotoLibraryScanner()

    func requestAccess() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .authorized || status == .limited { return true }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                continuation.resume(returning: newStatus == .authorized || newStatus == .limited)
            }
        }
    }

    func scanRecentAssets(limit: Int = 5000) async throws -> [TransferModel.MediaRef] {
        guard await requestAccess() else { throw PhotoLibraryImportError.permissionDenied }

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let exportDir = support.appendingPathComponent("RawBridge/PhotoCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit

        let results = PHAsset.fetchAssets(with: options)
        var refs: [TransferModel.MediaRef] = []

        try await withThrowingTaskGroup(of: TransferModel.MediaRef?.self) { group in
            results.enumerateObjects { asset, _, _ in
                group.addTask {
                    return try await self.exportAsset(asset, to: exportDir)
                }
            }

            for try await item in group {
                if let item { refs.append(item) }
            }
        }

        return refs.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    private func exportAsset(_ asset: PHAsset, to exportDir: URL) async throws -> TransferModel.MediaRef? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first else { return nil }

        let ext = (resource.originalFilename as NSString).pathExtension.lowercased()
        let category: MediaCategory
        if TransferModel.rawExtensionSet.contains(ext) {
            category = .raw
        } else if TransferModel.photoExtensionSet.contains(ext) {
            category = .photo
        } else if TransferModel.videoExtensionSet.contains(ext) {
            category = .video
        } else {
            category = .other
        }

        let safeFilename = "\(asset.localIdentifier.replacingOccurrences(of: "/", with: "_"))_\(resource.originalFilename)"
        let outURL = exportDir.appendingPathComponent(safeFilename)

        if !FileManager.default.fileExists(atPath: outURL.path) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let opts = PHAssetResourceRequestOptions()
                opts.isNetworkAccessAllowed = true
                PHAssetResourceManager.default().writeData(for: resource, toFile: outURL, options: opts) { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            }
        }

        let attr = try? FileManager.default.attributesOfItem(atPath: outURL.path)
        let size = (attr?[.size] as? NSNumber)?.int64Value ?? 0
        let relative = "CameraRoll/\(resource.originalFilename)"

        return TransferModel.MediaRef(url: outURL, relativePath: relative, size: size, ext: ext, category: category)
    }
}
