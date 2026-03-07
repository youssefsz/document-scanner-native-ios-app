//
//  DocumentScannerSheet.swift
//  document-scaner
//
//  Created by Codex on 7/3/2026.
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

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}
}

extension DocumentScannerSheet {
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let parent: DocumentScannerSheet

        init(parent: DocumentScannerSheet) {
            self.parent = parent
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.onError(error)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            var pages: [UIImage] = []
            pages.reserveCapacity(scan.pageCount)

            for pageIndex in 0..<scan.pageCount {
                pages.append(scan.imageOfPage(at: pageIndex))
            }

            parent.onComplete(pages)
        }
    }
}
