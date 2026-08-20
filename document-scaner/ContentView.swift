//
//  ContentView.swift
//  document-scaner
//
//  Created by Youssef Dhibi on 7/3/2026.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var library: DocumentLibrary
    @AppStorage(AppPreferenceKey.lastSeenMajorIntroduction) private var lastSeenMajorIntroduction = 0
    @State private var isOnboardingPresented = false

    var body: some View {
        LibraryView()
            .fullScreenCover(isPresented: $isOnboardingPresented) {
                V2OnboardingView(mode: .automatic) { completion in
                    finishOnboarding(completion)
                }
                .interactiveDismissDisabled()
            }
            .onAppear {
                updateOnboardingPresentation(for: library.loadState)
            }
            .onChange(of: library.loadState) { loadState in
                updateOnboardingPresentation(for: loadState)
            }
    }

    private func updateOnboardingPresentation(for loadState: LibraryLoadState) {
        isOnboardingPresented = V2OnboardingPresentation.shouldPresent(
            lastSeenMajorIntroduction: lastSeenMajorIntroduction,
            loadState: loadState
        )
    }

    private func finishOnboarding(_ completion: V2OnboardingCompletion) {
        switch completion {
        case .completed, .skipped:
            lastSeenMajorIntroduction = V2OnboardingPresentation.majorVersion
        }
        isOnboardingPresented = false
    }
}

enum V2OnboardingPresentation {
    nonisolated static let majorVersion = 2

    nonisolated static func shouldPresent(
        lastSeenMajorIntroduction: Int,
        loadState: LibraryLoadState
    ) -> Bool {
        guard lastSeenMajorIntroduction < majorVersion else { return false }

        return switch loadState {
        case .loaded, .empty:
            true
        case .initialLoading, .migrating, .migrationFailed, .failed:
            false
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(DocumentLibrary.preview)
        .environmentObject(ProStore(productIdentifier: nil, startLifecycle: false))
}
