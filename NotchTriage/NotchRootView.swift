import AppKit
import SwiftUI

struct NotchRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var panelGeometry: NotchPanelGeometryModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pointerRegion = NotchPointerRegion.outside
    @State private var requestedCompactReveal: CompactWingReveal?
    @State private var compactRevealPointerInside = false
    @State private var compactRevealDismissTask: Task<Void, Never>?
    @State private var retainedCompactMedia = MediaSnapshot.idle
    private let hoveredNotchHeight = NotchLayout.hoveredHeight

    var body: some View {
        VStack(spacing: NotchLayout.expandedGap) {
            collapsedBar
                .frame(height: compactHeight)

            if model.isExpanded || model.isPanelClosing {
                ExpandedPanelSurface(model: model)
            }
        }
        // AppKit owns the panel's frame. Keep SwiftUI's proposed root size
        // aligned with the controller's target to prevent NSHostingView from
        // feeding changing ideal sizes back into the window during layout.
        .frame(
            width: panelGeometry.size.width,
            height: panelGeometry.size.height,
            alignment: .top
        )
        .background {
            if model.isExpanded || model.isPanelClosing {
                // Keep the expanded window's transparent gutters hit-testable
                // so a click beside the glass surface can dismiss the panel.
                Color.clear
                    .contentShape(Rectangle())
            }
        }
        .animation(NotchDesign.Motion.value, value: model.leftWingContent)
        .animation(NotchDesign.Motion.value, value: model.rightWingContent)
        .environment(\.locale, model.appLanguage.locale)
    }

    private var compactHeight: CGFloat {
        model.isHoveringNotch
            || model.isExpanded
            || model.isPanelClosing
            || model.systemHUD != nil
            || model.panelState.isPresentingFileDropTarget
            ? hoveredNotchHeight
            : model.menuBarHeight
    }

    private var collapsedBar: some View {
        ZStack(alignment: .top) {
            Button {
                model.toggleExpanded()
            } label: {
                LivingNotch(
                    model: model,
                    hoveredHeight: hoveredNotchHeight,
                    compactOverlaySide: activeCompactReveal?.side
                )
            }
            .buttonStyle(StableNotchButtonStyle())
            .contextMenu {
                Button {
                    model.openSettings()
                } label: {
                    Label("设置…", systemImage: "gearshape")
                }

                Divider()

                Button(role: .destructive) {
                    model.quitApplication()
                } label: {
                    Label("退出 Notch Triage", systemImage: "power")
                }
            }
            .background {
                NotchHoverTracker { location in
                    updatePointerRegion(at: location)
                }
            }
            .offset(x: compactAlignmentOffset)
            .accessibilityLabel(
                model.localized(
                    model.isExpanded ? "收起 Notch Triage" : "展开 Notch Triage"
                )
            )

            // Isolate adaptive reveal alignment from the main notch. Custom
            // alignment guides can expand a ZStack's layout bounds; keeping
            // them in a full-canvas sibling prevents that from moving the
            // centered LivingNotch.
            ZStack(alignment: .top) {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)

                compactRevealSurface(for: .left)
                compactRevealSurface(for: .right)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .onDisappear {
            compactRevealDismissTask?.cancel()
            compactRevealDismissTask = nil
        }
        .onChange(of: model.media) { _, snapshot in
            retainCompactMediaIdentity(from: snapshot)
        }
        .onChange(of: model.mediaCommandInFlight) { _, command in
            guard command != nil, model.media != .idle else { return }
            retainedCompactMedia = model.media
        }
    }

    private var activeCompactReveal: CompactWingReveal? {
        guard !model.isExpanded,
              !model.isPanelClosing,
              !model.isHoveringNotch,
              model.systemHUD == nil,
              !model.panelState.isPresentingFileDropTarget,
              let reveal = requestedCompactReveal else {
            return nil
        }

        let content = reveal.side == .left
            ? model.leftWingContent
            : model.rightWingContent
        switch (reveal.kind, content) {
        case (.battery, .battery):
            return reveal
        case (.media, .media):
            guard model.media != .idle,
                  model.mediaCommandAvailability.transportAvailable else {
                return nil
            }
            return reveal
        default:
            return nil
        }
    }

    private var leftWingWidth: CGFloat {
        NotchLayout.compactWingWidth(
            for: model.leftWingContent,
            media: model.media
        )
    }

    private var rightWingWidth: CGFloat {
        NotchLayout.compactWingWidth(
            for: model.rightWingContent,
            media: model.media
        )
    }

    private var compactAlignmentOffset: CGFloat {
        return NotchLayout.compactSurfaceHorizontalOffset(
            leftWingWidth: leftWingWidth,
            rightWingWidth: rightWingWidth
        )
    }

    @ViewBuilder
    private func compactRevealSurface(for side: NotchWingSide) -> some View {
        let content = side == .left
            ? model.leftWingContent
            : model.rightWingContent
        switch content {
        case .media:
            let reveal = CompactWingReveal(side: side, kind: .media)
            let active = activeCompactReveal == reveal
            CompactMediaTransportControls(
                model: model,
                snapshot: compactMediaSnapshot,
                side: side,
                isRevealed: active,
                reduceMotion: reduceMotion
            )
            .frame(
                width: NotchLayout.compactMediaControlsWidth,
                height: min(model.menuBarHeight, 40)
            )
            .offset(
                x: compactRevealHorizontalOffset(
                    for: side,
                    width: NotchLayout.compactMediaControlsWidth
                )
            )
            .zIndex(active ? 2 : 0)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
            .onHover { hovered in
                compactRevealHoverChanged(hovered, reveal: reveal)
            }
        case .battery:
            let reveal = CompactWingReveal(side: side, kind: .battery)
            let active = activeCompactReveal == reveal
            let notchWidth = model.notchWidth
            CompactBatteryStatusReveal(
                model: model,
                snapshot: model.power,
                side: side,
                isRevealed: active,
                reduceMotion: reduceMotion,
                style: model.ringAppearance.style(for: .battery)
            )
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: min(model.menuBarHeight, 40))
            .alignmentGuide(HorizontalAlignment.center) { dimensions in
                switch side {
                case .left:
                    return dimensions.width + notchWidth / 2
                case .right:
                    return -notchWidth / 2
                }
            }
            .zIndex(active ? 2 : 0)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
            .onHover { hovered in
                compactRevealHoverChanged(hovered, reveal: reveal)
            }
        case .codex, .hidden:
            EmptyView()
        }
    }

    private var compactMediaSnapshot: MediaSnapshot {
        model.media == .idle ? retainedCompactMedia : model.media
    }

    private func compactRevealHorizontalOffset(
        for side: NotchWingSide,
        width: CGFloat
    ) -> CGFloat {
        let distance = model.notchWidth / 2 + width / 2
        return side == .left ? -distance : distance
    }

    private func updatePointerRegion(at location: CGPoint?) {
        let region = pointerRegion(at: location)
        guard region != pointerRegion else { return }
        pointerRegion = region

        if requestedCompactReveal != nil {
            switch region {
            case .wing(let reveal):
                cancelCompactRevealDismissal()
                requestedCompactReveal = reveal
            case .outside, .notch:
                scheduleCompactRevealDismissal()
            }
            return
        }

        switch region {
        case .outside:
            model.setNotchHovered(false)
        case .notch:
            model.setNotchHovered(true)
        case .wing(let reveal):
            guard !model.isHoveringNotch else { return }
            cancelCompactRevealDismissal()
            if reveal.kind == .media {
                retainedCompactMedia = model.media
            }
            requestedCompactReveal = reveal
        }
    }

    private func pointerRegion(at location: CGPoint?) -> NotchPointerRegion {
        guard let location else { return .outside }
        guard !model.isExpanded,
              !model.isPanelClosing,
              model.systemHUD == nil,
              !model.panelState.isPresentingFileDropTarget else {
            return .notch
        }

        let contentOriginX = NotchLayout.shoulderRadius
        let leftRange = contentOriginX..<(contentOriginX + leftWingWidth)
        let rightOriginX = contentOriginX + leftWingWidth + model.notchWidth
        let rightRange = rightOriginX..<(rightOriginX + rightWingWidth)

        if leftRange.contains(location.x),
           let reveal = compactReveal(
               for: model.leftWingContent,
               side: .left
           ) {
            return .wing(reveal)
        }
        if rightRange.contains(location.x),
           let reveal = compactReveal(
               for: model.rightWingContent,
               side: .right
           ) {
            return .wing(reveal)
        }
        return .notch
    }

    private func compactReveal(
        for content: NotchWingContent,
        side: NotchWingSide
    ) -> CompactWingReveal? {
        switch content {
        case .battery:
            return CompactWingReveal(side: side, kind: .battery)
        case .media:
            guard model.media != .idle,
                  model.mediaCommandAvailability.transportAvailable else {
                return nil
            }
            return CompactWingReveal(side: side, kind: .media)
        case .codex, .hidden:
            return nil
        }
    }

    private func compactRevealHoverChanged(
        _ hovered: Bool,
        reveal: CompactWingReveal
    ) {
        Task { @MainActor in
            // SwiftUI can deliver onHover while reconciling the reveal
            // surface. Wait until that update has completed before touching
            // state that changes the same view hierarchy.
            await Task.yield()
            applyCompactRevealHoverChange(hovered, reveal: reveal)
        }
    }

    private func applyCompactRevealHoverChange(
        _ hovered: Bool,
        reveal: CompactWingReveal
    ) {
        guard activeCompactReveal == reveal || !hovered else { return }
        compactRevealPointerInside = hovered
        if hovered {
            cancelCompactRevealDismissal()
            requestedCompactReveal = reveal
        } else {
            scheduleCompactRevealDismissal()
        }
    }

    private func cancelCompactRevealDismissal() {
        compactRevealDismissTask?.cancel()
        compactRevealDismissTask = nil
    }

    private func scheduleCompactRevealDismissal() {
        guard requestedCompactReveal != nil else { return }
        compactRevealDismissTask?.cancel()
        compactRevealDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled,
                  !compactRevealPointerInside else { return }

            if case .wing(let reveal) = pointerRegion {
                requestedCompactReveal = reveal
                compactRevealDismissTask = nil
                return
            }

            requestedCompactReveal = nil
            compactRevealDismissTask = nil

            switch pointerRegion {
            case .outside:
                model.setNotchHovered(false)
            case .notch:
                if !model.isHoveringNotch {
                    model.setNotchHovered(true)
                }
            case .wing:
                break
            }
        }
    }

    private func retainCompactMediaIdentity(from snapshot: MediaSnapshot) {
        guard snapshot != .idle else { return }
        guard retainedCompactMedia == .idle
                || retainedCompactMedia.sourceName != snapshot.sourceName
                || retainedCompactMedia.bundleIdentifier != snapshot.bundleIdentifier
                || retainedCompactMedia.title != snapshot.title
                || retainedCompactMedia.artist != snapshot.artist else {
            return
        }
        retainedCompactMedia = snapshot
    }
}

