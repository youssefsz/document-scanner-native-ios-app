import SwiftUI

enum VaultTransferReminder {
    static var isEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "VaultTransferReminderEnabled") as? Bool == true
    }

    static let snoozeDuration: TimeInterval = 24 * 60 * 60
}

struct VaultTransferReminderSheet: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ScaledMetric(relativeTo: .body) private var phoneHeight = 406.0
    @ScaledMetric(relativeTo: .body) private var tabletHeight = 370.0

    let unlockNow: () -> Void
    let remindLater: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if !dynamicTypeSize.isAccessibilitySize {
                    VaultFolderIllustration(size: 100)
                }

                VStack(spacing: 8) {
                    Text("Keep access to your secure folders")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)

                    Text("Unlock a secure folder once on this device to prepare your documents for future updates.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

                if !dynamicTypeSize.isAccessibilitySize {
                    actions
                }
            }
            .frame(maxWidth: 400)
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("vault-transfer-reminder")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if dynamicTypeSize.isAccessibilitySize {
                actions
                    .frame(maxWidth: 400)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
            }
        }
        .presentationDetents(detents)
        .presentationDragIndicator(.visible)
    }

    private var actions: some View {
        VStack(spacing: 6) {
            Button(action: unlockNow) {
                Text("Unlock Now")
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button(action: remindLater) {
                Text("Remind Me Later")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderless)
        }
        .multilineTextAlignment(.center)
    }

    private var detents: Set<PresentationDetent> {
        if dynamicTypeSize.isAccessibilitySize || verticalSizeClass == .compact { return [.large] }
        return [.height(horizontalSizeClass == .regular ? tabletHeight : phoneHeight), .large]
    }
}

struct VaultTransferReminderRow: View {
    let unlock: () -> Void

    var body: some View {
        Button(action: unlock) {
            HStack(spacing: 12) {
                VaultFolderIllustration(size: 46)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Keep access to your secure folders")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Unlock once to prepare for future updates.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Unlock a secure folder")
        .accessibilityIdentifier("vault-transfer-reminder-row")
    }
}

struct VaultFolderIllustration: View {
    let size: CGFloat

    var body: some View {
        Image("ProSecureFolderIcon")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
