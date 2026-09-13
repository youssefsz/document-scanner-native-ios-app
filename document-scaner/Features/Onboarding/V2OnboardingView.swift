import SwiftUI
import UIKit

enum V2OnboardingStep: Int, CaseIterable {
    case welcome
    case comparison
    case folders
    case photoImport
    case pro
}

enum V2OnboardingMode {
    case automatic
    case replay
}

enum V2OnboardingCompletion {
    case completed
    case skipped
}

struct V2OnboardingView: View {
    let mode: V2OnboardingMode
    let onFinish: (V2OnboardingCompletion) -> Void

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var step: V2OnboardingStep = .welcome

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            GeometryReader { proxy in
                page(isCompact: proxy.size.height < 680)
                    .id(step)
                    .frame(maxWidth: 620, maxHeight: .infinity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .transition(stepTransition)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actions
        }
        .animation(stepAnimation, value: step)
    }

    @ViewBuilder
    private func page(isCompact: Bool) -> some View {
        switch step {
        case .welcome:
            WelcomeOnboardingPage(isCompact: isCompact)
        case .comparison:
            ComparisonOnboardingPage(isCompact: isCompact)
        case .folders:
            FoldersOnboardingPage(isCompact: isCompact)
        case .photoImport:
            PhotoImportOnboardingPage(isCompact: isCompact)
        case .pro:
            ProOnboardingPage(isCompact: isCompact)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if step != .welcome {
                Button {
                    triggerNavigationHaptic()
                    move(to: V2OnboardingStep(rawValue: step.rawValue - 1) ?? .welcome)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline.weight(.semibold))
                        .frame(width: 50, height: 50)
                }
                .modifier(OnboardingSecondaryButtonStyle())
                .accessibilityLabel("Back")
            }

            Button {
                triggerNavigationHaptic()
                advance()
            } label: {
                Text(primaryActionTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .modifier(OnboardingPrimaryButtonStyle())
            .buttonBorderShape(.capsule)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 26)
        .padding(.bottom, 8)
        .background {
            OnboardingActionBarBackground()
        }
    }

    private var primaryActionTitle: String {
        guard step == .pro else { return "Continue" }
        return mode == .automatic ? "Start Using DocScanner" : "Done"
    }

    private var stepTransition: AnyTransition {
        .opacity
    }

    private var stepAnimation: Animation? {
        accessibilityReduceMotion ? nil : .easeInOut(duration: 0.24)
    }

    private func advance() {
        if let next = V2OnboardingStep(rawValue: step.rawValue + 1) {
            move(to: next)
        } else {
            onFinish(.completed)
        }
    }

    private func move(to newStep: V2OnboardingStep) {
        withAnimation(stepAnimation) {
            step = newStep
        }
    }

    private func triggerNavigationHaptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

private struct OnboardingSecondaryButtonStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
        } else {
            content
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
    }
}

private struct OnboardingPrimaryButtonStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

private struct WelcomeOnboardingPage: View {
    let isCompact: Bool

    var body: some View {
        VStack(spacing: isCompact ? 16 : 22) {
            Spacer()

            Image("OnboardingWelcomeHero")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: isCompact ? 240 : 300)
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                WelcomeBrandTitle(isCompact: isCompact)

                Text("A redesigned experience for scanning, organizing, and finding your documents.")
                    .font(isCompact ? .subheadline : .body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 380)
            }

            Spacer(minLength: 0)
        }
    }
}

private struct WelcomeBrandTitle: View {
    let isCompact: Bool

    private var titleFont: Font {
        (isCompact ? Font.title : .largeTitle).weight(.bold)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("Meet ")
                .foregroundStyle(.primary)

            ShimmeringBrandText("DocScanner 2", font: titleFont)
        }
        .font(titleFont)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Meet DocScanner 2")
    }
}

private struct ShimmeringBrandText: View {
    let title: String
    let font: Font

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    private let cycleDuration: TimeInterval = 2.4

    init(_ title: String, font: Font) {
        self.title = title
        self.font = font
    }

    var body: some View {
        if accessibilityReduceMotion {
            gradientText(phase: 0.5)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let elapsed = context.date.timeIntervalSinceReferenceDate
                let phase = elapsed.truncatingRemainder(dividingBy: cycleDuration) / cycleDuration

                gradientText(phase: 1 - phase)
                    .overlay {
                        OnboardingTitleSparkles(elapsed: elapsed)
                    }
            }
        }
    }

    private var brandText: some View {
        Text(title)
            .font(font)
    }

    private func gradientText(phase: Double) -> some View {
        brandText
            .foregroundStyle(.clear)
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(
                        stops: repeatingGradientStops,
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 2)
                    .offset(x: -proxy.size.width * CGFloat(phase))
                }
            }
            .mask {
                brandText
                    .foregroundStyle(.white)
            }
            .clipped()
    }

    private var repeatingGradientStops: [Gradient.Stop] {
        let firstPattern: [(color: Color, location: CGFloat)] = [
            (Color(red: 0.00, green: 0.52, blue: 1.00), 0.00),
            (Color(red: 0.00, green: 0.68, blue: 0.92), 0.16),
            (Color(red: 0.38, green: 0.68, blue: 0.96), 0.20),
            (Color(red: 0.16, green: 0.60, blue: 0.96), 0.24),
            (Color(red: 0.15, green: 0.36, blue: 0.90), 0.38),
            (Color(red: 0.00, green: 0.52, blue: 1.00), 0.50)
        ]

        let firstHalf = firstPattern.map { stop in
            Gradient.Stop(color: stop.color, location: stop.location)
        }
        let secondHalf = firstPattern.dropFirst().map { stop in
            Gradient.Stop(color: stop.color, location: stop.location + 0.5)
        }

        return firstHalf + secondHalf
    }
}

