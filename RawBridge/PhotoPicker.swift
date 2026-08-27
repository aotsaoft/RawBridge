import PhotosUI
import SwiftUI

struct PhotoPicker: UIViewControllerRepresentable {
    let onPick: ([String]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(
        context: Context
    ) -> PHPickerViewController {
        var config = PHPickerConfiguration(
            photoLibrary: PHPhotoLibrary.shared()
        )
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = 0
        config.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(
        _ uiViewController: PHPickerViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: ([String]) -> Void

        init(onPick: @escaping ([String]) -> Void) {
            self.onPick = onPick
        }

        func picker(
            _ picker: PHPickerViewController,
            didFinishPicking results: [PHPickerResult]
        ) {
            picker.dismiss(animated: true)
            let ids = results.compactMap(\.assetIdentifier)
            onPick(ids)
        }
    }
}
