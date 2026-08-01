import AppKit
import SwiftUI

struct NotchRootView: View {
    @ObservedObject var model: AppModel
    private let hoveredNotchHeight: CGFloat = 74

    var body: some View {
        VStack(spacing: 16) {
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
                    hoveredHeight: hoveredNotchHeight
                )
            }
            .buttonStyle(StableNotchButtonStyle())
            .background {
                NotchHoverTracker { hovered in
                    model.setNotchHovered(hovered)
                }
            }
            .offset(x: compactAlignmentOffset)
            .accessibilityLabel(model.isExpanded ? "收起 Notch Triage" : "展开 Notch Triage")
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var compactAlignmentOffset: CGFloat {
        let leftWidth = compactWingWidth(
            for: model.leftWingContent,
            media: model.media
        )
        let rightWidth = compactWingWidth(
            for: model.rightWingContent,
            media: model.media
        )
        return (rightWidth - leftWidth) / 2
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
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> HoverTrackingView {
        let view = HoverTrackingView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: HoverTrackingView, context: Context) {
        nsView.onHover = onHover
    }
}

private final class HoverTrackingView: NSView {
    var onHover: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let hoverArea {
            removeTrackingArea(hoverArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [
                .mouseEnteredAndExited,
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
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }
}

private enum NotchWingSide: Equatable {
    case left
    case right
}

private func compactWingWidth(
    for content: NotchWingContent,
    media: MediaSnapshot
) -> CGFloat {
    switch content {
    case .battery, .codex:
        // The 27 pt ring sits in a 37 pt square slot, leaving roughly
        // 5 pt on every side on the built-in display's 37 pt menu bar.
        return 37
    case .media:
        return media == .idle ? 0 : 170
    case .hidden:
        return 0
    }
}

private struct CompactMediaContent: View {
    let snapshot: MediaSnapshot
    let side: NotchWingSide

    var body: some View {
        HStack(spacing: 7) {
            if side == .right {
                mediaIcon
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.14))
                        Capsule()
                            .fill(.white.opacity(0.84))
                            .frame(width: proxy.size.width * snapshot.progress)
                    }
                }
                .frame(height: 1.5)
            }

            if side == .left {
                mediaIcon
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 170)
        .foregroundStyle(.white)
    }

    private var mediaIcon: some View {
        SourceIcon(
            bundleIdentifier: snapshot.bundleIdentifier,
            fallback: "music.note"
        )
        .frame(width: 18, height: 18)
    }
}

private struct CompactWingSlot: View {
    @ObservedObject var model: AppModel
    let content: NotchWingContent
    let side: NotchWingSide

