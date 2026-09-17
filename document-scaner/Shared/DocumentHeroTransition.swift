import SwiftUI

enum DocumentHeroTransition {
    static func usesZoom(supportsZoom: Bool, reduceMotion: Bool) -> Bool {
        supportsZoom && !reduceMotion
    }
}

extension View {
    @ViewBuilder
    func documentHeroSource(id: UUID, in namespace: Namespace.ID, enabled: Bool) -> some View {
        if #available(iOS 18.0, *), enabled {
            matchedTransitionSource(id: id, in: namespace) { source in
                source
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(
                        cornerRadius: DocumentCardLayout.cardCornerRadius,
                        style: .continuous
                    ))
                    .shadow(color: .clear, radius: 0)
            }
        } else {
            self
        }
    }

    @ViewBuilder
    func documentHeroDestination(id: UUID, in namespace: Namespace.ID, reduceMotion: Bool) -> some View {
        if #available(iOS 18.0, *),
           DocumentHeroTransition.usesZoom(supportsZoom: true, reduceMotion: reduceMotion) {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}
