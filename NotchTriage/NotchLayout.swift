import CoreGraphics

enum PanelGeometryPhase: Equatable {
    case compact
    case peek
    case workspace
}

struct PanelGeometry: Equatable {
    let windowFrame: CGRect
    let visibleSurfaceFrame: CGRect
    let hoverTrackingFrame: CGRect
    let dropHitFrame: CGRect
}

enum NotchLayout {
    static let panelWidth: CGFloat = 560
    static let hoveredHeight: CGFloat = 74
    static let expandedGap: CGFloat = 16
    static let expandedPanelWidth: CGFloat = 520
    static let expandedPanelHeight: CGFloat = 460
    static let shoulderRadius: CGFloat = 6
    static let compactWingSlotWidth: CGFloat = 37
    static let minimumMenuBarHeight: CGFloat = 32

    static var expandedHeight: CGFloat {
        hoveredHeight + expandedGap + expandedPanelHeight
    }

    static func menuBarHeight(
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> CGFloat {
        max(minimumMenuBarHeight, screenFrame.maxY - visibleFrame.maxY)
    }

    static func panelHeight(
        menuBarHeight: CGFloat,
        phase: PanelGeometryPhase
    ) -> CGFloat {
        switch phase {
        case .compact:
            return menuBarHeight
        case .peek:
            return max(menuBarHeight, hoveredHeight)
        case .workspace:
            return expandedHeight
        }
    }

    static func windowFrame(
        screenFrame: CGRect,
        height: CGFloat
    ) -> CGRect {
        CGRect(
            x: screenFrame.midX - panelWidth / 2,
            y: screenFrame.maxY - height,
            width: panelWidth,
            height: height
        )
    }

    static func geometry(
        screenFrame: CGRect,
        menuBarHeight: CGFloat,
        phase: PanelGeometryPhase,
        compactSurfaceWidth: CGFloat = panelWidth,
        compactSurfaceHorizontalOffset: CGFloat = 0
    ) -> PanelGeometry {
        let height = panelHeight(
            menuBarHeight: menuBarHeight,
            phase: phase
        )
        let windowFrame = windowFrame(
            screenFrame: screenFrame,
            height: height
        )

        let clampedCompactSurfaceWidth = min(
            panelWidth,
            max(0, compactSurfaceWidth)
        )
        let compactSurfaceFrame = CGRect(
            x: windowFrame.midX
                - clampedCompactSurfaceWidth / 2
                + compactSurfaceHorizontalOffset,
            y: windowFrame.maxY - min(menuBarHeight, 40),
            width: clampedCompactSurfaceWidth,
            height: min(menuBarHeight, 40)
        )
        let peekWidth = peekSurfaceWidth(
            compactSurfaceWidth: clampedCompactSurfaceWidth
        )
        let peekSurfaceFrame = CGRect(
            x: windowFrame.midX
                - peekWidth / 2
                + compactSurfaceHorizontalOffset,
            y: windowFrame.maxY - hoveredHeight,
            width: peekWidth,
            height: hoveredHeight
        )

        let visibleSurfaceFrame: CGRect
        let hoverTrackingFrame: CGRect
        switch phase {
        case .workspace:
            visibleSurfaceFrame = workspaceVisibleSurfaceFrame(
                in: windowFrame
            )
            hoverTrackingFrame = peekSurfaceFrame
        case .peek:
            hoverTrackingFrame = peekSurfaceFrame
            visibleSurfaceFrame = hoverTrackingFrame
        case .compact:
            visibleSurfaceFrame = compactSurfaceFrame
            hoverTrackingFrame = compactSurfaceFrame
        }

        return PanelGeometry(
            windowFrame: windowFrame,
            visibleSurfaceFrame: visibleSurfaceFrame,
            hoverTrackingFrame: hoverTrackingFrame,
            dropHitFrame: hoverTrackingFrame
        )
    }

    static func workspaceVisibleSurfaceFrame(
        in panelFrame: CGRect
    ) -> CGRect {
        CGRect(
            x: panelFrame.midX - expandedPanelWidth / 2,
            y: panelFrame.maxY - expandedHeight,
            width: expandedPanelWidth,
            height: expandedHeight
        )
    }

    static func compactWingWidth(
        for content: NotchWingContent,
        media: MediaSnapshot
    ) -> CGFloat {
        switch content {
        case .battery, .codex:
            return compactWingSlotWidth
        case .media:
            return media == .idle ? 0 : compactWingSlotWidth
        case .hidden:
            return 0
        }
    }

    static func compactSurfaceWidth(
        leftWingWidth: CGFloat,
        notchWidth: CGFloat,
        rightWingWidth: CGFloat
    ) -> CGFloat {
        leftWingWidth + notchWidth + rightWingWidth + shoulderRadius * 2
    }

    static func compactSurfaceHorizontalOffset(
        leftWingWidth: CGFloat,
        rightWingWidth: CGFloat
    ) -> CGFloat {
        (rightWingWidth - leftWingWidth) / 2
    }

    static func peekSurfaceWidth(
        compactSurfaceWidth: CGFloat
    ) -> CGFloat {
        min(panelWidth, max(0, compactSurfaceWidth))
    }

    static func resolvedNotchWidth(
        hasSafeArea: Bool,
        measuredWidth: CGFloat?
    ) -> CGFloat {
        guard hasSafeArea else { return 168 }
        guard let measuredWidth,
              measuredWidth.isFinite,
              measuredWidth > 100 else {
            return 186
        }
        return measuredWidth
    }
}
