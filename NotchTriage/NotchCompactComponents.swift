import AppKit
import SwiftUI

struct AttentionRing<Content: View>: View {
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

struct NotificationPrompt: View {
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

struct CompactMediaContent: View {
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

struct CompactMediaTransportControls: View {
    @ObservedObject var model: AppModel
    let snapshot: MediaSnapshot
    let side: NotchWingSide
    let isRevealed: Bool
    let reduceMotion: Bool

    var body: some View {
        CompactMediaTransportSurface(
            side: side,
            isRevealed: isRevealed,
            reduceMotion: reduceMotion
        ) { command in
            CompactMediaTransportButton(
                model: model,
                snapshot: snapshot,
                command: command
            )
        }
    }
}

// The live controls and settings demonstration share their geometry and
// animation. Only the live wrapper sends commands to the media source.
struct CompactMediaTransportSurface<Control: View>: View {
    let side: NotchWingSide
    let isRevealed: Bool
    let reduceMotion: Bool
    @ViewBuilder var control: (MediaCommand) -> Control

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
            CompactWingRevealShape(
                side: side,
                progress: isRevealed ? 1 : 0
            )
            .fill(.black)
            .opacity(isRevealed ? 1 : 0)
            .animation(revealAnimation, value: isRevealed)

            HStack(spacing: 8) {
                ForEach(Array(commands.enumerated()), id: \.element.rawValue) { index, command in
                    control(command)
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

private struct CompactWingRevealShape: Shape {
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

    private var helpText: String {
        let title = model.localized(command.title)
        if let reason = model.mediaCommandAvailability.disabledReason(for: command) {
            return "\(title) · \(model.localized(reason))"
        }
        return title
    }

    var body: some View {
        Button {
            model.sendMediaCommand(command)
        } label: {
            CompactMediaTransportLabel(
                snapshot: snapshot,
                style: model.ringAppearance.style(for: .media),
                command: command,
                isSending: isSending
            )
        }
        .buttonStyle(CompactMediaTransportButtonStyle())
        .disabled(!isEnabled)
        .opacity(isSending ? 0.78 : (isEnabled ? 1 : 0.34))
        .help(helpText)
        .accessibilityLabel(model.localized(command.title))
        .accessibilityValue(
            model.localized(isSending ? "正在发送" : (isEnabled ? "可用" : "不可用"))
        )
    }
}

struct CompactMediaTransportLabel: View {
    let snapshot: MediaSnapshot
    let style: RingStyle
    let command: MediaCommand
    var isSending = false

    private var imageName: String {
        command == .togglePlayPause
            ? (snapshot.isPlaying ? "pause.fill" : "play.fill")
            : command.systemImage
    }

    var body: some View {
        ZStack {
            if command == .togglePlayPause {
                Circle()
                    .fill(.white.opacity(0.045))
            }

            if command == .togglePlayPause, !isSending {
                MediaProgressRing(
                    snapshot: snapshot,
                    style: style,
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
                    .font(.system(
                        size: command == .togglePlayPause ? 11.5 : 11,
                        weight: .semibold
                    ))
                    .foregroundStyle(.white.opacity(
                        command == .togglePlayPause ? 1 : 0.86
                    ))
            }
        }
        .frame(
            width: command == .togglePlayPause ? 30 : 28,
            height: command == .togglePlayPause ? 30 : 28
        )
        .contentShape(Circle())
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

struct CompactWingSlot: View {
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

struct CompactBatteryContent: View {
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
        let battery = model.localized("电池")
        if let chargingWatts = snapshot.chargingWatts {
            return "\(battery) \(snapshot.batteryPercent)% · \(model.localized("正在充电")) \(String(format: "%.1f W", chargingWatts))"
        }
        if snapshot.isExternalPowerConnected {
            return "\(battery) \(snapshot.batteryPercent)% · \(model.localized("已连接电源"))"
        }
        return "\(battery) \(snapshot.batteryPercent)% · \(model.localized("电池供电"))"
    }

}

struct CompactBatteryStatusReveal: View {
    @ObservedObject var model: AppModel
    let snapshot: PowerSnapshot
    let side: NotchWingSide
    let isRevealed: Bool
    let reduceMotion: Bool
    let style: RingStyle

    var body: some View {
        ZStack {
            CompactWingRevealShape(
                side: side,
                progress: isRevealed ? 1 : 0
            )
            .fill(.black)
            .opacity(isRevealed ? 1 : 0)
            .animation(revealAnimation, value: isRevealed)

            HStack(spacing: 6) {
                if side == .left {
                    batteryPercentage
                    statusText
                    statusRing
                } else {
                    statusRing
                    statusText
                    batteryPercentage
                }
            }
            .padding(side == .left ? .leading : .trailing, 12)
            .padding(side == .left ? .trailing : .leading, 3.5)
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {}
        .help(accessibilityText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var statusRing: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.045))

            UsageArc(
                progress: Double(snapshot.batteryPercent) / 100,
                style: style,
                lineWidth: 2.5
            )

            Image(systemName: statusSymbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.94))
        }
        .frame(width: 30, height: 30)
        .opacity(isRevealed ? 1 : 0)
        .scaleEffect(isRevealed ? 1 : 0.76)
        .animation(revealAnimation, value: isRevealed)
    }

    private var statusText: some View {
        VStack(
            alignment: side == .left ? .trailing : .leading,
            spacing: 1
        ) {
            Text(statusTitle)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Text(powerDetail)
                .font(.system(size: 7.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.52))
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        .fixedSize(horizontal: true, vertical: false)
        .opacity(isRevealed ? 1 : 0)
        .scaleEffect(isRevealed ? 1 : 0.92, anchor: textAnchor)
        .offset(x: isRevealed ? 0 : collapsedTextOffset)
        .animation(textAnimation, value: isRevealed)
        .animation(NotchDesign.Motion.value, value: snapshot.updatedAt)
    }

    private var batteryPercentage: some View {
        Text("\(snapshot.batteryPercent)%")
            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.82))
            .monospacedDigit()
            .contentTransition(.numericText())
            .frame(minWidth: 26, minHeight: 22)
            .opacity(isRevealed ? 1 : 0)
            .scaleEffect(isRevealed ? 1 : 0.84, anchor: textAnchor)
            .offset(x: isRevealed ? 0 : collapsedTextOffset * 0.55)
            .animation(textAnimation, value: isRevealed)
            .animation(NotchDesign.Motion.value, value: snapshot.batteryPercent)
    }

    private var statusTitle: String {
        if snapshot.isCharging {
            return model.localized("正在充电")
        }
        if snapshot.isExternalPowerConnected {
            return model.localized("已达充电上限")
        }
        return model.localized("电池供电")
    }

    private var statusSymbol: String {
        if snapshot.isCharging { return "bolt.fill" }
        if snapshot.isExternalPowerConnected { return "checkmark" }
        return "battery.75"
    }

    private var powerDetail: String {
        let source = model.localized(
            snapshot.isExternalPowerConnected ? "适配器" : "系统"
        )
        guard let watts = livePowerWatts else {
            return "\(source) — W"
        }
        return "\(source) \(String(format: "%.1f W", watts))"
    }

    private var livePowerWatts: Double? {
        let candidates = snapshot.isExternalPowerConnected
            ? [snapshot.adapterInputWatts, snapshot.systemLoadWatts]
            : [snapshot.systemLoadWatts, snapshot.batteryPowerWatts]

        return candidates.lazy.compactMap { value -> Double? in
            guard let value, value.isFinite else { return nil }
            let watts = abs(value)
            return watts >= 0.05 ? watts : nil
        }.first
    }

    private var accessibilityText: String {
        "\(statusTitle) · \(powerDetail) · \(snapshot.batteryPercent)%"
    }

    private var revealAnimation: Animation {
        reduceMotion
            ? .linear(duration: 0.01)
            : NotchDesign.Motion.hover
    }

    private var textAnimation: Animation {
        guard !reduceMotion else { return .linear(duration: 0.01) }
        if isRevealed {
            return NotchDesign.Motion.hover.delay(0.035)
        }
        return .easeOut(duration: 0.12)
    }

    private var collapsedTextOffset: CGFloat {
        side == .left ? 14 : -14
    }

    private var textAnchor: UnitPoint {
        side == .left ? .trailing : .leading
    }
}
