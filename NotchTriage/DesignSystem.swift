import SwiftUI

struct LiquidGlassAppearance: Equatable, Sendable {
    static let defaultIntensity = 0.68

    let intensity: Double

    init(intensity: Double) {
        let finiteValue = intensity.isFinite
            ? intensity
            : Self.defaultIntensity
        self.intensity = min(max(finiteValue, 0), 1)
    }

    var dimmingOpacity: Double { 0.24 + intensity * 0.38 }
    var outerHighlightOpacity: Double { 0.20 + intensity * 0.38 }
    var innerHighlightOpacity: Double { 0.055 + intensity * 0.14 }
}

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

private struct LiquidGlassPanelSurface: ViewModifier {
    let cornerRadius: CGFloat
    let intensity: Double

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var appearance: LiquidGlassAppearance {
        LiquidGlassAppearance(intensity: intensity)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .glassEffect(
                reduceTransparency ? .identity : .clear,
                in: .rect(cornerRadius: cornerRadius)
            )
            .background {
                shape.fill(
                    reduceTransparency
                        ? Color(nsColor: .windowBackgroundColor).opacity(0.96)
                        : Color.black.opacity(appearance.dimmingOpacity)
                )
            }
            .overlay {
                shape
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(
                                    color: .white.opacity(
                                        reduceTransparency
                                            ? 0.18
                                            : appearance.outerHighlightOpacity
                                    ),
                                    location: 0
                                ),
                                .init(color: .white.opacity(0.13), location: 0.22),
                                .init(color: .white.opacity(0.035), location: 0.52),
                                .init(color: .white.opacity(0.17), location: 0.82),
                                .init(color: .white.opacity(0.08), location: 1)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.05
                    )
                    .blendMode(.screen)
            }
            .overlay {
                shape
                    .inset(by: 1.35)
                    .strokeBorder(
                        .white.opacity(
                            reduceTransparency
                                ? 0.06
                                : appearance.innerHighlightOpacity
                        ),
                        lineWidth: 0.55
                    )
                    .blur(radius: 0.35)
                    .blendMode(.screen)
            }
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
    func liquidGlassPanelSurface(
        cornerRadius: CGFloat = NotchDesign.Radius.panel,
        intensity: Double = LiquidGlassAppearance.defaultIntensity
    ) -> some View {
        modifier(
            LiquidGlassPanelSurface(
                cornerRadius: cornerRadius,
                intensity: intensity
            )
        )
    }

    func panelGroupSurface(
        cornerRadius: CGFloat = NotchDesign.Radius.group
    ) -> some View {
        modifier(PanelGroupSurface(cornerRadius: cornerRadius))
    }
}
