import AppKit
import SwiftUI

struct ExpandedPanelSurface: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    var body: some View {
        ExpandedPanel(model: model)
            .environment(\.appearsActive, true)
            .nativeLiquidGlassSurface(
                level: model.liquidGlassLevel,
                cornerRadius: NotchDesign.Radius.panel,
                contentSize: CGSize(
                    width: NotchLayout.expandedPanelWidth,
                    height: NotchLayout.expandedPanelHeight
                ),
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
    @State private var notificationClearConfirmation: NotificationClearConfirmation?
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
            LocalizedStringKey(
                notificationClearConfirmation?.title ?? "清理全部通知？"
            ),
            isPresented: Binding(
                get: { notificationClearConfirmation != nil },
                set: { isPresented in
                    if !isPresented {
                        notificationClearConfirmation = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            if let action = notificationClearConfirmation {
                Button(LocalizedStringKey(action.actionTitle), role: .destructive) {
                    switch action {
                    case .notificationCenter:
                        model.clearAllNotifications()
                    case .sessionRecords:
                        model.clearObservedBannerRecords()
                    }
                    notificationClearConfirmation = nil
                }
            }
            Button("取消", role: .cancel) {
                notificationClearConfirmation = nil
            }
        } message: {
            if let action = notificationClearConfirmation {
                Text(LocalizedStringKey(action.message))
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
                    title: Text(model.localized(prompt.title)),
                    message: Text(model.localized(prompt.message)),
                    primaryButton: .destructive(Text("重置并重新授权")) {
                        model.repairAccessibilityAuthorization()
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
            return Alert(
                title: Text(model.localized(prompt.title)),
                message: Text(model.localized(prompt.message)),
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
                    Text(LocalizedStringKey(title))
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
                    Text(LocalizedStringKey(detail))
                } else {
                    Text(LocalizedStringKey(detail))
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
                Text(LocalizedStringKey(model.workspaceSection.title))
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
                            Label(LocalizedStringKey(section.title), systemImage: section.symbol)
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
                    clearConfirmation: $notificationClearConfirmation
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: NotchDesign.Spacing.group) {
                    Text("快捷状态")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
