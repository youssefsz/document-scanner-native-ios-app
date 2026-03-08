//
//  document_scanerApp.swift
//  document-scaner
//
//  Created by Youssef Dhibi on 7/3/2026.
//

import SwiftUI

@main
struct document_scanerApp: App {
    @StateObject private var library = DocumentLibrary()
    @AppStorage(AppPreferenceKey.useDarkMode) private var useDarkMode = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .onAppear {
                    AppThemeController.apply(useDarkMode: useDarkMode, animated: false)
                }
                .onChange(of: useDarkMode) { newValue in
                    AppThemeController.apply(useDarkMode: newValue, animated: true)
                }
        }
    }
}