struct NotchSilhouette: Shape {
    let shoulderRadius: CGFloat
    let bottomCornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let shoulder = min(
            shoulderRadius,
            min(rect.width / 4, rect.height / 3)
        )
        let bodyLeft = rect.minX + shoulder
        let bodyRight = rect.maxX - shoulder
        let bottomRadius = min(
            bottomCornerRadius,
            min(
                (bodyRight - bodyLeft) / 2,
                max(0, rect.height - shoulder)
            )
        )
        let bottom = rect.maxY

        var path = Path()
        // Extend the top edge slightly past the view bounds so antialiasing
        // can never reveal a seam against the physical display notch.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY - 1))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY - 1))

        // The display notch flares outward where it meets the top bezel.
        // These concave shoulders replace the abrupt 90-degree junction.
        path.addCurve(
            to: CGPoint(x: bodyRight, y: rect.minY + shoulder),
            control1: CGPoint(
                x: rect.maxX - shoulder * 0.58,
                y: rect.minY - 1
            ),
            control2: CGPoint(
                x: bodyRight,
                y: rect.minY + shoulder * 0.42
            )
        )
        path.addLine(
            to: CGPoint(x: bodyRight, y: bottom - bottomRadius)
        )
        path.addCurve(
            to: CGPoint(x: bodyRight - bottomRadius, y: bottom),
            control1: CGPoint(
                x: bodyRight,
                y: bottom - bottomRadius * 0.45
            ),
            control2: CGPoint(
                x: bodyRight - bottomRadius * 0.45,
                y: bottom
            )
        )
        path.addLine(
            to: CGPoint(x: bodyLeft + bottomRadius, y: bottom)
        )
        path.addCurve(
            to: CGPoint(x: bodyLeft, y: bottom - bottomRadius),
            control1: CGPoint(
                x: bodyLeft + bottomRadius * 0.45,
                y: bottom
            ),
            control2: CGPoint(
                x: bodyLeft,
                y: bottom - bottomRadius * 0.45
            )
        )
        path.addLine(
            to: CGPoint(x: bodyLeft, y: rect.minY + shoulder)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.minY - 1),
            control1: CGPoint(
                x: bodyLeft,
                y: rect.minY + shoulder * 0.42
            ),
            control2: CGPoint(
                x: rect.minX + shoulder * 0.58,
                y: rect.minY - 1
            )
        )
        path.closeSubpath()
        return path
    }
}

