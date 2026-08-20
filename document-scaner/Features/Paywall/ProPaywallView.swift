//
//  ProPaywallView.swift
//  document-scaner
//

import SwiftUI
import UIKit

struct ProPaywallConfiguration: Equatable {
    let displayPrice: String?
    let isLoadingProduct: Bool
    let isPurchasing: Bool
    let isRestoring: Bool
    let isPending: Bool
    let errorMessage: String?
    let success: ProPaywallSuccessKind?

    var disablesActions: Bool {
        isLoadingProduct || isPurchasing || isRestoring || success != nil
    }

    var disablesDismissal: Bool {
        isPurchasing || isRestoring || success != nil
    }

    static let preview = ProPaywallConfiguration(
        displayPrice: "$14.99",
        isLoadingProduct: false,
        isPurchasing: false,
        isRestoring: false,
        isPending: false,
        errorMessage: nil,
        success: nil
    )
}

enum ProPaywallSuccessKind: Equatable {
    case purchase
    case restore
}

struct ProPaywallView: View {
    let configuration: ProPaywallConfiguration
    let onPurchase: () -> Void
    let onRestore: () -> Void
    let onDismiss: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isPrivacyPolicyPresented = false

    private let maximumContentWidth: CGFloat = 560

    var body: some View {
        NavigationStack {
            ScrollView {
                if let success = configuration.success {
                    successConfirmation(success)
                        .frame(minHeight: 480)
                        .frame(maxWidth: maximumContentWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)
                } else {
                    VStack(spacing: 0) {
                    Image("ProPaywallHero")
                        .resizable()
                        .scaledToFit()
                        .frame(width: heroSize, height: heroSize)
                        .padding(.top, 8)
                        .accessibilityHidden(true)

                    VStack(spacing: 8) {
                        Text("Protect private documents")
                            .font(.largeTitle.bold())
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)

                        Text("Secure folders, password-protected PDFs, and every future Pro feature.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 12)

                    benefits
                        .padding(.top, 26)

                    lifetimePromise
                        .padding(.top, 26)
                }
                    .frame(maxWidth: maximumContentWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
            .background(Color(.systemBackground).ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if configuration.success == nil { purchaseFooter }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                    .disabled(configuration.disablesDismissal)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    if configuration.success == nil { restoreButton }
                }
            }
        }
        .sheet(isPresented: $isPrivacyPolicyPresented) {
            NavigationStack {
                PrivacyPolicyView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                isPrivacyPolicyPresented = false
                            }
                        }
                    }
            }
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 18) {
            BenefitRow(
                imageName: "ProSecureFolderIcon",
                title: "Secure folders",
                detail: "Encrypt folders and unlock them with device authentication."
            )

            BenefitRow(
                imageName: "ProProtectedPDFIcon",
                title: "Password-protected PDFs",
                detail: "Add a password to the PDF copy you share."
            )
        }
        .frame(maxWidth: 480)
        .accessibilityElement(children: .contain)
    }

    private var lifetimePromise: some View {
        HStack(spacing: 10) {
            Image(systemName: "infinity")
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            Text("Pay once. Keep Pro forever.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var purchaseFooter: some View {
        VStack(spacing: 8) {
            if let message = statusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(configuration.errorMessage == nil ? Color.secondary : Color.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                guard !configuration.disablesActions else { return }
                onPurchase()
            } label: {
                HStack(spacing: 10) {
                    if configuration.isPurchasing || configuration.isLoadingProduct {
                        AppProminentProgressView(accessibilityLabel: configuration.isPurchasing ? "Purchasing" : "Loading")
                    }

                    Text(purchaseButtonTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .allowsTightening(true)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 52)
                .padding(.horizontal, 16)
            }
            .paywallProminentButtonStyle()
            .controlSize(.large)
            .disabled(configuration.isRestoring)
            .allowsHitTesting(!configuration.disablesActions)
            .accessibilityLabel(purchaseAccessibilityLabel)

            Text("One-time purchase. No subscription.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 22) {
                termsLink
                privacyButton
            }
            .font(.footnote)
        }
        .tint(.accentColor)
        .frame(maxWidth: maximumContentWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var restoreButton: some View {
        Button(action: onRestore) {
            HStack(spacing: 6) {
                if configuration.isRestoring {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(configuration.isRestoring ? "Restoring…" : "Restore Purchases")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
        }
        .disabled(configuration.disablesActions)
    }

    private var termsLink: some View {
        Link("Terms of Use", destination: AppMetadata.standardEULAURL)
            .lineLimit(1)
            .frame(minHeight: 44)
    }

    private var privacyButton: some View {
        Button("Privacy Policy") {
            isPrivacyPolicyPresented = true
        }
        .lineLimit(1)
        .frame(minHeight: 44)
    }

    private var purchaseButtonTitle: String {
        if configuration.isLoadingProduct { return "Loading..." }
        if configuration.isPurchasing { return "Purchasing..." }
        guard let displayPrice = configuration.displayPrice else { return "Retry" }
        return "Unlock Pro for \(displayPrice)"
    }

    private var purchaseAccessibilityLabel: String {
        if configuration.isLoadingProduct { return "Loading Pro purchase" }
        if configuration.isPurchasing { return "Purchasing" }
        guard let displayPrice = configuration.displayPrice else { return "Retry loading Pro purchase" }
        return "Unlock Pro for \(displayPrice). One-time purchase. No subscription."
    }

    private var statusMessage: String? {
        if configuration.isPending {
            return "Purchase pending approval. Pro will unlock when Apple confirms it."
        }
        return configuration.errorMessage
    }

    private func successConfirmation(_ kind: ProPaywallSuccessKind) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image("ProPurchaseSuccessIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text(kind == .purchase ? "Pro unlocked" : "Pro restored")
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)
            Text(kind == .purchase ? "Lifetime access is ready." : "Your lifetime access is ready.")
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .multilineTextAlignment(.center)
    }

    private var heroSize: CGFloat {
        horizontalSizeClass == .regular ? 160 : 144
    }
}

private struct BenefitRow: View {
    let imageName: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(imageName)
                .resizable()
                .scaledToFit()
                .frame(width: 42, height: 42)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    @ViewBuilder
    func paywallProminentButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}

private struct ProPaywallPreview: View {
    var body: some View {
        ProPaywallView(
            configuration: .preview,
            onPurchase: {},
            onRestore: {},
            onDismiss: {}
        )
    }
}

struct ProPaywallView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ProPaywallPreview()
                .preferredColorScheme(.light)
                .previewDisplayName("iPhone SE · Light")
                .previewLayout(.fixed(width: 375, height: 667))

            ProPaywallPreview()
                .preferredColorScheme(.dark)
                .previewDisplayName("iPhone 17 · Dark")
                .previewLayout(.fixed(width: 402, height: 874))

            ProPaywallPreview()
                .preferredColorScheme(.light)
                .environment(\.horizontalSizeClass, .regular)
                .previewDisplayName("iPad · Constrained width")
                .previewLayout(.fixed(width: 820, height: 1180))

            ProPaywallPreview()
                .environment(\.dynamicTypeSize, .accessibility3)
                .previewDisplayName("Accessibility text")
                .previewLayout(.fixed(width: 402, height: 874))

            ProPaywallPreview()
                .environment(\._accessibilityReduceMotion, true)
                .previewDisplayName("Reduced motion")
                .previewLayout(.fixed(width: 402, height: 874))
        }
    }
}
