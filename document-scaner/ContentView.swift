//
//  ContentView.swift
//  document-scaner
//
//  Created by Youssef Dhibi on 7/3/2026.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var library: DocumentLibrary
    @Environment(\.presentProPaywall) private var presentProPaywall
    @AppStorage(AppPreferenceKey.lastSeenMajorIntroduction) private var lastSeenMajorIntroduction = 0
    @State private var isOnboardingPresented = false
    @State private var shouldPresentPaywallAfterOnboarding = false
    @State private var hasRequestedLaunchPaywall = false

    var body: some View {
        LibraryView()
#if DEBUG
            .task {
                guard PerformanceFixture.isEnabled else { return }
                do {
                    try await PerformanceFixture.seedIfNeeded()
                    await library.reload()
                } catch {
                    print("Performance fixture setup failed: \(error)")
                }
            }
#endif
            .fullScreenCover(
                isPresented: $isOnboardingPresented,
                onDismiss: onboardingDidDismiss
            ) {
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
#if DEBUG
        if PerformanceFixture.isEnabled { return }
#endif
        let destination = AppLaunchPresentation.destination(
            lastSeenMajorIntroduction: lastSeenMajorIntroduction,
            loadState: loadState
        )

        switch destination {
        case .onboarding:
            isOnboardingPresented = true
        case .paywall:
            isOnboardingPresented = false
            requestLaunchPaywallOnce()
        case .none:
            isOnboardingPresented = false
        }
    }

    private func finishOnboarding(_ completion: V2OnboardingCompletion) {
        switch completion {
        case .completed, .skipped:
            lastSeenMajorIntroduction = V2OnboardingPresentation.majorVersion
        }
        shouldPresentPaywallAfterOnboarding = true
        isOnboardingPresented = false
    }

    private func onboardingDidDismiss() {
        guard shouldPresentPaywallAfterOnboarding else { return }
        shouldPresentPaywallAfterOnboarding = false
        requestLaunchPaywallOnce()
    }

    private func requestLaunchPaywallOnce() {
        guard !hasRequestedLaunchPaywall else { return }
        hasRequestedLaunchPaywall = true
        presentProPaywall()
    }
}

enum AppLaunchPresentation: Equatable {
    case none
    case onboarding
    case paywall

    nonisolated static func destination(
        lastSeenMajorIntroduction: Int,
        loadState: LibraryLoadState
    ) -> AppLaunchPresentation {
        switch loadState {
        case .loaded, .empty:
            V2OnboardingPresentation.shouldPresent(
                lastSeenMajorIntroduction: lastSeenMajorIntroduction,
                loadState: loadState
            ) ? .onboarding : .paywall
        case .initialLoading, .migrating, .migrationFailed, .failed:
            .none
        }
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
