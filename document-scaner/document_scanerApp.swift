//
//  document_scanerApp.swift
//  document-scaner
//
//  Created by Youssef Dhibi on 7/3/2026.
//

import SwiftUI
import UIKit

@main
struct document_scanerApp: App {
    @StateObject private var proStore: ProStore
    @StateObject private var library: DocumentLibrary
    @AppStorage(AppPreferenceKey.useDarkMode) private var useDarkMode = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let proStore = ProStore()
        _proStore = StateObject(wrappedValue: proStore)
        _library = StateObject(wrappedValue: DocumentLibrary(proAccess: proStore))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .environmentObject(proStore)
                .proPaywallHost()
                .preferredColorScheme(useDarkMode ? .dark : .light)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    Task {
                        await ThumbnailPipeline.shared.clearCache()
                        await SecureThumbnailPipeline.shared.clearAll()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
                    library.lockAllSecureFolders()
                    Task {
                        await ThumbnailPipeline.shared.clearCache()
                        await SecureThumbnailPipeline.shared.clearAll()
                    }
                }
                .onChange(of: scenePhase) { phase in
                    let shouldLock = phase == .background
                        || (phase == .inactive && !library.isAuthenticatingSecureContent)
                    guard shouldLock else { return }
                    library.lockAllSecureFolders()
                    Task {
                        await ThumbnailPipeline.shared.clearCache()
                        await SecureThumbnailPipeline.shared.clearAll()
                    }
                }
        }
    }
}
