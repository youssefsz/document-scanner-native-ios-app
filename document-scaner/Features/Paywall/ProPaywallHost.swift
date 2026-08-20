import SwiftUI
import UIKit

private struct ProFeatureRequestActionKey: EnvironmentKey {
    static let defaultValue: @MainActor (ProFeature, @escaping @MainActor () -> Void) -> Void = { _, _ in }
}

extension EnvironmentValues {
    var requestProFeature: @MainActor (ProFeature, @escaping @MainActor () -> Void) -> Void {
        get { self[ProFeatureRequestActionKey.self] }
        set { self[ProFeatureRequestActionKey.self] = newValue }
    }
}

extension View {
    func proPaywallHost() -> some View {
        modifier(ProPaywallHostModifier())
    }
}

private struct PendingProFeatureRequest: Identifiable {
    let id = UUID()
    let feature: ProFeature
    let onGranted: @MainActor () -> Void
}

private struct ProPaywallHostModifier: ViewModifier {
    @EnvironmentObject private var store: ProStore
    @State private var pendingRequest: PendingProFeatureRequest?
    @State private var isPaywallPresented = false
    @State private var shouldContinueAfterDismissal = false

    func body(content: Content) -> some View {
        content
            .environment(\.requestProFeature, request)
            .sheet(isPresented: $isPaywallPresented, onDismiss: paywallDidDismiss) {
                ProPaywallPresenter {
                    shouldContinueAfterDismissal = true
                    isPaywallPresented = false
                } onCancel: {
                    shouldContinueAfterDismissal = false
                    isPaywallPresented = false
                }
            }
    }

    private func request(_ feature: ProFeature, onGranted: @escaping @MainActor () -> Void) {
        guard pendingRequest == nil else { return }
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

    private func paywallDidDismiss() {
        guard let request = pendingRequest else { return }
        pendingRequest = nil
        let shouldContinue = shouldContinueAfterDismissal
        shouldContinueAfterDismissal = false
        store.resetPresentationState()
        if shouldContinue, store.hasAccess(to: request.feature) {
            request.onGranted()
        }
    }
}

private struct ProPaywallPresenter: View {
    let onGranted: () -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var store: ProStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isCompleting = false
    @State private var successKind: ProPaywallSuccessKind?

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

