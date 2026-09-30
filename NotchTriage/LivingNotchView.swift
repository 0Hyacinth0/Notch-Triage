import AppKit
import SwiftUI

struct LivingNotch: View {
    @ObservedObject var model: AppModel
    let hoveredHeight: CGFloat
    let compactOverlaySide: NotchWingSide?
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
            .opacity(compactOverlaySide == .left ? 0 : 1)
            .animation(
                compactOverlaySlotAnimation(for: .left),
                value: compactOverlaySide
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
            .opacity(compactOverlaySide == .right ? 0 : 1)
            .animation(
                compactOverlaySlotAnimation(for: .right),
                value: compactOverlaySide
            )
        }
        .frame(width: compactWidth, height: height)
    }

    private func compactOverlaySlotAnimation(
        for side: NotchWingSide
    ) -> Animation {
        guard !reduceMotion else { return .linear(duration: 0.01) }
        if compactOverlaySide == side {
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
                    if model.media == .idle {
                        Text("暂未播放")
                            .font(.system(size: 10.5, weight: .semibold))
                            .lineLimit(1)
                    } else {
                        Text(model.media.title)
                            .font(.system(size: 10.5, weight: .semibold))
                            .lineLimit(1)
                    }
                    if model.media == .idle {
                        Text("正在播放")
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.48))
                            .lineLimit(1)
                    } else {
                        Text(model.media.artist.isEmpty
                             ? model.media.sourceName
                             : model.media.artist)
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.48))
                            .lineLimit(1)
                    }
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
                        Text("\(fiveHour.windowLabel) \(Int(fiveHour.remainingPercent.rounded()))%")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .contentTransition(.numericText())
                    }
                    if let weekly = model.weeklyCodexLimit,
                       weekly.id != model.fiveHourCodexLimit?.id {
                        Text("\(model.appLanguage == .english ? "W" : "周") \(Int(weekly.remainingPercent.rounded()))%")
                            .font(.system(size: 8.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.56))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
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
                Text(LocalizedStringKey(model.aiQuotaMessage))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
                if side == .right {
                    hoverCodexFallbackIcon
                }
            }
        }
    }

    private func hoverBalanceCodexStatus(side: NotchWingSide) -> some View {
        let balance = model.aiUsage.selectedValue
        let valueLabel = model.aiUsage.selected.name + "，" + balance.main + "，" + balance.detail

        return HStack(spacing: 7) {
            if side == .left {
                hoverCodexBalanceRing
            }

            VStack(alignment: side == .left ? .leading : .trailing, spacing: 0) {
                Text(LocalizedStringKey(balance.main))
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .contentTransition(.numericText())
                Text(LocalizedStringKey(balance.detail))
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            if side == .right {
                hoverCodexBalanceRing
            }
        }
        .help(valueLabel)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(valueLabel)
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
            CodexQuotaRings(
                layout: model.codexRingLayout,
                fiveHour: model.fiveHourCodexLimit?.remainingFraction ?? 0,
                weekly: model.weeklyCodexLimit?.id != model.fiveHourCodexLimit?.id
                    ? model.weeklyCodexLimit?.remainingFraction : nil,
                style: model.ringAppearance.style(for: .codex),
                diameter: 20
            )
        }
    }

    private var hoverCodexBalanceRing: some View {
        AttentionRing(
            model: model,
            diameter: 20
        ) {
            ZStack {
                UsageArc(
                    progress: model.aiUsage.selectedHasValue ? 1 : 0,
                    style: model.ringAppearance.style(for: .codex),
                    lineWidth: 2.6
                )

                Image(systemName: model.aiUsage.selectedSymbol)
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
            return model.appLanguage == .english
                ? String(format: "Charging %.1f W", chargingWatts)
                : String(format: "充电 %.1f W", chargingWatts)
        }
        if model.power.isExternalPowerConnected {
            return model.localized("已连接电源")
        }
        return model.localized("电池供电")
    }
}
