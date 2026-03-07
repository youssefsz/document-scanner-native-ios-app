//
//  AppThemeController.swift
//  document-scaner
//
//  Created by Codex on 7/3/2026.
//

import SwiftUI
import UIKit

@MainActor
enum AppThemeController {
    static func apply(useDarkMode: Bool, animated: Bool) {
        let interfaceStyle: UIUserInterfaceStyle = useDarkMode ? .dark : .light

        for window in connectedWindows {
            let applyStyle = {
                window.overrideUserInterfaceStyle = interfaceStyle
            }

            guard animated else {
                applyStyle()
                continue
            }

            UIView.transition(
                with: window,
                duration: 0.35,
                options: [.transitionCrossDissolve, .allowAnimatedContent]
            ) {
                applyStyle()
            }
        }
    }

    private static var connectedWindows: [UIWindow] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
    }
}
