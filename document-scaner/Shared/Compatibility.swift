//
//  Compatibility.swift
//  document-scaner
//
//

import SwiftUI

struct AppProminentProgressView: View {
    let accessibilityLabel: String

    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .tint(.white)
            .foregroundStyle(.white)
            .accessibilityLabel(accessibilityLabel)
    }
}

struct AppToolbarProgressView: View {
    let accessibilityLabel: String

    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.small)
            .tint(.accentColor)
            .accessibilityLabel(accessibilityLabel)
    }
}

struct AppUnavailableStateView: View {
    let title: String
    let systemImage: String
    let description: String
    var titleColor: Color = .primary
    var detailColor: Color = .secondary

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(detailColor)

            VStack(spacing: 8) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(titleColor)
                    .multilineTextAlignment(.center)

                Text(description)
                    .font(.body)
                    .foregroundStyle(detailColor)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

extension View {
    func appGroupedScreenBackground() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    @ViewBuilder
    func appProminentButtonStyle(color: Color = .accentColor) -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
                .tint(color)
        } else {
            buttonStyle(AppProminentButtonStyle(color: color))
        }
    }

    @ViewBuilder
    func appSecondaryCircularButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(AppSecondaryCircularButtonStyle())
        }
    }

    @ViewBuilder
    func appViewerControlButtonStyle(isDestructive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
                .tint(isDestructive ? .red : .white)
        } else {
            buttonStyle(AppViewerControlButtonStyle(foregroundColor: isDestructive ? .red : .white))
        }
    }

    @ViewBuilder
    func appToolbarTitleSurface() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
    }

    @ViewBuilder
    func appTopScrollEdgeEffect(isScrolled: Bool) -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            overlay(alignment: .top) {
                LegacyTopScrollEdgeEffect()
                    .opacity(isScrolled ? 1 : 0)
                    .animation(.easeOut(duration: 0.18), value: isScrolled)
            }
        }
    }
}

private struct LegacyTopScrollEdgeEffect: View {
    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .frame(height: 28)
            .mask {
                LinearGradient(
                    colors: [.black, .black.opacity(0.45), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct AppProminentButtonStyle: ButtonStyle {
    let color: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(color.gradient.opacity(isEnabled ? 1 : 0.55))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(isEnabled ? 0.18 : 0.08), lineWidth: 1)
            }
            .shadow(color: color.opacity(isEnabled ? 0.25 : 0.12), radius: 18, y: 10)
            .opacity(configuration.isPressed ? 0.94 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct AppSecondaryCircularButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.primary.opacity(isEnabled ? 1 : 0.45))
            .background(Circle().fill(.regularMaterial))
            .overlay {
                Circle()
                    .strokeBorder(.white.opacity(isEnabled ? 0.2 : 0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(isEnabled ? 0.14 : 0.06), radius: 14, y: 8)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct AppViewerControlButtonStyle: ButtonStyle {
    let foregroundColor: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foregroundColor.opacity(isEnabled ? 1 : 0.45))
            .background(
                Circle()
                    .fill(.regularMaterial)
            )
            .overlay {
                Circle()
                    .strokeBorder(.white.opacity(isEnabled ? 0.14 : 0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(isEnabled ? 0.18 : 0.08), radius: 14, y: 8)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
