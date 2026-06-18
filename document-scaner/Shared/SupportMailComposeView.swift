//
//  SupportMailComposeView.swift
//  document-scaner
//

import MessageUI
import SwiftUI

struct SupportMailComposeView: UIViewControllerRepresentable {
    let draft: SupportEmailDraft
    let onFinish: (MFMailComposeResult, Error?) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let viewController = MFMailComposeViewController()
        viewController.mailComposeDelegate = context.coordinator
        viewController.setToRecipients([draft.recipient])
        viewController.setSubject(draft.subject)
        viewController.setMessageBody(draft.body, isHTML: false)
        return viewController
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> SupportMailComposeCoordinator {
        SupportMailComposeCoordinator(onFinish: onFinish)
    }
}

final class SupportMailComposeCoordinator: NSObject, MFMailComposeViewControllerDelegate {
    private let onFinish: (MFMailComposeResult, Error?) -> Void

    init(onFinish: @escaping (MFMailComposeResult, Error?) -> Void) {
        self.onFinish = onFinish
    }

    func mailComposeController(
        _ controller: MFMailComposeViewController,
        didFinishWith result: MFMailComposeResult,
        error: Error?
    ) {
        controller.dismiss(animated: true)
        onFinish(result, error)
    }
}
