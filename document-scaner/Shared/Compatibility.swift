//
//  Compatibility.swift
//  document-scaner
//
//  Created by Codex on 8/3/2026.
//

import SwiftUI

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
    func appViewerControlButtonStyle(isDestructive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
                .tint(isDestructive ? .red : .white)
        } else {
            buttonStyle(AppViewerControlButtonStyle(foregroundColor: isDestructive ? .red : .white))
        }
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