private struct StableNotchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

private struct NotchHoverTracker: NSViewRepresentable {
    let onPointerLocation: (CGPoint?) -> Void

    func makeNSView(context: Context) -> HoverTrackingView {
        let view = HoverTrackingView()
        view.onPointerLocation = onPointerLocation
        return view
    }

    func updateNSView(_ nsView: HoverTrackingView, context: Context) {
        nsView.onPointerLocation = onPointerLocation
    }
}

@MainActor
private final class HoverTrackingView: NSView {
    var onPointerLocation: ((CGPoint?) -> Void)?
    private var hoverArea: NSTrackingArea?
    private var pendingPointerLocation: CGPoint?
    private var hasPendingPointerLocation = false
    private var pointerDeliveryScheduled = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // inVisibleRect keeps this area synchronized with the view bounds.
        // Replacing it during every constraint pass can itself cause another
        // enter/move callback while SwiftUI is resizing the compact notch.
        guard hoverArea == nil else { return }

        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .activeAlways,
                .inVisibleRect
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        reportLocation(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        reportLocation(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        schedulePointerLocation(nil)
    }

    private func reportLocation(for event: NSEvent) {
        schedulePointerLocation(convert(event.locationInWindow, from: nil))
    }

    private func schedulePointerLocation(_ location: CGPoint?) {
        pendingPointerLocation = location
        hasPendingPointerLocation = true
        guard !pointerDeliveryScheduled else { return }
        pointerDeliveryScheduled = true

        // The callback changes SwiftUI layout. Deliver it after AppKit has
        // completed the current event/constraint pass and coalesce any mouse
        // movement generated by that same layout change.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pointerDeliveryScheduled = false
            guard self.hasPendingPointerLocation else { return }

            let location = self.pendingPointerLocation
            self.pendingPointerLocation = nil
            self.hasPendingPointerLocation = false
            self.onPointerLocation?(location)
        }
    }
}

enum NotchWingSide: Equatable {
    case left
    case right
}

private enum CompactWingRevealKind: Equatable {
    case media
    case battery
}

private struct CompactWingReveal: Equatable {
    let side: NotchWingSide
    let kind: CompactWingRevealKind
}

private enum NotchPointerRegion: Equatable {
    case outside
    case notch
    case wing(CompactWingReveal)
}
