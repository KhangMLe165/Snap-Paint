import SwiftUI
import UIKit

final class PortraitImagePickerController: UIImagePickerController {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .portrait }
    override var shouldAutorotate: Bool { false }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if #available(iOS 16.0, *),
           let scene = view.window?.windowScene {
            // Keep camera UI locked to portrait for consistent capture framing.
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
        }
    }
}

struct ImagePicker: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onImagePicked: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker: UIImagePickerController
        if sourceType == .camera {
            let cameraPicker = PortraitImagePickerController()
            cameraPicker.modalPresentationStyle = .fullScreen
            // Must be set before camera-specific properties to avoid UIKit source-type exception.
            cameraPicker.sourceType = .camera
            if UIImagePickerController.isCameraDeviceAvailable(.rear) {
                cameraPicker.cameraDevice = .rear
            } else if UIImagePickerController.isCameraDeviceAvailable(.front) {
                cameraPicker.cameraDevice = .front
            }
            if let modes = UIImagePickerController.availableCaptureModes(for: cameraPicker.cameraDevice),
               modes.contains(NSNumber(value: UIImagePickerController.CameraCaptureMode.photo.rawValue)) {
                cameraPicker.cameraCaptureMode = .photo
            }
            picker = cameraPicker
        } else {
            picker = UIImagePickerController()
        }
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: ImagePicker

        init(_ parent: ImagePicker) {
            self.parent = parent
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.dismiss()
            if let image = info[.originalImage] as? UIImage {
                DispatchQueue.main.async {
                    self.parent.onImagePicked(image)
                }
            }
        }
    }
}
