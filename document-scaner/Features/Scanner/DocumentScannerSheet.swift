//
//  DocumentScannerSheet.swift
//  document-scaner
//
//

import SwiftUI
import UIKit
import VisionKit

struct DocumentScannerSheet: UIViewControllerRepresentable {
    let onComplete: ([UIImage]) -> Void
    let onCancel: () -> Void
    let onError: (Error) -> Void

    static var isSupported: Bool {
        VNDocumentCameraViewController.isSupported && UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIViewController(
        _ uiViewController: VNDocumentCameraViewController,
        coordinator: Coordinator
    ) {
        uiViewController.delegate = nil
    }
}

extension DocumentScannerSheet {
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        fileprivate var parent: DocumentScannerSheet
        private var isFinishing = false

        init(parent: DocumentScannerSheet) {
            self.parent = parent
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            finish(controller, completion: parent.onCancel)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            finish(controller) { [parent] in
                parent.onError(error)
            }
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            var pages: [UIImage] = []
            pages.reserveCapacity(scan.pageCount)

            for pageIndex in 0..<scan.pageCount {
                pages.append(scan.imageOfPage(at: pageIndex))
            }

            finish(controller) { [parent] in
                parent.onComplete(pages)
            }
        }

        private func finish(
            _ controller: VNDocumentCameraViewController,
            completion: @escaping () -> Void
        ) {
            guard !isFinishing else { return }
            isFinishing = true

            controller.delegate = nil
            controller.dismiss(animated: true, completion: completion)
        }
    }
}