private struct OnboardingTitleSparkles: View {
    let elapsed: TimeInterval

    var body: some View {
        GeometryReader { proxy in
            let textHeight = max(proxy.size.height, 1)

            ZStack {
                NativeTitleSparkle(elapsed: elapsed, advance: 0.20)
                    .frame(width: textHeight * 0.24, height: textHeight * 0.24)
                    .position(x: proxy.size.width * 0.10, y: textHeight * 0.02)

                NativeTitleSparkle(elapsed: elapsed, advance: 1.35)
                    .frame(width: textHeight * 0.16, height: textHeight * 0.16)
                    .position(x: proxy.size.width, y: textHeight * 0.96)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct NativeTitleSparkle: View {
    let elapsed: TimeInterval
    let advance: TimeInterval

    private let duration: TimeInterval = 2.8

    var body: some View {
        Image(systemName: "sparkle")
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(Color(red: 0.18, green: 0.62, blue: 0.96))
            .shadow(
                color: Color(red: 0.00, green: 0.52, blue: 1.00).opacity(0.24),
                radius: 2
            )
            .opacity(0.18 + (pulse * 0.50))
            .scaleEffect(0.86 + (pulse * 0.14))
    }

    private var pulse: Double {
        let phase = (elapsed + advance).truncatingRemainder(dividingBy: duration) / duration
        return (sin((phase * 2 * .pi) - (.pi / 2)) + 1) / 2
    }
}

private struct ComparisonOnboardingPage: View {
    let isCompact: Bool

    var body: some View {
        VStack(spacing: isCompact ? 8 : 14) {
            OnboardingTitle(
                title: "A whole new DocScanner",
                subtitle: isCompact ? nil : "Drag to compare the original design with Version 2."
            )

            GeometryReader { proxy in
                BeforeAfterComparisonView(
                    beforeImageName: "OnboardingV1Library",
                    afterImageName: "OnboardingV2Library"
                )
                .aspectRatio(852.0 / 1847.0, contentMode: .fit)
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }
}

private struct FoldersOnboardingPage: View {
    let isCompact: Bool

    var body: some View {
        VStack(spacing: isCompact ? 8 : 14) {
            OnboardingTitle(
                title: "Organize with folders",
                subtitle: isCompact ? nil : "Move scans into folders, or scan directly where each document belongs."
            )

            GeometryReader { proxy in
                OnboardingScreenshot(
                    imageName: "OnboardingFolders",
                    fallback: .folders
                )
                .aspectRatio(852.0 / 1847.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color(.separator).opacity(0.45), lineWidth: 0.5)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .accessibilityHidden(true)
            }
        }
    }
}

private struct PhotoImportOnboardingPage: View {
    let isCompact: Bool

    var body: some View {
        VStack(spacing: isCompact ? 12 : 18) {
            Spacer(minLength: 0)

            OnboardingTitle(
                title: "Import, find, and organize",
                subtitle: "Bring in photos, search document titles, and keep everything organized in folders."
            )

            OnboardingScreenshot(
                imageName: "OnboardingPhotoImport",
                fallback: .photoImport
            )
            .aspectRatio(1000.0 / 481.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.45), lineWidth: 0.5)
            }
            .accessibilityHidden(true)

            VStack(spacing: 0) {
                OnboardingFeatureSummary(
                    imageName: "OnboardingPhotoImportIcon",
                    title: "Import from Photos",
                    description: "Turn one or more images into a searchable PDF."
                )

                Divider()
                    .padding(.leading, 68)

                OnboardingFeatureSummary(
                    imageName: "OnboardingDocumentSearchIcon",
                    title: "Find documents quickly",
                    description: "Search your saved documents by title."
                )

                Divider()
                    .padding(.leading, 68)

                OnboardingFeatureSummary(
                    imageName: "OnboardingFolderOrganizationIcon",
                    title: "Keep everything organized",
                    description: "Group related documents in folders."
                )
            }
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )

            Spacer(minLength: 0)
        }
    }
}

private struct OnboardingFeatureSummary: View {
    let imageName: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(imageName)
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

enum OnboardingScreenshotFallback {
    case library
    case folders
    case photoImport
}

struct OnboardingScreenshot: View {
    let imageName: String
    let fallback: OnboardingScreenshotFallback

    var body: some View {
        Group {
            if let image = UIImage(named: imageName) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityHidden(true)
            } else {
                switch fallback {
                case .library:
                    OnboardingLibraryFallback()
                case .folders:
                    OnboardingFoldersFallback()
                case .photoImport:
                    OnboardingPhotoImportFallback()
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct OnboardingLibraryFallback: View {
    var body: some View {
        VStack(spacing: 14) {
            Picker("Library Section", selection: .constant(0)) {
                Text("Library").tag(0)
                Text("Folders").tag(1)
            }
            .pickerStyle(.segmented)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                OnboardingDocumentMock(title: "Electricity Bill", color: .orange)
                OnboardingDocumentMock(title: "Lease Agreement", color: .blue)
                OnboardingDocumentMock(title: "Project Notes", color: .green)
                OnboardingDocumentMock(title: "School Forms", color: .purple)
            }

            Label("Search document titles", systemImage: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.regularMaterial, in: Capsule())
        }
        .padding(16)
        .background(Color(.systemGroupedBackground))
        .accessibilityHidden(true)
    }
}

private struct OnboardingFoldersFallback: View {
    private let folders: [(String, Color)] = [
        ("Receipts", .orange),
        ("Work", .blue),
        ("School", .purple)
    ]

    var body: some View {
        VStack(spacing: 14) {
            Picker("Library Section", selection: .constant(1)) {
                Text("Library").tag(0)
                Text("Folders").tag(1)
            }
            .pickerStyle(.segmented)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(folders, id: \.0) { folder in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 4) {
                            ForEach(0..<3) { index in
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(folder.1.opacity(0.12 + (Double(index) * 0.06)))
                                    .overlay {
                                        VStack(spacing: 3) {
                                            ForEach(0..<3) { _ in
                                                Capsule()
                                                    .fill(folder.1.opacity(0.35))
                                                    .frame(height: 2)
                                            }
                                        }
                                        .padding(4)
                                    }
                                    .aspectRatio(0.72, contentMode: .fit)
                            }
                        }

                        Text(folder.0)
                            .font(.subheadline.weight(.semibold))

                        Text("3 documents")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color(.systemGroupedBackground))
        .accessibilityHidden(true)
    }
}

private struct OnboardingPhotoImportFallback: View {
    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle")
                    .font(.title2.weight(.semibold))
                    .frame(width: 64, height: 64)
                    .background(.regularMaterial, in: Circle())

                Label("Scan Document", systemImage: "document.viewfinder")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(Color.accentColor, in: Capsule())
            }

            Label("Search document titles", systemImage: "magnifyingglass")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .frame(minHeight: 56)
                .background(.regularMaterial, in: Capsule())
        }
        .padding(20)
        .background(Color(.systemGroupedBackground))
        .accessibilityHidden(true)
    }
}

private struct OnboardingDocumentMock: View {
    let title: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(.systemBackground))
                .overlay {
                    VStack(alignment: .leading, spacing: 5) {
                        Capsule()
                            .fill(color)
                            .frame(width: 42, height: 6)
                        ForEach(0..<5) { index in
                            Capsule()
                                .fill(Color.secondary.opacity(0.2))
                                .frame(maxWidth: index == 4 ? 54 : .infinity)
                                .frame(height: 3)
                        }
                    }
                    .padding(10)
                }
                .aspectRatio(0.82, contentMode: .fit)

            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .padding(8)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ProOnboardingPage: View {
    let isCompact: Bool

    var body: some View {
        VStack(spacing: isCompact ? 12 : 18) {
            Spacer(minLength: 0)

            Image("ProPaywallHero")
                .resizable()
                .scaledToFit()
                .frame(
                    width: isCompact ? 104 : 144,
                    height: isCompact ? 104 : 144
                )
                .accessibilityHidden(true)

            OnboardingTitle(
                title: "Extra privacy when you need it",
                subtitle: isCompact ? nil : "DocScanner Pro"
            )

            VStack(spacing: 0) {
                ProOnboardingFeature(
                    imageName: "ProSecureFolderIcon",
                    title: "Secure folders",
                    description: "Encrypt private folders and unlock them with Face ID, Touch ID, or your device passcode."
                )

                Divider()
                    .padding(.leading, isCompact ? 52 : 64)

                ProOnboardingFeature(
                    imageName: "ProProtectedPDFIcon",
                    title: "Password-protected PDFs",
                    description: "Add a password to the PDF copy you share. Your saved original stays unchanged."
                )
            }

            Label(
                "One purchase. Lifetime access. Future Pro features included.",
                systemImage: "checkmark.circle.fill"
            )
            .font(isCompact ? .subheadline.weight(.semibold) : .headline)
            .foregroundStyle(Color.accentColor)
            .multilineTextAlignment(.center)

            Spacer(minLength: 0)
        }
    }
}

private struct ProOnboardingFeature: View {
    let imageName: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(imageName)
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)

                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 16)
        .accessibilityElement(children: .combine)
    }
}

private struct OnboardingTitle: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)

            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

private struct OnboardingActionBarBackground: View {
    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.7), location: 0.32),
                        .init(color: .black, location: 0.58)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .ignoresSafeArea()
    }
}

#Preview("Welcome") {
    V2OnboardingView(mode: .automatic) { _ in }
}
