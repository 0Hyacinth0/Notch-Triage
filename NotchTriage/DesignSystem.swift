import SwiftUI

enum NotchDesign {
    enum Spacing {
        static let panelInset: CGFloat = 20
        static let section: CGFloat = 16
        static let group: CGFloat = 12
        static let row: CGFloat = 8
    }

    enum Radius {
        static let panel: CGFloat = 26
        static let group: CGFloat = 17
        static let compactGroup: CGFloat = 14
    }

    enum Motion {
        static let value = Animation.easeInOut(duration: 0.18)
        static let hover = Animation.timingCurve(
            0.22,
            0.72,
            0,
            1,
            duration: 0.28
        )
        static let panelOpen = Animation.timingCurve(
            0.16,
            1,
            0.3,
            1,
            duration: 0.38
        )
        static let panelClose = Animation.timingCurve(
            0.4,
            0,
            1,
            1,
            duration: 0.30
        )
        static let sectionChange = Animation.easeInOut(duration: 0.20)
    }
}

private struct PanelGroupSurface: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                .primary.opacity(0.045),
                in: RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
                .stroke(.primary.opacity(0.07), lineWidth: 0.5)
            }
    }
}

extension View {
    func panelGroupSurface(
        cornerRadius: CGFloat = NotchDesign.Radius.group
    ) -> some View {
        modifier(PanelGroupSurface(cornerRadius: cornerRadius))
    }
}