    var body: some View {
        Group {
            switch content {
            case .battery:
                CompactBatteryContent(snapshot: model.power)
            case .codex:
                CompactCodexContent(
                    limits: model.codexLimits,
                    health: model.codexHealth
                )
            case .media:
                if model.media != .idle {
                    CompactMediaContent(snapshot: model.media, side: side)
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
    let snapshot: PowerSnapshot

    var body: some View {
        ZStack {
            UsageArc(
                progress: Double(snapshot.batteryPercent) / 100,
                color: ringColor,
                lineWidth: 3.2,
                trackColor: .white.opacity(0.16)
            )
        }
        .frame(width: 22, height: 22)
        .foregroundStyle(.white)
        .animation(NotchDesign.Motion.value, value: snapshot.updatedAt)
        .help(batteryHelp)
        .accessibilityLabel(batteryHelp)
    }

    private var ringColor: Color {
        if snapshot.batteryPercent <= 20 { return .red }
        if snapshot.isCharging { return .green }
        if snapshot.isExternalPowerConnected { return .mint }
        return .white.opacity(0.9)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let shoulderRadius: CGFloat = 6

    private var hovering: Bool {
        model.isHoveringNotch
            || model.isExpanded
            || model.isPanelClosing
            || model.systemHUD != nil
    }

    private var leftWidth: CGFloat {
        compactWingWidth(
            for: model.leftWingContent,
            media: model.media
        )
    }

    private var rightWidth: CGFloat {
        compactWingWidth(
            for: model.rightWingContent,
            media: model.media
        )
    }

    private var compactWidth: CGFloat {
        leftWidth + model.notchWidth + rightWidth
    }

    private var width: CGFloat {
        compactWidth + shoulderRadius * 2
    }

    private var height: CGFloat {
        hovering ? hoveredHeight : min(model.menuBarHeight, 40)
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
                .opacity(hovering && model.systemHUD == nil ? 1 : 0)
                .accessibilityHidden(!hovering || model.systemHUD != nil)
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
                content: model.leftWingContent,
                side: .left
            )
            .frame(width: leftWidth, height: height)

            ZStack {
                if let pulse = model.notificationPulse {
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
                content: model.rightWingContent,
                side: .right
            )
            .frame(width: rightWidth, height: height)
        }
        .frame(width: compactWidth, height: height)
    }

    private var hoverPreview: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: model.menuBarHeight)

            HStack(spacing: 10) {
                hoverCell(for: model.leftWingContent)

                hoverDivider

                hoverCenterStatus
                    .frame(width: 42)

                hoverDivider

                hoverCell(for: model.rightWingContent)
            }
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func hoverCell(for content: NotchWingContent) -> some View {
        if content == .hidden {
            Color.clear
                .frame(maxWidth: .infinity)
        } else {
            hoverStatus(for: content)
                .frame(maxWidth: .infinity, alignment: .center)
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

                Text("展开")
                    .font(.system(size: 7.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.44))
            }
        }
    }

    @ViewBuilder
    private func hoverStatus(for content: NotchWingContent) -> some View {
        switch content {
        case .media:
            HStack(spacing: 7) {
                SourceIcon(
                    bundleIdentifier: model.media.bundleIdentifier,
                    fallback: "music.note"
                )
                .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 1) {
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
            }
            .frame(maxWidth: 154, alignment: .leading)

        case .battery:
            HStack(spacing: 7) {
                UsageArc(
                    progress: Double(model.power.batteryPercent) / 100,
                    color: model.power.isCharging ? .green : .white.opacity(0.92),
                    lineWidth: 2.6,
                    trackColor: .white.opacity(0.16)
                )
                .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 0) {
                    Text("\(model.power.batteryPercent)%")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(hoverBatteryDetail)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.48))
                }
            }

        case .codex:
            HStack(spacing: 7) {
                if let primary = model.codexLimits.first {
                    UsageArc(
                        progress: primary.remainingFraction,
                        color: .white.opacity(0.92),
                        lineWidth: 2.6,
                        trackColor: .white.opacity(0.16)
                    )
                    .frame(width: 20, height: 20)

                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(Int(primary.remainingPercent.rounded()))%")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text(primary.windowLabel)
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.48))
                    }
                } else {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 11, weight: .semibold))
                    Text("正在连接")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.48))
                }
            }

        case .hidden:
            EmptyView()
        }
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

