import SwiftUI
import UIKit

struct BeforeAfterComparisonView: View {
    let beforeImageName: String
    let afterImageName: String

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var afterFraction = 0.6
    @State private var lastMidpointSide = true
    @State private var didReveal = false

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let dividerX = width * afterFraction

            ZStack(alignment: .leading) {
                comparisonImage(named: beforeImageName)

                comparisonImage(named: afterImageName)
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: dividerX)
                    }

                divider
                    .position(x: dividerX, y: proxy.size.height / 2)

                labels
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(width: width))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.45), lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Original and Version 2 design comparison")
        .accessibilityValue("\(Int((afterFraction * 100).rounded())) percent Version 2")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                setFraction(afterFraction + 0.1, hapticsEnabled: false)
            case .decrement:
                setFraction(afterFraction - 0.1, hapticsEnabled: false)
            @unknown default:
                break
            }
        }
        .accessibilityAction(named: "Show Original") {
            setFraction(0, hapticsEnabled: false)
        }
        .accessibilityAction(named: "Show Version 2") {
            setFraction(1, hapticsEnabled: false)
        }
        .onAppear {
            lastMidpointSide = afterFraction >= 0.5
            guard !accessibilityReduceMotion, !didReveal else {
                didReveal = true
                return
            }
            didReveal = true
            afterFraction = 0.5
            withAnimation(.easeOut(duration: 0.38)) {
                afterFraction = 0.6
            }
        }
    }

    private func comparisonImage(named name: String) -> some View {
        GeometryReader { proxy in
            OnboardingScreenshot(imageName: name, fallback: .library)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .accessibilityHidden(true)
        }
    }

    private var divider: some View {
        ZStack {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 2)

            Circle()
                .fill(.regularMaterial)
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "chevron.left.chevron.right")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                }
                .overlay {
                    Circle().strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5)
                }
        }
        .accessibilityHidden(true)
    }

    private var labels: some View {
        HStack {
            Text("Version 2")
                .onboardingComparisonLabel()
            Spacer()
            Text("Original")
                .onboardingComparisonLabel()
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                setFraction(value.location.x / width, hapticsEnabled: true)
            }
    }

    private func setFraction(_ value: Double, hapticsEnabled: Bool) {
        let clamped = min(max(value, 0), 1)
        let newMidpointSide = clamped >= 0.5
        if hapticsEnabled, newMidpointSide != lastMidpointSide {
            UISelectionFeedbackGenerator().selectionChanged()
        }
        lastMidpointSide = newMidpointSide
        afterFraction = clamped
    }
}

private extension View {
    func onboardingComparisonLabel() -> some View {
        font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
    }
}
