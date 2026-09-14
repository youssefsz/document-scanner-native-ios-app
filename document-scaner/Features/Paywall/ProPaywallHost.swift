import SwiftUI
import UIKit

private struct ProFeatureRequestActionKey: EnvironmentKey {
    static let defaultValue: @MainActor (ProFeature, @escaping @MainActor () -> Void) -> Void = { _, _ in }
}

private struct ProPaywallPresentationActionKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}

extension EnvironmentValues {
    var requestProFeature: @MainActor (ProFeature, @escaping @MainActor () -> Void) -> Void {
        get { self[ProFeatureRequestActionKey.self] }
        set { self[ProFeatureRequestActionKey.self] = newValue }
    }

    var presentProPaywall: @MainActor () -> Void {
        get { self[ProPaywallPresentationActionKey.self] }
        set { self[ProPaywallPresentationActionKey.self] = newValue }
    }
}

extension View {
    /// Owns Pro presentation for this view hierarchy. Passing the store explicitly
    /// keeps sheet-to-sheet presentation independent of EnvironmentObject propagation.
    func proPaywallHost(store: ProStore) -> some View {
        modifier(ProPaywallHostModifier(store: store))
    }
}

private struct PendingProFeatureRequest: Identifiable {
    let id = UUID()
    let feature: ProFeature
    let onGranted: @MainActor () -> Void
}

private struct ProPaywallHostModifier: ViewModifier {
    @ObservedObject private var store: ProStore
    @State private var pendingRequest: PendingProFeatureRequest?
    @State private var isPaywallPresented = false
    @State private var isLaunchRequestPending = false
    @State private var shouldContinueAfterDismissal = false

    init(store: ProStore) {
        self.store = store
    }

    func body(content: Content) -> some View {
        content
            .environment(\.requestProFeature, request)
            .environment(\.presentProPaywall, presentLaunchPaywall)
            .sheet(isPresented: $isPaywallPresented, onDismiss: paywallDidDismiss) {
                ProPaywallPresenter(store: store) {
                    shouldContinueAfterDismissal = true
                    isPaywallPresented = false
                } onCancel: {
                    shouldContinueAfterDismissal = false
                    isPaywallPresented = false
                }
            }
    }

    private func request(_ feature: ProFeature, onGranted: @escaping @MainActor () -> Void) {
        guard pendingRequest == nil,
              !isLaunchRequestPending,
              !isPaywallPresented else { return }
        if store.hasAccess(to: feature) {
            onGranted()
            return
        }

        let request = PendingProFeatureRequest(feature: feature, onGranted: onGranted)
        pendingRequest = request
        Task { @MainActor in
            if store.entitlementState == .unknown {
                _ = await store.refreshEntitlement()
            }
            guard pendingRequest?.id == request.id else { return }
            if store.hasAccess(to: feature) {
                shouldContinueAfterDismissal = true
                paywallDidDismiss()
            } else {
                isPaywallPresented = true
            }
        }
    }

    private func presentLaunchPaywall() {
        guard pendingRequest == nil,
              !isLaunchRequestPending,
              !isPaywallPresented,
              !store.hasProAccess else { return }

        isLaunchRequestPending = true
        Task { @MainActor in
            if store.entitlementState == .unknown {
                _ = await store.refreshEntitlement()
            }
            guard isLaunchRequestPending else { return }
            isLaunchRequestPending = false
            guard !store.hasProAccess else { return }
            isPaywallPresented = true
        }
    }

    private func paywallDidDismiss() {
        let request = pendingRequest
        pendingRequest = nil
        isLaunchRequestPending = false
        let shouldContinue = shouldContinueAfterDismissal
        shouldContinueAfterDismissal = false
        store.resetPresentationState()
        if let request,
           shouldContinue,
           store.hasAccess(to: request.feature) {
            request.onGranted()
        }
    }
}

private struct ProPaywallPresenter: View {
    @ObservedObject private var store: ProStore
    let onGranted: () -> Void
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isCompleting = false
    @State private var successKind: ProPaywallSuccessKind?

    init(store: ProStore, onGranted: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.store = store
        self.onGranted = onGranted
        self.onCancel = onCancel
    }

    var body: some View {
        ProPaywallView(
            configuration: configuration,
            onPurchase: purchase,
            onRestore: restore,
            onDismiss: onCancel
        )
        .interactiveDismissDisabled(configuration.disablesDismissal)
        .onChange(of: store.operation) { operation in
            if operation == .purchaseSucceeded, successKind == nil {
                complete(.purchase)
            }
        }
        .task {
            if store.product == nil, store.operation != .loadingProduct {
                await store.loadProduct()
            }
        }
    }

    private var configuration: ProPaywallConfiguration {
        ProPaywallConfiguration(
            displayPrice: store.displayPrice,
            isLoadingProduct: store.operation == .loadingProduct,
            isPurchasing: store.operation == .purchasing,
            isRestoring: store.operation == .restoring,
            isPending: store.operation == .pending,
            errorMessage: store.error?.localizedDescription,
            success: successKind
        )
    }

    private func purchase() {
        guard !configuration.disablesActions else { return }
        if store.product == nil {
            Task { await store.loadProduct() }
            return
        }
        Task {
            let outcome = await store.purchase()
            if outcome == .purchased { complete(.purchase) }
        }
    }

    private func restore() {
        guard !configuration.disablesActions else { return }
        Task {
            let outcome = await store.restore()
            if outcome == .restored { complete(.restore) }
        }
    }

    private func complete(_ kind: ProPaywallSuccessKind) {
        guard !isCompleting else { return }
        isCompleting = true
        successKind = kind
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 350 : 800))
            onGranted()
        }
    }
}
