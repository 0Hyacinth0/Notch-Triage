import AppKit
import SwiftUI

struct NotificationInbox: View {
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
                    Text(LocalizedStringKey(emptyDetail))
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

                Text(LocalizedStringKey(
                    model.autoDismissBanners ? "横幅自动收起" : "横幅保持原样"
                ))
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

struct CodexUsageCard: View {
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

            Text(LocalizedStringKey(title))
                .font(.system(size: 9.5, weight: .semibold))

            Text(LocalizedStringKey(resetLabel(for: bucket)))
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
                Text(LocalizedStringKey(estimatedUSDLabel))
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(LocalizedStringKey(creditsLabel))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(LocalizedStringKey(balanceHint))
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
        return reset.formatted(date: .omitted, time: .shortened)
            + " "
            + model.localized("重置")
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

struct TrashCompactCard: View {
    @ObservedObject var model: AppModel
    @Binding var confirmEmptyTrash: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: trashSymbol)
                .font(.system(size: 16, weight: .medium))

            VStack(alignment: .leading, spacing: 1) {
                Text("废纸篓")
                    .font(.system(size: 11.5, weight: .semibold))
                Text(LocalizedStringKey(trashStatus))
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
        if count == 0 { return model.localized("空") }
        return model.appLanguage == .english
            ? "\(count) item\(count == 1 ? "" : "s")"
            : "\(count) 项"
    }

    private var trashSymbol: String {
        guard let count = model.trashCount else { return "trash" }
        return count == 0 ? "trash" : "trash.fill"
    }
}

struct NowPlayingStrip: View {
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
                if snapshot == .idle {
                    Text("暂未播放")
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                } else {
                    Text(snapshot.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                }

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
        .accessibilityLabel(model.localized(command.title))
        .accessibilityValue(
            model.localized(isSending ? "正在发送" : (isEnabled ? "可用" : "不可用"))
        )
    }
}

struct MediaProgressRing: View {
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

struct UsageArc: View {
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

struct SourceIcon: View {
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
