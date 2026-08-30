import AppKit
import SwiftUI

struct NotchRootView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pointerRegion = NotchPointerRegion.outside
    @State private var requestedMediaControlSide: NotchWingSide?
    @State private var mediaControlsPointerInside = false
    @State private var mediaControlsDismissTask: Task<Void, Never>?
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                    mediaOverlaySide: activeMediaControlSide
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
                model.isExpanded ? "收起 Notch Triage" : "展开 Notch Triage"
            )

            // Keep both control surfaces mounted in the panel's fixed canvas.
            // Their reveal never changes the main silhouette width or feeds
            // another geometry change back into AppKit window constraints.
            compactMediaSurface(for: .left)
            compactMediaSurface(for: .right)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .onDisappear {
            mediaControlsDismissTask?.cancel()
            mediaControlsDismissTask = nil
        }
        .onChange(of: model.media) { _, snapshot in
            retainCompactMediaIdentity(from: snapshot)
        }
        .onChange(of: model.mediaCommandInFlight) { _, command in
            guard command != nil, model.media != .idle else { return }
            retainedCompactMedia = model.media
        }
    }

    private var activeMediaControlSide: NotchWingSide? {
        guard !model.isExpanded,
              !model.isPanelClosing,
              !model.isHoveringNotch,
              model.systemHUD == nil,
              !model.panelState.isPresentingFileDropTarget,
              let side = requestedMediaControlSide else {
            return nil
        }

        switch side {
        case .left:
            return model.leftWingContent == .media ? .left : nil
        case .right:
            return model.rightWingContent == .media ? .right : nil
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
    private func compactMediaSurface(for side: NotchWingSide) -> some View {
        let active = activeMediaControlSide == side
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
        .offset(x: mediaControlHorizontalOffset(for: side))
        .zIndex(active ? 2 : 0)
        .allowsHitTesting(active)
        .accessibilityHidden(!active)
        .onHover { hovered in
            mediaControlsHoverChanged(hovered, side: side)
        }
    }

    private var compactMediaSnapshot: MediaSnapshot {
        model.media == .idle ? retainedCompactMedia : model.media
    }

    private func mediaControlHorizontalOffset(for side: NotchWingSide) -> CGFloat {
        let distance = model.notchWidth / 2
            + NotchLayout.compactMediaControlsWidth / 2
        return side == .left ? -distance : distance
    }

    private func updatePointerRegion(at location: CGPoint?) {
        let region = pointerRegion(at: location)
        guard region != pointerRegion else { return }
        pointerRegion = region

        if requestedMediaControlSide != nil {
            switch region {
            case .media(let side):
                cancelMediaControlsDismissal()
                requestedMediaControlSide = side
            case .outside, .notch:
                scheduleMediaControlsDismissal()
            }
            return
        }

        switch region {
        case .outside:
            model.setNotchHovered(false)
        case .notch:
            model.setNotchHovered(true)
        case .media(let side):
            guard !model.isHoveringNotch else { return }
            cancelMediaControlsDismissal()
            retainedCompactMedia = model.media
            requestedMediaControlSide = side
        }
    }

    private func pointerRegion(at location: CGPoint?) -> NotchPointerRegion {
        guard let location else { return .outside }
        guard !model.isExpanded,
              !model.isPanelClosing,
              model.systemHUD == nil,
              !model.panelState.isPresentingFileDropTarget,
              model.media != .idle,
              model.mediaCommandAvailability.transportAvailable else {
            return .notch
        }

        let contentOriginX = NotchLayout.shoulderRadius
        let leftRange = contentOriginX..<(contentOriginX + leftWingWidth)
        let rightOriginX = contentOriginX + leftWingWidth + model.notchWidth
        let rightRange = rightOriginX..<(rightOriginX + rightWingWidth)

        if model.leftWingContent == .media, leftRange.contains(location.x) {
            return .media(.left)
        }
        if model.rightWingContent == .media, rightRange.contains(location.x) {
            return .media(.right)
        }
        return .notch
    }

    private func mediaControlsHoverChanged(
        _ hovered: Bool,
        side: NotchWingSide
    ) {
        guard activeMediaControlSide == side || !hovered else { return }
        mediaControlsPointerInside = hovered
        if hovered {
            cancelMediaControlsDismissal()
            requestedMediaControlSide = side
        } else {
            scheduleMediaControlsDismissal()
        }
    }

    private func cancelMediaControlsDismissal() {
        mediaControlsDismissTask?.cancel()
        mediaControlsDismissTask = nil
    }

    private func scheduleMediaControlsDismissal() {
        guard requestedMediaControlSide != nil else { return }
        mediaControlsDismissTask?.cancel()
        mediaControlsDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled,
                  !mediaControlsPointerInside else { return }

            if case .media(let side) = pointerRegion {
                requestedMediaControlSide = side
                mediaControlsDismissTask = nil
                return
            }

            requestedMediaControlSide = nil
            mediaControlsDismissTask = nil

            switch pointerRegion {
            case .outside:
                model.setNotchHovered(false)
            case .notch:
                if !model.isHoveringNotch {
                    model.setNotchHovered(true)
                }
            case .media:
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

private struct NotchSilhouette: Shape {
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

private enum NotchWingSide: Equatable {
    case left
    case right
}

private enum NotchPointerRegion: Equatable {
    case outside
    case notch
    case media(NotchWingSide)
}

private struct AttentionRing<Content: View>: View {
    @ObservedObject var model: AppModel
    let diameter: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            content()

            if model.notificationAttentionActive {
                NotificationPrompt(model: model)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

private struct NotificationPrompt: View {
    @ObservedObject var model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var phaseIsActive: Bool {
        model.notificationAnimationTick.isMultiple(of: 2) == false
    }

    private var animation: Animation {
        switch model.notificationPromptAnimation {
        case .pulse: return .easeInOut(duration: 0.62)
        case .float: return .easeInOut(duration: 0.76)
        case .twinkle: return .easeInOut(duration: 0.46)
        case .bounce: return .spring(response: 0.48, dampingFraction: 0.62)
        }
    }

    var body: some View {
        Image(systemName: model.notificationPromptIcon.symbol)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(model.notificationPromptColor.color)
            .scaleEffect(scale)
            .opacity(opacity)
            .rotationEffect(rotation)
            .offset(y: verticalOffset)
            .animation(
                reduceMotion ? .linear(duration: 0.01) : animation,
                value: model.notificationAnimationTick
            )
            .accessibilityLabel("通知提示")
    }

    private var scale: CGFloat {
        guard !reduceMotion else { return 1 }
        switch model.notificationPromptAnimation {
        case .pulse: return phaseIsActive ? 1.18 : 0.94
        case .float: return phaseIsActive ? 1.04 : 0.98
        case .twinkle: return phaseIsActive ? 1.12 : 0.94
        case .bounce: return phaseIsActive ? 1.18 : 0.92
        }
    }

    private var opacity: Double {
        guard !reduceMotion else { return 0.92 }
        switch model.notificationPromptAnimation {
        case .pulse: return phaseIsActive ? 1 : 0.68
        case .float: return phaseIsActive ? 0.92 : 0.78
        case .twinkle: return phaseIsActive ? 1 : 0.58
        case .bounce: return phaseIsActive ? 1 : 0.72
        }
    }

    private var rotation: Angle {
        guard !reduceMotion else { return .zero }
        switch model.notificationPromptAnimation {
        case .pulse: return .zero
        case .float: return phaseIsActive ? .degrees(-3) : .degrees(3)
        case .twinkle: return phaseIsActive ? .degrees(8) : .degrees(-8)
        case .bounce: return .zero
        }
    }

    private var verticalOffset: CGFloat {
        guard !reduceMotion else { return 0 }
        switch model.notificationPromptAnimation {
        case .pulse, .twinkle, .bounce: return 0
        case .float: return phaseIsActive ? -1.5 : 1.5
        }
    }
}

private struct CompactMediaContent: View {
    @ObservedObject var model: AppModel
    let snapshot: MediaSnapshot
    let style: RingStyle

    var body: some View {
        AttentionRing(
            model: model,
            diameter: 22
        ) {
            MediaProgressRing(
                snapshot: snapshot,
                style: style,
                diameter: 22,
                lineWidth: 3.2
            )
        }
            .frame(width: 37, height: 37)
            .foregroundStyle(.white)
            .help(mediaHelp)
            .accessibilityLabel(mediaHelp)
    }

    private var mediaHelp: String {
        let artist = snapshot.artist.isEmpty ? snapshot.sourceName : snapshot.artist
        return "\(snapshot.title) · \(artist) · \(Int((snapshot.progress * 100).rounded()))%"
    }
}

private struct CompactMediaTransportControls: View {
    @ObservedObject var model: AppModel
    let snapshot: MediaSnapshot
    let side: NotchWingSide
    let isRevealed: Bool
    let reduceMotion: Bool

    private var commands: [MediaCommand] {
        switch side {
        case .left:
            return [.previousTrack, .nextTrack, .togglePlayPause]
        case .right:
            return [.togglePlayPause, .previousTrack, .nextTrack]
        }
    }

    var body: some View {
        ZStack {
            CompactMediaRevealShape(
                side: side,
                progress: isRevealed ? 1 : 0
            )
            .fill(.black)
            .opacity(isRevealed ? 1 : 0)
            .animation(revealAnimation, value: isRevealed)

            HStack(spacing: 8) {
                ForEach(Array(commands.enumerated()), id: \.element.rawValue) { index, command in
                    CompactMediaTransportButton(
                        model: model,
                        snapshot: snapshot,
                        command: command
                    )
                    .opacity(isRevealed ? 1 : 0)
                    .scaleEffect(isRevealed ? 1 : 0.82)
                    .offset(
                        x: isRevealed
                            ? 0
                            : collapsedControlOffset(at: index)
                    )
                    .animation(
                        controlAnimation(at: index),
                        value: isRevealed
                    )
                }
            }
            .frame(
                maxWidth: .infinity,
                alignment: side == .left ? .trailing : .leading
            )
            .padding(side == .left ? .trailing : .leading, 3.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {}
        .accessibilityElement(children: .contain)
        .accessibilityLabel("快速媒体控制")
    }

    private var revealAnimation: Animation {
        reduceMotion
            ? .linear(duration: 0.01)
            : NotchDesign.Motion.hover
    }

    private func distanceFromAnchor(at index: Int) -> Int {
        switch side {
        case .left:
            return commands.count - 1 - index
        case .right:
            return index
        }
    }

    private func collapsedControlOffset(at index: Int) -> CGFloat {
        let distance = CGFloat(distanceFromAnchor(at: index))
        let offset = distance * 18
        return side == .left ? offset : -offset
    }

    private func controlAnimation(at index: Int) -> Animation {
        guard !reduceMotion else { return .linear(duration: 0.01) }
        guard isRevealed else { return .easeOut(duration: 0.12) }
        return NotchDesign.Motion.hover.delay(
            Double(distanceFromAnchor(at: index)) * 0.035
        )
    }
}

private struct CompactMediaRevealShape: Shape {
    let side: NotchWingSide
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let progress = min(1, max(0, progress))
        let collapsedWidth = min(
            NotchLayout.compactWingSlotWidth,
            rect.width
        )
        let width = collapsedWidth
            + (rect.width - collapsedWidth) * progress
        let revealRect: CGRect

        switch side {
        case .left:
            revealRect = CGRect(
                x: rect.maxX - width,
                y: rect.minY,
                width: width,
                height: rect.height
            )
        case .right:
            revealRect = CGRect(
                x: rect.minX,
                y: rect.minY,
                width: width,
                height: rect.height
            )
        }

        return NotchSilhouette(
            shoulderRadius: NotchLayout.shoulderRadius,
            bottomCornerRadius: 12
        )
        .path(in: revealRect)
    }
}

private struct CompactMediaTransportButton: View {
    @ObservedObject var model: AppModel
    let snapshot: MediaSnapshot
    let command: MediaCommand

    private var isEnabled: Bool {
        model.isMediaCommandEnabled(command)
    }

    private var isSending: Bool {
        model.mediaCommandInFlight == command
    }

    private var imageName: String {
        if command == .togglePlayPause {
            return snapshot.isPlaying ? "pause.fill" : "play.fill"
        }
        return command.systemImage
    }

    private var helpText: String {
        if let reason = model.mediaCommandAvailability.disabledReason(for: command) {
            return "\(command.title) · \(reason)"
        }
        return command.title
    }

    private var diameter: CGFloat {
        command == .togglePlayPause ? 30 : 28
    }

    var body: some View {
        Button {
            model.sendMediaCommand(command)
        } label: {
            ZStack {
                if command == .togglePlayPause {
                    Circle()
                        .fill(.white.opacity(0.045))
                }

                if command == .togglePlayPause, !isSending {
                    MediaProgressRing(
                        snapshot: snapshot,
                        style: model.ringAppearance.style(for: .media),
                        diameter: 30,
                        lineWidth: 2.5
                    )
                }

                if isSending {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                } else {
                    Image(systemName: imageName)
                        .font(
                            .system(
                                size: command == .togglePlayPause ? 11.5 : 11,
                                weight: .semibold
                            )
                        )
                        .foregroundStyle(
                            .white.opacity(
                                command == .togglePlayPause ? 1 : 0.86
                            )
                        )
                }
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }
        .buttonStyle(CompactMediaTransportButtonStyle())
        .disabled(!isEnabled)
        .opacity(isSending ? 0.78 : (isEnabled ? 1 : 0.34))
        .help(helpText)
        .accessibilityLabel(command.title)
        .accessibilityValue(
            isSending ? "正在发送" : (isEnabled ? "可用" : "不可用")
        )
    }
}

private struct CompactMediaTransportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Circle()
                    .fill(.white.opacity(configuration.isPressed ? 0.13 : 0))
            }
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(
                .easeOut(duration: 0.10),
                value: configuration.isPressed
            )
    }
}

private struct CompactWingSlot: View {
    @ObservedObject var model: AppModel
    let content: NotchWingContent

    var body: some View {
        Group {
            switch content {
            case .battery:
                CompactBatteryContent(
                    model: model,
                    snapshot: model.power,
                    style: model.ringAppearance.style(for: .battery)
                )
            case .codex:
                CompactCodexContent(
                    model: model,
                    limits: model.codexLimits,
                    health: model.codexHealth,
                    style: model.ringAppearance.style(for: .codex)
                )
            case .media:
                if model.media != .idle {
                    CompactMediaContent(
                        model: model,
                        snapshot: model.media,
                        style: model.ringAppearance.style(for: .media)
                    )
                }
            case .hidden:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .id(content)
        .transition(.opacity)
    }
}

private struct CompactBatteryContent: View {
    @ObservedObject var model: AppModel
    let snapshot: PowerSnapshot
    let style: RingStyle

    var body: some View {
        AttentionRing(
            model: model,
            diameter: 22
        ) {
            UsageArc(
                progress: Double(snapshot.batteryPercent) / 100,
                style: ringStyle,
                lineWidth: 3.2
            )
        }
        .foregroundStyle(.white)
        .animation(NotchDesign.Motion.value, value: snapshot.updatedAt)
        .help(batteryHelp)
        .accessibilityLabel(batteryHelp)
    }

    private var ringStyle: RingStyle {
        style
    }

    private var batteryHelp: String {
        if let chargingWatts = snapshot.chargingWatts {
            return "电池 \(snapshot.batteryPercent)% · 正在充电 \(String(format: "%.1f W", chargingWatts))"
        }
        if snapshot.isExternalPowerConnected {
            return "电池 \(snapshot.batteryPercent)% · 已连接电源"
        }
        return "电池 \(snapshot.batteryPercent)% · 电池供电"
    }

}

private struct LivingNotch: View {
    @ObservedObject var model: AppModel
    let hoveredHeight: CGFloat
    let mediaOverlaySide: NotchWingSide?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let shoulderRadius = NotchLayout.shoulderRadius

    private var hovering: Bool {
        model.isHoveringNotch
            || model.isExpanded
            || model.isPanelClosing
            || model.systemHUD != nil
            || model.panelState.isPresentingFileDropTarget
    }

    private var leftWidth: CGFloat {
        NotchLayout.compactWingWidth(
            for: model.leftWingContent,
            media: model.media
        )
    }

    private var rightWidth: CGFloat {
        NotchLayout.compactWingWidth(
            for: model.rightWingContent,
            media: model.media
        )
    }

    private var compactWidth: CGFloat {
        leftWidth + model.notchWidth + rightWidth
    }

    private var compactSurfaceWidth: CGFloat {
        NotchLayout.compactSurfaceWidth(
            leftWingWidth: leftWidth,
            notchWidth: model.notchWidth,
            rightWingWidth: rightWidth
        )
    }

    private var width: CGFloat {
        compactSurfaceWidth
    }

    private var height: CGFloat {
        hovering ? hoveredHeight : min(model.menuBarHeight, 40)
    }

    private var showsHoverPreview: Bool {
        hovering
            && model.systemHUD == nil
            && !model.panelState.isPresentingFileDropTarget
    }

    private var notificationCount: Int {
        model.notificationSources.reduce(0) { $0 + $1.count }
    }

    var body: some View {
        NotchSilhouette(
            shoulderRadius: shoulderRadius,
            bottomCornerRadius: hovering ? 22 : 12
        )
        .fill(.black)
        .frame(width: width, height: height, alignment: .top)
        .overlay {
            compactContent
                .opacity(hovering ? 0 : 1)
                .accessibilityHidden(hovering)
        }
        .overlay {
            hoverPreview
                .frame(width: compactWidth, height: height)
                .opacity(showsHoverPreview ? 1 : 0)
                .accessibilityHidden(!showsHoverPreview)
        }
        .overlay {
            if let target = model.panelState.fileDropTarget {
                FileDropTargetContent(acceptance: target.acceptance)
                    .frame(
                        width: max(0, width - NotchLayout.shoulderRadius * 2),
                        height: height
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .overlay {
            if let snapshot = model.systemHUD {
                SystemHUDContent(
                    snapshot: snapshot,
                    menuBarHeight: model.menuBarHeight
                )
                .frame(width: compactWidth, height: height)
                .id(snapshot.kind)
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .background {
            NotchFileDropTarget(
                onDragEntered: { sessionID, urls, itemCount in
                    model.fileDragEntered(
                        sessionID: sessionID,
                        urls: urls,
                        itemCount: itemCount
                    )
                },
                onDragExited: { sessionID in
                    model.fileDragExited(sessionID: sessionID)
                },
                onDrop: { sessionID, urls, itemCount in
                    model.performFileDrop(
                        sessionID: sessionID,
                        urls: urls,
                        itemCount: itemCount
                    )
                }
            )
        }
        .foregroundStyle(.white)
        .animation(
            reduceMotion ? .linear(duration: 0.01) : NotchDesign.Motion.hover,
            value: hovering
        )
    }

    private var compactContent: some View {
        HStack(spacing: 0) {
            CompactWingSlot(
                model: model,
                content: model.leftWingContent
            )
            .frame(width: leftWidth, height: height)
            .opacity(mediaOverlaySide == .left ? 0 : 1)
            .animation(
                compactMediaSlotAnimation(for: .left),
                value: mediaOverlaySide
            )

            ZStack {
                if model.panelState.canShowNotificationPulse,
                   let pulse = model.notificationPulse {
                    SourceIcon(
                        bundleIdentifier: pulse.bundleIdentifier,
                        fallback: "bell.fill"
                    )
                    .frame(width: 22, height: 22)
                    .transition(
                        .scale(scale: 0.35)
                            .combined(with: .opacity)
                    )
                    .accessibilityLabel("\(pulse.sourceName) 通知")
                } else {
                    Capsule()
                        .fill(.white.opacity(0.12))
                        .frame(width: 22, height: 2)
                        .padding(.top, max(0, model.menuBarHeight - 9))
                }
            }
            .frame(width: model.notchWidth, height: height, alignment: .top)

            CompactWingSlot(
                model: model,
                content: model.rightWingContent
            )
            .frame(width: rightWidth, height: height)
            .opacity(mediaOverlaySide == .right ? 0 : 1)
            .animation(
                compactMediaSlotAnimation(for: .right),
                value: mediaOverlaySide
            )
        }
        .frame(width: compactWidth, height: height)
    }

    private func compactMediaSlotAnimation(
        for side: NotchWingSide
    ) -> Animation {
        guard !reduceMotion else { return .linear(duration: 0.01) }
        if mediaOverlaySide == side {
            return .easeOut(duration: 0.08)
        }
        return .easeIn(duration: 0.10).delay(0.12)
    }

    private var hoverPreview: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: model.menuBarHeight)

            HStack(spacing: 10) {
                hoverCell(for: model.leftWingContent, side: .left)

                hoverDivider

                hoverCenterStatus
                    .frame(width: 42)

                hoverDivider

                hoverCell(for: model.rightWingContent, side: .right)
            }
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func hoverCell(
        for content: NotchWingContent,
        side: NotchWingSide
    ) -> some View {
        if content == .hidden {
            Color.clear
                .frame(maxWidth: .infinity)
        } else {
            hoverStatus(for: content, side: side)
                .frame(
                    maxWidth: .infinity,
                    alignment: side == .left ? .leading : .trailing
                )
        }
    }

    private var hoverDivider: some View {
        Capsule()
            .fill(.white.opacity(0.1))
            .frame(width: 1, height: 19)
    }

    private var hoverCenterStatus: some View {
        VStack(spacing: 1) {
            if notificationCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "bell.fill")
                    Text("\(notificationCount)")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .font(.system(size: 9, weight: .bold))

                Text("通知")
                    .font(.system(size: 7.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.44))
            } else {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.72))

                Text("点击展开")
                    .font(.system(size: 7.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.44))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .accessibilityLabel("点击展开详细面板")
    }

    @ViewBuilder
    private func hoverStatus(
        for content: NotchWingContent,
        side: NotchWingSide
    ) -> some View {
        switch content {
        case .media:
            HStack(spacing: 7) {
                if side == .left {
                    hoverMediaRing
                }

                VStack(alignment: side == .left ? .leading : .trailing, spacing: 1) {
                    Text(model.media == .idle ? "暂未播放" : model.media.title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                    Text(
                        model.media == .idle
                            ? "正在播放"
                            : (model.media.artist.isEmpty
                                ? model.media.sourceName
                                : model.media.artist)
                    )
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(1)
                }

                if side == .right {
                    hoverMediaRing
                }
            }
            .frame(
                maxWidth: 154,
                alignment: side == .left ? .leading : .trailing
            )

        case .battery:
            HStack(spacing: 7) {
                if side == .left {
                    hoverBatteryRing
                }

                VStack(alignment: side == .left ? .leading : .trailing, spacing: 0) {
                    Text("\(model.power.batteryPercent)%")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(hoverBatteryDetail)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.48))
                }

                if side == .right {
                    hoverBatteryRing
                }
            }

        case .codex:
            switch model.codexDisplayMode {
            case .weekly:
                hoverCodexLimitsStatus(side: side)
            case .balance:
                hoverBalanceCodexStatus(side: side)
            }

        case .hidden:
            EmptyView()
        }
    }

    private func hoverCodexLimitsStatus(side: NotchWingSide) -> some View {
        HStack(spacing: 7) {
            if !model.codexQuotaLimits.isEmpty {
                if side == .left {
                    hoverCodexQuotaRings
                }

                VStack(alignment: side == .left ? .leading : .trailing, spacing: 0) {
                    if let fiveHour = model.fiveHourCodexLimit {
                        Text("5 小时 \(Int(fiveHour.remainingPercent.rounded()))%")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    if let weekly = model.weeklyCodexLimit,
                       weekly.id != model.fiveHourCodexLimit?.id {
                        Text("周额度 \(Int(weekly.remainingPercent.rounded()))%")
                            .font(.system(size: 8.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.56))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }

                if side == .right {
                    hoverCodexQuotaRings
                }
            } else {
                if side == .left {
                    hoverCodexFallbackIcon
                }
                Text("正在连接")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
                if side == .right {
                    hoverCodexFallbackIcon
                }
            }
        }
    }

    private func hoverBalanceCodexStatus(side: NotchWingSide) -> some View {
        let balance = CodexBalancePresentation(
            credits: model.codexCredits,
            healthMessage: model.codexHealth.message
        )

        return HStack(spacing: 7) {
            if side == .left {
                hoverCodexBalanceRing
            }

            VStack(alignment: side == .left ? .leading : .trailing, spacing: 0) {
                Text(balance.estimatedUSDLabel)
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .contentTransition(.numericText())
                Text(balance.creditsLabel)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            if side == .right {
                hoverCodexBalanceRing
            }
        }
        .help(balance.accessibilityLabel)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(balance.accessibilityLabel)
    }

    private var hoverMediaRing: some View {
        AttentionRing(
            model: model,
            diameter: 20
        ) {
            MediaProgressRing(
                snapshot: model.media,
                style: model.ringAppearance.style(for: .media),
                diameter: 20,
                lineWidth: 2.6
            )
        }
    }

    private var hoverBatteryRing: some View {
        AttentionRing(
            model: model,
            diameter: 20
        ) {
            UsageArc(
                progress: Double(model.power.batteryPercent) / 100,
                style: model.ringAppearance.style(for: .battery),
                lineWidth: 2.6
            )
        }
    }

    private var hoverCodexQuotaRings: some View {
        AttentionRing(
            model: model,
            diameter: 20
        ) {
            ZStack {
                UsageArc(
                    progress: model.fiveHourCodexLimit?.remainingFraction ?? 0,
                    style: model.ringAppearance.style(for: .codex),
                    lineWidth: 2.2
                )

                if let weekly = model.weeklyCodexLimit,
                   weekly.id != model.fiveHourCodexLimit?.id {
                    UsageArc(
                        progress: weekly.remainingFraction,
                        style: model.ringAppearance.style(for: .codex),
                        lineWidth: 1.6
                    )
                    .frame(width: 13, height: 13)
                    .opacity(0.72)
                }
            }
        }
    }

    private var hoverCodexBalanceRing: some View {
        AttentionRing(
            model: model,
            diameter: 20
        ) {
            ZStack {
                UsageArc(
                    progress: 1,
                    style: model.ringAppearance.style(for: .codex),
                    lineWidth: 2.6
                )

                Image(systemName: "dollarsign")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
            }
        }
    }

    private var hoverCodexFallbackIcon: some View {
        Image(systemName: "gauge.with.dots.needle.67percent")
            .font(.system(size: 11, weight: .semibold))
    }

    private var hoverBatteryDetail: String {
        if let chargingWatts = model.power.chargingWatts {
            return String(format: "充电 %.1f W", chargingWatts)
        }
        if model.power.isExternalPowerConnected {
            return "已连接电源"
        }
        return "电池供电"
    }
}

struct CodexBalancePresentation: Equatable {
    enum State: Equatable {
        case connecting(message: String)
        case unlimited
        case unavailable
        case unknown
        case available(estimatedUSD: Decimal, credits: Decimal)
    }

    let state: State

    init(credits: CodexCreditsBalance?, healthMessage: String) {
        guard let credits else {
            let message = healthMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            state = .connecting(
                message: message.isEmpty ? "正在连接 Codex" : message
            )
            return
        }

        if credits.unlimited {
            state = .unlimited
        } else if !credits.hasCredits {
            state = .unavailable
        } else if let value = credits.credits,
                  let estimatedUSD = credits.estimatedUSD {
            state = .available(
                estimatedUSD: estimatedUSD,
                credits: value
            )
        } else {
            state = .unknown
        }
    }

    var estimatedUSDLabel: String {
        switch state {
        case .connecting:
            return "正在连接"
        case .unlimited:
            return "无限"
        case .unavailable:
            return "不可用"
        case .unknown:
            return "余额未知"
        case .available(let value, _):
            let formatted = Self.usdFormatter.string(
                from: NSDecimalNumber(decimal: value)
            ) ?? "US$—"
            return "≈ " + formatted
        }
    }

    var creditsLabel: String {
        switch state {
        case .connecting(let message):
            return message
        case .unlimited:
            return "credits 无上限"
        case .unavailable:
            return "账户未启用 credits"
        case .unknown:
            return "credits 暂未返回"
        case .available(_, let value):
            let formatted = Self.creditsFormatter.string(
                from: NSDecimalNumber(decimal: value)
            ) ?? "—"
            return formatted + " credits"
        }
    }

    var hint: String {
        switch state {
        case .available:
            return "按 25 credits ≈ US$1"
        default:
            return "来自本机 Codex 会话"
        }
    }

    var accessibilityLabel: String {
        "Codex 余额，" + estimatedUSDLabel + "，" + creditsLabel
    }

    private static let usdFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static let creditsFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter
    }()
}

private struct FileDropTargetContent: View {
    let acceptance: FileDropAcceptance

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.14), in: .rect(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 38)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch acceptance {
        case .accepted:
            return "tray.and.arrow.down.fill"
        case .partial:
            return "exclamationmark.triangle.fill"
        case .rejected:
            return "circle.slash"
        }
    }

    private var tint: Color {
        switch acceptance {
        case .accepted:
            return .mint
        case .partial:
            return .yellow
        case .rejected:
            return .red
        }
    }

    private var title: String {
        switch acceptance {
        case .accepted(let count):
            return "松手加入 \(count) 项"
        case .partial(let acceptedCount, let rejectedCount, _):
            return "\(acceptedCount) 项可加入 · \(rejectedCount) 项跳过"
        case .rejected:
            return "不能加入暂存架"
        }
    }

    private var subtitle: String {
        switch acceptance {
        case .accepted:
            return "只保存引用，不会移动或复制原文件"
        case .partial(_, _, let reason), .rejected(_, let reason):
            return reason
        }
    }
}

private struct CompactCodexContent: View {
    @ObservedObject var model: AppModel
    let limits: [CodexLimitBucket]
    let health: ServiceHealth
    let style: RingStyle

    private var fiveHour: CodexLimitBucket? {
        AppModel.fiveHourCodexLimit(from: limits)
    }

    private var weekly: CodexLimitBucket? {
        AppModel.weeklyCodexLimit(from: limits)
    }

    private var balance: CodexBalancePresentation {
        CodexBalancePresentation(
            credits: model.codexCredits,
            healthMessage: health.message
        )
    }

    var body: some View {
        AttentionRing(
            model: model,
            diameter: 22
        ) {
            switch model.codexDisplayMode {
            case .weekly:
                ZStack {
                    UsageArc(
                        progress: fiveHour?.remainingFraction ?? 0,
                        style: style,
                        lineWidth: 2.7
                    )

                    if let weekly, weekly.id != fiveHour?.id {
                        UsageArc(
                            progress: weekly.remainingFraction,
                            style: style,
                            lineWidth: 1.8
                        )
                        .frame(width: 14, height: 14)
                        .opacity(0.72)
                    }
                }
            case .balance:
                ZStack {
                    UsageArc(
                        progress: 1,
                        style: style,
                        lineWidth: 3.2
                    )

                    Image(systemName: "dollarsign")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                }
            }
        }
        .foregroundStyle(.white)
        .animation(NotchDesign.Motion.value, value: fiveHour?.remainingPercent)
        .animation(NotchDesign.Motion.value, value: weekly?.remainingPercent)
        .animation(NotchDesign.Motion.value, value: model.codexDisplayMode)
        .help(helpLabel)
        .accessibilityLabel(
            accessibilityLabel
        )
    }

    private var helpLabel: String {
        switch model.codexDisplayMode {
        case .weekly:
            return quotaLabel(separator: " · ")
        case .balance:
            return balance.accessibilityLabel + " · " + balance.hint
        }
    }

    private var accessibilityLabel: String {
        switch model.codexDisplayMode {
        case .weekly:
            return quotaLabel(separator: "，")
        case .balance:
            return balance.accessibilityLabel
        }
    }

    private func quotaLabel(separator: String) -> String {
        let labels = [
            fiveHour.map { "5 小时剩余 \(Int($0.remainingPercent.rounded()))%" },
            weekly.flatMap { bucket in
                bucket.id == fiveHour?.id
                    ? nil
                    : "周额度剩余 \(Int(bucket.remainingPercent.rounded()))%"
            }
        ].compactMap { $0 }

        guard !labels.isEmpty else {
            return "ChatGPT 与 Codex 限额" + separator + health.message
        }
        return "ChatGPT 与 Codex " + labels.joined(separator: separator)
    }

}

private struct ExpandedPanelSurface: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    var body: some View {
        ExpandedPanel(model: model)
            .environment(\.appearsActive, true)
            .nativeLiquidGlassSurface(
                level: model.liquidGlassLevel,
                cornerRadius: NotchDesign.Radius.panel,
                samplesDesktopBackdrop: true
            )
            .opacity(isVisible ? 1 : 0)
            .offset(y: reduceMotion || isVisible ? 0 : 8)
            .task {
                await Task.yield()
                guard !model.isPanelClosing else { return }
                withAnimation(reduceMotion ? .linear(duration: 0.12) : NotchDesign.Motion.panelOpen) {
                    isVisible = true
                }
            }
            .onChange(of: model.isPanelClosing) { _, closing in
                if closing {
                    withAnimation(
                        reduceMotion
                            ? .linear(duration: 0.12)
                            : NotchDesign.Motion.panelClose
                    ) {
                        isVisible = false
                    }
                } else if model.isExpanded {
                    withAnimation(
                        reduceMotion
                            ? .linear(duration: 0.12)
                            : NotchDesign.Motion.panelOpen
                    ) {
                        isVisible = true
                    }
                }
            }
            .allowsHitTesting(!model.isPanelClosing)
    }
}

private struct ExpandedPanel: View {
    private enum Layout {
        static let outerInset = NotchDesign.Spacing.panelInset
        static let sectionSpacing = NotchDesign.Spacing.section
        static let columnSpacing: CGFloat = 12
        static let secondaryColumnWidth: CGFloat = 176
        static let upperContentHeight: CGFloat = 288
    }

    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmClearNotifications = false
    @State private var confirmEmptyTrash = false

    private var notificationCount: Int {
        model.notificationSources.reduce(0) { $0 + $1.count }
    }

    var body: some View {
        VStack(spacing: Layout.sectionSpacing) {
            header

            Group {
                if model.updateStatus.isInstallingUpdate {
                    updateProgressCard
                        .frame(maxWidth: 380)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                } else if model.workspaceSection == .power {
                    PowerDashboardView(model: model)
                        .transition(.opacity)
                } else if model.workspaceSection == .notifications {
                    triageDashboard
                        .transition(.opacity)
                } else if model.workspaceSection == .shelf {
                    FileShelfView(model: model)
                        .transition(.opacity)
                } else {
                    ClipboardHistoryView(model: model)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(Layout.outerInset)
        .frame(
            width: NotchLayout.expandedPanelWidth,
            height: NotchLayout.expandedPanelHeight
        )
        .animation(
            reduceMotion ? .linear(duration: 0.10) : NotchDesign.Motion.sectionChange,
            value: model.workspaceSection
        )
        .animation(
            reduceMotion ? .linear(duration: 0.10) : NotchDesign.Motion.sectionChange,
            value: model.updateStatus.isInstallingUpdate
        )
        .overlay {
            if let prompt = model.updatePrompt,
               let release = prompt.release,
               model.panelState.isPresentingReleaseUpdatePrompt,
               !model.updateStatus.isBusy {
                UpdateAvailableOverlay(
                    release: release,
                    onInstall: {
                        model.installPresentedUpdate(release)
                    },
                    onDismiss: {
                        model.dismissUpdatePrompt()
                    }
                )
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.97))
                )
                .zIndex(10)
            }
        }
        .confirmationDialog(
            "清除系统通知中心中的全部通知？",
            isPresented: $confirmClearNotifications
        ) {
            Button("清除全部通知", role: .destructive) {
                model.clearAllNotifications()
            }
        }
        .confirmationDialog(
            "清空废纸篓？此操作无法撤销。",
            isPresented: $confirmEmptyTrash
        ) {
            Button("清空废纸篓", role: .destructive) {
                model.emptyTrash()
            }
        }
        .alert(item: nonReleaseUpdatePrompt) { prompt in
            if prompt.recovery == .resetAccessibility {
                return Alert(
                    title: Text(prompt.title),
                    message: Text(prompt.message),
                    primaryButton: .destructive(Text("重置并重新授权")) {
                        model.repairAccessibilityAuthorization()
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
            return Alert(
                title: Text(prompt.title),
                message: Text(prompt.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    private var nonReleaseUpdatePrompt: Binding<AppUpdatePrompt?> {
        Binding(
            get: {
                guard let prompt = model.updatePrompt, prompt.release == nil else {
                    return nil
                }
                return prompt
            },
            set: { newValue in
                guard newValue == nil,
                      model.updatePrompt?.release == nil else { return }
                model.updatePrompt = nil
            }
        )
    }

    private var updateProgressCard: some View {
        let progress = model.updateDownloadProgress
        let fraction = progress?.fraction ?? 0
        let isInstalling: Bool = {
            if case .installing = model.updateStatus { return true }
            return false
        }()
        let isVerifying = !isInstalling && fraction >= 0.999
        let title = isInstalling
            ? "正在安装更新"
            : (isVerifying ? "正在验证更新" : "正在下载更新")
        let detail = isInstalling
            ? "验证完成，正在安全替换应用并准备重启"
            : (isVerifying
                ? "正在验证签名与完整性"
                : "下载完成后会自动验证并重启")

        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isInstalling ? "checkmark.shield" : "arrow.down.circle")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                    Text(model.updateStatus.activeUpdateVersion.map { "Notch Triage v\($0)" } ?? "Notch Triage")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if !isInstalling {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: fraction))
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            ProgressView(value: isInstalling ? 1 : fraction)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .animation(
                    reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.16),
                    value: fraction
                )

            HStack(spacing: 6) {
                if let progress {
                    Text("\(Self.byteCount(progress.receivedBytes)) / \(Self.byteCount(progress.totalBytes))")
                    Spacer(minLength: 8)
                    Text(detail)
                } else {
                    Text(detail)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(20)
        .frame(maxWidth: 380, alignment: .leading)
        .panelGroupSurface(cornerRadius: 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(isInstalling ? detail : "百分之\(Int((fraction * 100).rounded()))，\(detail)")
    }

    private static func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: model.workspaceSection.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                Text(model.workspaceSection.title)
                    .font(.system(size: 14, weight: .semibold))

                if model.workspaceSection == .notifications,
                   notificationCount > 0 {
                    Text("\(notificationCount)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.primary.opacity(0.1), in: Capsule())
                }
            }
            .frame(width: 88, alignment: .leading)

            Spacer(minLength: 8)

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Picker("工作区", selection: workspaceSectionBinding) {
                        ForEach(WorkspaceSection.allCases) { section in
                            Label(section.title, systemImage: section.symbol)
                                .tag(section)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 300)

                    Button {
                        model.openSettings()
                    } label: {
                        Image(systemName: "gearshape")
                            .frame(width: 26, height: 26)
                            .contentShape(Circle())
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .help("打开设置")
                    .accessibilityLabel("打开设置")
                }
            }
            .disabled(
                model.updateStatus.isBusy
                    || model.panelState.blocksOrdinaryPanelInput
            )
        }
        .frame(height: 28)
    }

    private var workspaceSectionBinding: Binding<WorkspaceSection> {
        Binding(
            get: { model.workspaceSection },
            set: { model.setWorkspaceSection($0) }
        )
    }

    private var triageDashboard: some View {
        VStack(spacing: NotchDesign.Spacing.group) {
            HStack(alignment: .top, spacing: Layout.columnSpacing) {
                NotificationInbox(
                    model: model,
                    confirmClear: $confirmClearNotifications
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: NotchDesign.Spacing.group) {
                    CodexUsageCard(model: model)
                    TrashCompactCard(
                        model: model,
                        confirmEmptyTrash: $confirmEmptyTrash
                    )
                    Spacer(minLength: 0)
                }
                .frame(width: Layout.secondaryColumnWidth)
                .frame(maxHeight: .infinity)
            }
            .frame(height: Layout.upperContentHeight)

            NowPlayingStrip(model: model, snapshot: model.media)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct UpdateAvailableOverlay: View {
    let release: AppRelease
    let onInstall: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var releaseNotes: String {
        release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.16)
                .contentShape(Rectangle())

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "arrow.down.app")
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 30, height: 30)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("有新的版本可用")
                            .font(.system(size: 17, weight: .semibold))
                        Text("Notch Triage \(release.displayVersion)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)
                }

                if !releaseNotes.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("更新内容")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ScrollView {
                            Text(releaseNotes)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 116)
                    }
                }

                Text("安装前会验证签名与完整性，完成后自动重启应用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("稍后") {
                        onDismiss()
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)

                    Spacer(minLength: 8)

                    Button("安装并重启") {
                        onInstall()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(22)
            .frame(maxWidth: 390, alignment: .leading)
            .glassEffect(
                .regular,
                in: .rect(cornerRadius: NotchDesign.Radius.panel)
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: NotchDesign.Radius.panel,
                    style: .continuous
                )
                .stroke(.white.opacity(0.12), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.24), radius: 22, y: 12)
            .transition(
                reduceMotion
                    ? .opacity
                    : .opacity.combined(with: .scale(scale: 0.97))
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}

private struct NotificationInbox: View {
    @ObservedObject var model: AppModel
    @Binding var confirmClear: Bool

    var body: some View {
        VStack(spacing: 0) {
            if model.notificationSources.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("没有待处理通知")
                        .font(.system(size: 13, weight: .medium))
                    Text(emptyDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.notificationSources) { source in
                            NotificationSourceRow(source: source)
                        }
                    }
                    .padding(6)
                }
            }

            Divider()
                .opacity(0.45)

            HStack {
                StatusDot(health: model.notificationHealth)

                Text(model.autoDismissBanners ? "横幅自动收起" : "横幅保持原样")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                if !model.notificationSources.isEmpty {
                    Button("清除全部", role: .destructive) {
                        confirmClear = true
                    }
                    .buttonStyle(.plain)
                    .font(.caption2.weight(.medium))
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 35)
        }
        .panelGroupSurface()
    }

    private var emptyDetail: String {
        switch model.notificationHealth {
        case .warning, .failed:
            return "授权辅助功能后，来源会显示在这里"
        default:
            return "通知内容仍由系统通知中心保存"
        }
    }
}

private struct NotificationSourceRow: View {
    let source: NotificationSource

    var body: some View {
        HStack(spacing: 10) {
            SourceIcon(
                bundleIdentifier: source.bundleIdentifier,
                fallback: "app.badge"
            )
            .frame(width: 28, height: 28)

            Text(source.sourceName)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)

            Spacer()

            Text("\(source.count)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .contentShape(RoundedRectangle(cornerRadius: 11))
    }
}

private struct CodexUsageCard: View {
    @ObservedObject var model: AppModel

    private var fiveHour: CodexLimitBucket? {
        model.fiveHourCodexLimit
    }

    private var weekly: CodexLimitBucket? {
        model.weeklyCodexLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Codex")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Button {
                    model.refreshCodex()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("刷新用量")
            }

            Picker("Codex 显示", selection: $model.codexDisplayMode) {
                Text("限额").tag(AppModel.CodexDisplayMode.weekly)
                Text("余额").tag(AppModel.CodexDisplayMode.balance)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.mini)

            Group {
                switch model.codexDisplayMode {
                case .weekly:
                    limitsContent
                case .balance:
                    balanceContent
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 154, alignment: .topLeading)
        .panelGroupSurface()
    }

    private var limitsContent: some View {
        HStack(spacing: 8) {
            quotaColumn(title: "5 小时", bucket: fiveHour)

            if let weekly, weekly.id != fiveHour?.id {
                Divider()
                    .frame(height: 52)
                quotaColumn(title: "周额度", bucket: weekly)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(quotaAccessibilityLabel)
    }

    private func quotaColumn(
        title: String,
        bucket: CodexLimitBucket?
    ) -> some View {
        VStack(spacing: 3) {
            ZStack {
                UsageArc(
                    progress: bucket?.remainingFraction ?? 0,
                    style: model.ringAppearance.style(for: .codex),
                    lineWidth: 3
                )

                Text(percentLabel(for: bucket))
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 38, height: 38)

            Text(title)
                .font(.system(size: 9.5, weight: .semibold))

            Text(resetLabel(for: bucket))
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var balanceContent: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(.tint.opacity(0.14))
                Circle()
                    .stroke(.tint.opacity(0.42), lineWidth: 1)
                Image(systemName: "dollarsign")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tint)
            }
            .frame(width: 45, height: 45)

            VStack(alignment: .leading, spacing: 3) {
                Text(estimatedUSDLabel)
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(creditsLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(balanceHint)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Codex credits 余额，\(estimatedUSDLabel)，\(creditsLabel)")
    }

    private var balancePresentation: CodexBalancePresentation {
        CodexBalancePresentation(
            credits: model.codexCredits,
            healthMessage: model.codexHealth.message
        )
    }

    private func percentLabel(for bucket: CodexLimitBucket?) -> String {
        guard let bucket else { return "—" }
        return "\(Int(bucket.remainingPercent.rounded()))"
    }

    private func resetLabel(for bucket: CodexLimitBucket?) -> String {
        guard let reset = bucket?.resetsAt else { return "正在连接" }
        return reset.formatted(date: .omitted, time: .shortened) + " 重置"
    }

    private var quotaAccessibilityLabel: String {
        model.codexQuotaLimits.map { bucket in
            "\(bucket.windowLabel)剩余\(Int(bucket.remainingPercent.rounded()))%"
        }
        .joined(separator: "，")
    }

    private var estimatedUSDLabel: String {
        balancePresentation.estimatedUSDLabel
    }

    private var creditsLabel: String {
        balancePresentation.creditsLabel
    }

    private var balanceHint: String {
        balancePresentation.hint
    }

}

private struct TrashCompactCard: View {
    @ObservedObject var model: AppModel
    @Binding var confirmEmptyTrash: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: trashSymbol)
                .font(.system(size: 16, weight: .medium))

            VStack(alignment: .leading, spacing: 1) {
                Text("废纸篓")
                    .font(.system(size: 11.5, weight: .semibold))
                Text(trashStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                model.openTrash()
            } label: {
                Image(systemName: "arrow.up.forward")
            }
            .buttonStyle(.plain)
            .help("打开废纸篓")

            Button {
                confirmEmptyTrash = true
            } label: {
                Image(systemName: "trash.slash")
            }
            .buttonStyle(.plain)
            .help(model.trashCount == nil ? "清空废纸篓（计数不可用）" : "清空废纸篓")
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 66)
        .panelGroupSurface()
    }

    private var trashStatus: String {
        guard let count = model.trashCount else { return "计数不可用" }
        return count == 0 ? "空" : "\(count) 项"
    }

    private var trashSymbol: String {
        guard let count = model.trashCount else { return "trash" }
        return count == 0 ? "trash" : "trash.fill"
    }
}

private struct NowPlayingStrip: View {
    @ObservedObject var model: AppModel
    let snapshot: MediaSnapshot

    var body: some View {
        HStack(spacing: 10) {
            SourceIcon(
                bundleIdentifier: snapshot.bundleIdentifier,
                fallback: "music.note"
            )
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot == .idle ? "暂未播放" : snapshot.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)

                if snapshot != .idle {
                    Text(snapshot.artist.isEmpty ? snapshot.sourceName : snapshot.artist)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if snapshot != .idle {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 10) {
                        Text(snapshot.estimatedElapsed(at: context.date).clockString)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)

                        ProgressView(value: snapshot.progress(at: context.date))
                            .progressViewStyle(.linear)
                            .frame(width: 104)
                    }
                }
            }

            MediaCommandControls(model: model, snapshot: snapshot)
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .panelGroupSurface(cornerRadius: NotchDesign.Radius.compactGroup)
    }
}

private struct MediaCommandControls: View {
    @ObservedObject var model: AppModel
    let snapshot: MediaSnapshot

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MediaCommand.allCases, id: \.rawValue) { command in
                MediaCommandButton(
                    model: model,
                    snapshot: snapshot,
                    command: command
                )
            }
        }
        .padding(3)
        .background(.primary.opacity(0.055), in: Capsule())
        .overlay {
            Capsule()
                .stroke(.primary.opacity(0.07), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("媒体控制")
    }
}

private struct MediaCommandButton: View {
    @ObservedObject var model: AppModel
    let snapshot: MediaSnapshot
    let command: MediaCommand

    private var isEnabled: Bool {
        model.isMediaCommandEnabled(command)
    }

    private var isSending: Bool {
        model.mediaCommandInFlight == command
    }

    private var imageName: String {
        if command == .togglePlayPause {
            return snapshot.isPlaying ? "pause.fill" : "play.fill"
        }
        return command.systemImage
    }

    private var helpText: String {
        if let reason = model.mediaCommandAvailability.disabledReason(for: command) {
            return "\(command.title) · \(reason)"
        }
        return command.title
    }

    var body: some View {
        Button {
            model.sendMediaCommand(command)
        } label: {
            Group {
                if isSending {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.primary)
                } else {
                    Image(systemName: imageName)
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Circle())
            .background {
                Circle()
                    .fill(.primary.opacity(isEnabled ? 0.10 : 0))
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isSending ? 0.76 : (isEnabled ? 1 : 0.34))
        .help(helpText)
        .accessibilityLabel(command.title)
        .accessibilityValue(
            isSending ? "正在发送" : (isEnabled ? "可用" : "不可用")
        )
    }
}

private struct MediaProgressRing: View {
    let snapshot: MediaSnapshot
    let style: RingStyle
    let diameter: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let progress = snapshot.progress(at: context.date)
            ZStack {
                UsageArc(
                    progress: progress,
                    style: style.withOpacity(snapshot.isPlaying ? 1 : 0.64),
                    lineWidth: lineWidth
                )
            }
            .animation(NotchDesign.Motion.value, value: progress)
        }
        .frame(width: diameter, height: diameter)
        .animation(NotchDesign.Motion.value, value: snapshot.isPlaying)
    }
}

private struct UsageArc: View {
    let progress: Double
    let foregroundStyle: AnyShapeStyle
    let lineWidth: CGFloat
    let trackColor: Color

    init(
        progress: Double,
        color: Color,
        lineWidth: CGFloat,
        trackColor: Color = .primary.opacity(0.12)
    ) {
        self.progress = progress
        self.foregroundStyle = AnyShapeStyle(color)
        self.lineWidth = lineWidth
        self.trackColor = trackColor
    }

    init(
        progress: Double,
        style: RingStyle,
        lineWidth: CGFloat
    ) {
        self.progress = progress
        self.foregroundStyle = style.shapeStyle
        self.lineWidth = lineWidth
        self.trackColor = style.track.color
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    foregroundStyle,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(NotchDesign.Motion.value, value: progress)
        }
    }
}

private struct StatusDot: View {
    let health: ServiceHealth

    var body: some View {
        Circle()
            .fill(Color(nsColor: health.color))
            .frame(width: 6, height: 6)
            .help(health.message)
    }
}

private struct SourceIcon: View {
    let bundleIdentifier: String?
    let fallback: String

    var body: some View {
        Group {
            if let image = appIcon {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: fallback)
                    .resizable()
                    .scaledToFit()
                    .padding(3)
            }
        }
    }

    private var appIcon: NSImage? {
        guard let bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
              ) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

private extension TimeInterval {
    var clockString: String {
        guard isFinite, self > 0 else { return "0:00" }
        let total = Int(self.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