private struct SystemHUDContent: View {
    let snapshot: SystemHUDSnapshot
    let menuBarHeight: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentVisible = false

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: menuBarHeight)

            Group {
                if snapshot.kind == .airPods {
                    airPodsContent
                } else {
                    levelContent
                }
            }
            .padding(.horizontal, 24)
            .frame(maxHeight: .infinity)
            .opacity(contentVisible ? 1 : 0)
            .offset(y: reduceMotion || contentVisible ? 0 : -3)
        }
        .foregroundStyle(.white)
        .onAppear {
            withAnimation(reduceMotion ? .linear(duration: 0.12) : NotchDesign.Motion.panelOpen) {
                contentVisible = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(snapshot.title)，\(snapshot.subtitle)")
    }

    private var levelContent: some View {
        HStack(spacing: 12) {
            systemIcon

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(snapshot.title)
                        .font(.system(size: 10.5, weight: .bold))
                    Spacer(minLength: 8)
                    Text(snapshot.subtitle)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                AnimatedLevelBar(
                    value: snapshot.value ?? 0,
                    gradient: levelGradient
                )
                .frame(height: 4.5)
            }
        }
    }

    private var airPodsContent: some View {
        HStack(spacing: 11) {
            systemIcon

            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(snapshot.subtitle)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer(minLength: 8)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var systemIcon: some View {
        switch snapshot.kind {
        case .volume:
            Image(systemName: snapshot.symbol)
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(systemIconColor)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(
                    .wiggle.forward.byLayer,
                    options: .nonRepeating.speed(1.18),
                    value: snapshot.subtitle
                )
                .frame(width: 22, height: 27)

        case .brightness:
            Image(systemName: snapshot.symbol)
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(systemIconColor)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(
                    .breathe.pulse.byLayer,
                    options: .nonRepeating.speed(1.15),
                    value: snapshot.subtitle
                )
                .frame(width: 22, height: 27)

        case .airPods:
            Image(systemName: snapshot.symbol)
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(systemIconColor)
                .symbolEffect(
                    .breathe.pulse.byLayer,
                    options: .nonRepeating.speed(1.05),
                    value: snapshot.id
                )
                .frame(width: 22, height: 27)
        }
    }

    private var levelGradient: LinearGradient {
        switch snapshot.kind {
        case .volume:
            return LinearGradient(
                colors: [
                    Color(red: 0.30, green: 0.48, blue: 1.00),
                    Color(red: 0.20, green: 0.82, blue: 1.00)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        case .brightness:
            return LinearGradient(
                colors: [
                    Color(red: 1.00, green: 0.48, blue: 0.08),
                    Color(red: 1.00, green: 0.87, blue: 0.18)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        case .airPods:
            return LinearGradient(
                colors: [.cyan, .mint],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private var systemIconColor: Color {
        snapshot.kind == .airPods ? .cyan : .white.opacity(0.94)
    }

}

private struct AnimatedLevelBar: View {
    let value: Double
    let gradient: LinearGradient
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedValue = 0.0

    private var normalizedValue: Double {
        max(0, min(1, value))
    }

    var body: some View {
        GeometryReader { proxy in
            let filledWidth = displayedValue > 0
                ? max(proxy.size.height, proxy.size.width * displayedValue)
                : 0

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.white.opacity(0.14))

                Capsule(style: .continuous)
                    .fill(gradient)
                    .frame(width: filledWidth)
            }
        }
        .onAppear {
            displayedValue = reduceMotion ? normalizedValue : 0
            withAnimation(reduceMotion ? .linear(duration: 0.01) : NotchDesign.Motion.panelOpen) {
                displayedValue = normalizedValue
            }
        }
        .onChange(of: value) { _, _ in
            withAnimation(reduceMotion ? .linear(duration: 0.01) : NotchDesign.Motion.value) {
                displayedValue = normalizedValue
            }
        }
    }
}

private struct CompactCodexContent: View {
    let limits: [CodexLimitBucket]
    let health: ServiceHealth

    private var primary: CodexLimitBucket? { limits.first }

    var body: some View {
        ZStack {
            UsageArc(
                progress: primary?.remainingFraction ?? 0,
                color: meterColor,
                lineWidth: 3.2,
                trackColor: .white.opacity(0.16)
            )
        }
        .frame(width: 22, height: 22)
        .foregroundStyle(.white)
        .animation(NotchDesign.Motion.value, value: primary?.remainingPercent)
        .help(exactLabel + " · " + (primary?.windowLabel ?? health.message))
        .accessibilityLabel(
            "ChatGPT 与 Codex 剩余额度 "
                + exactLabel
                + "，"
                + (primary?.windowLabel ?? health.message)
        )
    }

    private var exactLabel: String {
        guard let primary else { return "—" }
        return "\(Int(primary.remainingPercent.rounded()))%"
    }

    private var meterColor: Color {
        guard let primary else { return .gray }
        switch primary.remainingPercent {
        case ..<15: return .red
        case ..<35: return .orange
        default: return .white.opacity(0.92)
        }
    }
}

private struct ExpandedPanelSurface: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    var body: some View {
        ExpandedPanel(model: model)
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
            .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
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
                guard closing else { return }
                withAnimation(reduceMotion ? .linear(duration: 0.12) : NotchDesign.Motion.panelClose) {
                    isVisible = false
                }
            }
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

    private enum Section: Hashable {
        case power
        case triage
    }

    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmClearNotifications = false
    @State private var confirmEmptyTrash = false
    @State private var section: Section = .power

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
                } else if section == .power {
                    PowerDashboardView(model: model)
                        .transition(.opacity)
                } else {
                    triageDashboard
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(Layout.outerInset)
        .frame(width: 520, height: 460)
        .animation(
            reduceMotion ? .linear(duration: 0.10) : NotchDesign.Motion.sectionChange,
            value: section
        )
        .animation(
            reduceMotion ? .linear(duration: 0.10) : NotchDesign.Motion.sectionChange,
            value: model.updateStatus.isInstallingUpdate
        )
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
        .alert(item: $model.updatePrompt) { prompt in
            if let release = prompt.release {
                return Alert(
                    title: Text(prompt.title),
                    message: Text(prompt.message),
                    primaryButton: .default(Text("安装并重启")) {
                        model.installUpdate(release)
                    },
                    secondaryButton: .cancel(Text("稍后"))
                )
            }
            return Alert(
                title: Text(prompt.title),
                message: Text(prompt.message),
                dismissButton: .default(Text("好"))
            )
        }
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
            ? "正在安装并准备重启"
            : (isVerifying ? "正在验证更新" : "正在下载更新")
        let symbol = isInstalling || isVerifying
            ? "checkmark.shield.fill"
            : "arrow.down.circle.fill"

        return VStack(spacing: 14) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.tint)
                    .contentTransition(.symbolEffect(.replace))

                Text(title)
                    .font(.system(size: 15, weight: .semibold))

                Text(model.updateStatus.activeUpdateVersion.map { "Notch Triage v\($0)" } ?? "Notch Triage")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.primary.opacity(0.09))

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.cyan, .blue, .indigo],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(
                            width: proxy.size.width * (isInstalling ? 1 : fraction)
                        )
                }
            }
            .frame(height: 5)
            .animation(
                reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.16),
                value: fraction
            )

            HStack {
                if let progress {
                    Text(Self.byteCount(progress.receivedBytes))
                    Spacer()
                    Text(Self.byteCount(progress.totalBytes))
                    Text("·")
                    Text("\(Int((fraction * 100).rounded()))%")
                        .contentTransition(.numericText(value: fraction))
                } else {
                    Text(isInstalling ? "正在安全替换应用程序" : "正在准备下载")
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)

            Text(isInstalling || isVerifying
                ? "签名与完整性验证通过后会自动重启"
                : "下载期间可以继续查看进度，请勿退出应用")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .panelGroupSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(isInstalling ? "" : "百分之\(Int((fraction * 100).rounded()))")
    }

    private static func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: section == .power ? "bolt.fill" : "bell.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                Text(section == .power ? "电源" : "通知")
                    .font(.system(size: 14, weight: .semibold))

                Text("\(notificationCount)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.primary.opacity(0.1), in: Capsule())
                    .opacity(section == .triage && notificationCount > 0 ? 1 : 0)
                    .accessibilityHidden(section != .triage || notificationCount == 0)
            }
            .frame(width: 104, alignment: .leading)

            Spacer(minLength: 8)

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Picker("面板", selection: $section) {
                        Image(systemName: "bolt.fill")
                            .accessibilityLabel("电源")
                            .tag(Section.power)
                        Image(systemName: "bell.fill")
                            .accessibilityLabel("通知")
                            .tag(Section.triage)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 78)

                    settingsMenu
                }
            }
        }
        .frame(height: 28)
    }

    private var settingsMenu: some View {
        Menu {
            Menu {
                wingChoices(selected: model.leftWingContent) { content in
                    model.setLeftWingContent(content)
                }
            } label: {
                Label(
                    "左侧显示：\(model.leftWingContent.title)",
                    systemImage: "rectangle.leadinghalf.inset.filled"
                )
            }

            Menu {
                wingChoices(selected: model.rightWingContent) { content in
                    model.setRightWingContent(content)
                }
            } label: {
                Label(
                    "右侧显示：\(model.rightWingContent.title)",
                    systemImage: "rectangle.trailinghalf.inset.filled"
                )
            }

            Button {
                model.swapWingContents()
            } label: {
                Label("左右互换", systemImage: "arrow.left.arrow.right")
            }

            Button {
                model.resetWingContents()
            } label: {
                Label("恢复默认显示", systemImage: "arrow.counterclockwise")
            }

            Divider()

            Button {
                model.handleUpdateMenuAction()
            } label: {
                Label(model.updateStatus.menuTitle, systemImage: model.updateStatus.symbol)
            }
            .disabled(model.updateStatus.isBusy)

            Button {
                model.autoDismissBanners.toggle()
            } label: {
                Label(
                    model.autoDismissBanners ? "停止自动收起横幅" : "自动收起横幅",
                    systemImage: model.autoDismissBanners
                        ? "rectangle.slash"
                        : "rectangle.compress.vertical"
                )
            }

            Button {
                model.requestAccessibility()
            } label: {
                Label("辅助功能权限", systemImage: "hand.raised")
            }

            Divider()

            Button(role: .destructive) {
                model.quitApplication()
            } label: {
                Label("退出 Notch Triage", systemImage: "power")
            }
        } label: {
            Image(systemName: "gearshape")
                .frame(width: 26, height: 26)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("设置与更新")
        .accessibilityLabel("设置与更新")
    }

    @ViewBuilder
    private func wingChoices(
        selected: NotchWingContent,
        onSelect: @escaping (NotchWingContent) -> Void
    ) -> some View {
        ForEach(NotchWingContent.allCases) { content in
            Button {
                onSelect(content)
            } label: {
                Label(
                    content.title,
                    systemImage: selected == content
                        ? "checkmark"
                        : content.symbol
                )
            }
        }
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

            NowPlayingStrip(snapshot: model.media)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

    private var primary: CodexLimitBucket? {
        model.codexLimits.first
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

            HStack(spacing: 12) {
                ZStack {
                    UsageArc(
                        progress: primary?.remainingFraction ?? 0,
                        color: usageColor,
                        lineWidth: 4
                    )

                    Text(percentLabel)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                .frame(width: 53, height: 53)

                VStack(alignment: .leading, spacing: 3) {
                    Text(primary?.windowLabel ?? "正在连接")
                        .font(.system(size: 11, weight: .semibold))
                    Text("剩余额度")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if let reset = primary?.resetsAt {
                        Text(reset.formatted(date: .omitted, time: .shortened))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        .panelGroupSurface()
    }

    private var percentLabel: String {
        guard let primary else { return "—" }
        return "\(Int(primary.remainingPercent.rounded()))"
    }

    private var usageColor: Color {
        guard let primary else { return .secondary }
        switch primary.remainingPercent {
        case ..<15: return .red
        case ..<35: return .orange
        default: return .primary
        }
    }
}

private struct TrashCompactCard: View {
    @ObservedObject var model: AppModel
    @Binding var confirmEmptyTrash: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: model.trashCount == 0 ? "trash" : "trash.fill")
                .font(.system(size: 16, weight: .medium))

            VStack(alignment: .leading, spacing: 1) {
                Text("废纸篓")
                    .font(.system(size: 11.5, weight: .semibold))
                Text(model.trashCount == 0 ? "空" : "\(model.trashCount) 项")
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
            .disabled(model.trashCount == 0)
            .help("清空废纸篓")
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 66)
        .panelGroupSurface()
    }
}

private struct NowPlayingStrip: View {
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
                Text(snapshot.elapsed.clockString)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                ProgressView(value: snapshot.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 104)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .panelGroupSurface(cornerRadius: NotchDesign.Radius.compactGroup)
    }
}

private struct UsageArc: View {
    let progress: Double
    let color: Color
    let lineWidth: CGFloat
    let trackColor: Color

    init(
        progress: Double,
        color: Color,
        lineWidth: CGFloat,
        trackColor: Color = .primary.opacity(0.12)
    ) {
        self.progress = progress
        self.color = color
        self.lineWidth = lineWidth
        self.trackColor = trackColor
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    color,
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
