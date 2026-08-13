import AppKit
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
    func nativeLiquidGlassSurface(
        level: Double,
        cornerRadius: CGFloat,
        samplesDesktopBackdrop: Bool = false
    ) -> some View {
        modifier(
            NativeLiquidGlassSurface(
                level: level,
                cornerRadius: cornerRadius,
                samplesDesktopBackdrop: samplesDesktopBackdrop
            )
        )
    }

    func panelGroupSurface(
        cornerRadius: CGFloat = NotchDesign.Radius.group
    ) -> some View {
        modifier(PanelGroupSurface(cornerRadius: cornerRadius))
    }
}

private struct NativeLiquidGlassSurface: ViewModifier {
    let level: Double
    let cornerRadius: CGFloat
    let samplesDesktopBackdrop: Bool

    func body(content: Content) -> some View {
        NativeLiquidGlassHost(
            level: level,
            cornerRadius: cornerRadius,
            samplesDesktopBackdrop: samplesDesktopBackdrop,
            content: content
        )
    }
}

private struct NativeLiquidGlassHost<Content: View>: NSViewRepresentable {
    let level: Double
    let cornerRadius: CGFloat
    let samplesDesktopBackdrop: Bool
    let content: Content

    func makeNSView(context: Context) -> NativeLiquidGlassHostView<Content> {
        NativeLiquidGlassHostView(
            rootView: content,
            level: level,
            cornerRadius: cornerRadius,
            samplesDesktopBackdrop: samplesDesktopBackdrop
        )
    }

    func updateNSView(
        _ nsView: NativeLiquidGlassHostView<Content>,
        context: Context
    ) {
        nsView.update(
            rootView: content,
            level: level,
            cornerRadius: cornerRadius,
            samplesDesktopBackdrop: samplesDesktopBackdrop
        )
    }
}

private final class NativeLiquidGlassHostView<Content: View>: NSView {
    private static var glassTint: NSColor {
        NSColor.black.withAlphaComponent(0.32)
    }

    private let desktopBackdrop = NSVisualEffectView()
    private let regularGlass = NSGlassEffectView()
    private let clearGlass = NSGlassEffectView()
    private let hostingView: NSHostingView<Content>

    init(
        rootView: Content,
        level: Double,
        cornerRadius: CGFloat,
        samplesDesktopBackdrop: Bool
    ) {
        hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = true

        desktopBackdrop.material = .underWindowBackground
        desktopBackdrop.blendingMode = .behindWindow
        desktopBackdrop.state = .active
        desktopBackdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(desktopBackdrop)
        NSLayoutConstraint.activate([
            desktopBackdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            desktopBackdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            desktopBackdrop.topAnchor.constraint(equalTo: topAnchor),
            desktopBackdrop.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        regularGlass.style = .regular
        regularGlass.contentView = NSView()
        clearGlass.style = .clear
        clearGlass.contentView = hostingView

        for glass in [regularGlass, clearGlass] {
            glass.translatesAutoresizingMaskIntoConstraints = false
            addSubview(glass)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: trailingAnchor),
                glass.topAnchor.constraint(equalTo: topAnchor),
                glass.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        update(
            rootView: rootView,
            level: level,
            cornerRadius: cornerRadius,
            samplesDesktopBackdrop: samplesDesktopBackdrop
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        rootView: Content,
        level: Double,
        cornerRadius: CGFloat,
        samplesDesktopBackdrop: Bool
    ) {
        let appearance = LiquidGlassAppearance(level: level)
        hostingView.rootView = rootView
        layer?.cornerRadius = cornerRadius
        desktopBackdrop.alphaValue = samplesDesktopBackdrop
            ? appearance.desktopBackdropOpacity
            : 0
        desktopBackdrop.isHidden = !samplesDesktopBackdrop
        clearGlass.tintColor = Self.glassTint
        regularGlass.tintColor = Self.glassTint
        clearGlass.cornerRadius = cornerRadius
        regularGlass.cornerRadius = cornerRadius
        regularGlass.alphaValue = appearance.regularLayerOpacity
        regularGlass.isHidden = appearance.regularLayerOpacity <= 0.001
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        hostingView.fittingSize
    }
}
