import SwiftUI

/// The full settings surface lives in a conventional macOS settings window.
/// The notch panel only exposes a single entry point so the panel does not
/// become a dense, nested menu as more options are added.
struct SettingsRootView: View {
    private enum Destination: Hashable {
        case appearance
        case behavior
        case permissions
        case updates
        case diagnostics
        case about
    }

    @ObservedObject var model: AppModel
    @State private var selection: Destination? = .appearance

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                Section("Notch Triage") {
                    sidebarItem("外观", symbol: "rectangle.on.rectangle", destination: .appearance)
                    sidebarItem("行为", symbol: "slider.horizontal.3", destination: .behavior)
                    sidebarItem("权限", symbol: "lock.shield", destination: .permissions)
                    sidebarItem("更新", symbol: "arrow.trianglehead.2.clockwise.rotate.90", destination: .updates)
                    sidebarItem("诊断", symbol: "waveform.path.ecg", destination: .diagnostics)
                }

                Section {
                    sidebarItem("关于", symbol: "info.circle", destination: .about)
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 210, idealWidth: 210, maxWidth: 210)
            .layoutPriority(1)

            Divider()

            ScrollView {
                detailView
                    .frame(maxWidth: 560, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.horizontal, 42)
                    .padding(.vertical, 34)
            }
            .frame(minWidth: 569)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 780, idealWidth: 860, minHeight: 540, idealHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            model.refreshLaunchAtLoginStatus()
        }
        .alert(item: nonReleaseUpdatePrompt) { prompt in
            Alert(
                title: Text(prompt.title),
                message: Text(prompt.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    @ViewBuilder
    private func sidebarItem(
        _ title: String,
        symbol: String,
        destination: Destination
    ) -> some View {
        Label(title, systemImage: symbol)
            .tag(destination)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection ?? .appearance {
        case .appearance:
            appearancePage
        case .behavior:
            behaviorPage
        case .permissions:
            permissionsPage
        case .updates:
            updatesPage
        case .diagnostics:
            diagnosticsPage
        case .about:
            aboutPage
        }
    }

    private var appearancePage: some View {
        SettingsPage(
            title: "外观",
            subtitle: "选择刘海两侧显示的内容，预览会随设置即时更新。",
            symbol: "rectangle.on.rectangle"
        ) {
            SettingsGroup(title: "刘海内容") {
                settingsPicker(
                    title: "左侧",
                    symbol: "arrow.left",
                    selection: Binding(
                        get: { model.leftWingContent },
                        set: { model.setLeftWingContent($0) }
                    )
                )

                Divider()

                settingsPicker(
                    title: "右侧",
                    symbol: "arrow.right",
                    selection: Binding(
                        get: { model.rightWingContent },
                        set: { model.setRightWingContent($0) }
                    )
                )
            }

            HStack(spacing: 10) {
                WingPreviewCard(title: "左侧", content: model.leftWingContent)
                WingPreviewCard(title: "右侧", content: model.rightWingContent)
            }

            HStack {
                Button {
                    model.swapWingContents()
                } label: {
                    Label("左右互换", systemImage: "arrow.left.arrow.right")
                }

                Button("恢复默认") {
                    model.resetWingContents()
                }

                Spacer()
            }
            .buttonStyle(.borderless)

            SettingsGroup(title: "圆环主题") {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "circle.lefthalf.filled")
                        .foregroundStyle(.tint)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("全局主题模板")
                            .font(.callout.weight(.medium))
                        Text(model.ringAppearance.theme.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    Picker(
                        "全局主题模板",
                        selection: Binding(
                            get: { model.ringAppearance.theme },
                            set: { model.setRingTheme($0) }
                        )
                    ) {
                        ForEach(RingTheme.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }

                Divider()

                HStack(spacing: 8) {
                    ForEach(RingMetric.allCases) { metric in
                        RingThemeSwatch(
                            metric: metric,
                            style: model.ringAppearance.style(for: metric)
                        )
                    }
                    Spacer(minLength: 0)
                }

                Text("电池、额度和正在播放会统一使用这个模板；单独调整请展开高阶配置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup {
                AdvancedRingAppearanceView(model: model)
                    .padding(.top, 6)
            } label: {
                Label("高阶圆环配置", systemImage: "slider.horizontal.2.square")
                    .font(.callout.weight(.semibold))
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.primary.opacity(0.08), lineWidth: 0.5)
            }
        }
    }

    private var behaviorPage: some View {
        SettingsPage(
            title: "行为",
            subtitle: "控制通知横幅、后台刷新和登录后的启动方式。",
            symbol: "slider.horizontal.3"
        ) {
            SettingsGroup(title: "通知横幅") {
                HStack(alignment: .center, spacing: 12) {
                    Toggle("自动收起横幅", isOn: $model.autoDismissBanners)
                        .labelsHidden()
                        .controlSize(.regular)
                        .accessibilityLabel("自动收起横幅")

                    SettingsRowLabel(
                        title: "自动收起横幅",
                        subtitle: "新通知提示完成后自动恢复为紧凑状态。",
                        symbol: "rectangle.compress.vertical"
                    )
                    Spacer(minLength: 0)
                }
            }

            SettingsGroup(title: "登录项") {
                HStack(alignment: .center, spacing: 12) {
                    Toggle(
                        "登录时启动 Notch Triage",
                        isOn: Binding(
                            get: { model.launchAtLoginEnabled },
                            set: { model.setLaunchAtLoginEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .controlSize(.regular)
                    .accessibilityLabel("登录时启动 Notch Triage")

                    SettingsRowLabel(
                        title: "登录时启动 Notch Triage",
                        subtitle: model.launchAtLoginStatusDescription,
                        symbol: "power"
                    )
                    Spacer(minLength: 0)
                }

                if model.launchAtLoginRequiresApproval {
                    Divider()
                    Button {
                        model.openLoginItemsSettings()
                    } label: {
                        SettingsRowLabel(
                            title: "批准登录项",
                            subtitle: "系统设置需要确认 Notch Triage 的登录项。",
                            symbol: "gear"
                        )
                    }
                    .buttonStyle(.borderless)
                }
            }

            SettingsGroup(title: "后台刷新") {
                SettingsStatusRow(
                    title: model.isBackgroundRefreshPaused ? "后台刷新已暂停" : "后台刷新正常",
                    subtitle: model.isBackgroundRefreshPaused
                        ? "屏幕锁定或休眠时暂停非必要刷新。"
                        : "由统一调度器合并任务，减少唤醒和耗电。",
                    symbol: model.isBackgroundRefreshPaused ? "pause.circle" : "leaf",
                    tint: model.isBackgroundRefreshPaused ? .orange : .green
                )
            }
        }
    }

    private var permissionsPage: some View {
        SettingsPage(
            title: "权限",
            subtitle: "Notch Triage 只在对应功能需要时使用系统权限。",
            symbol: "lock.shield"
        ) {
            SettingsGroup(title: "辅助功能") {
                SettingsStatusRow(
                    title: accessibilityTitle,
                    subtitle: model.notificationHealth.message,
                    symbol: "hand.raised",
                    tint: accessibilityColor
                )

                Divider()

                HStack {
                    Text("用于读取和清理通知中心中的通知。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Button(model.accessibilityRepairSuggested ? "修复权限…" : "打开设置…") {
                        if model.accessibilityRepairSuggested {
                            model.presentAccessibilityRepairPrompt()
                        } else {
                            model.requestAccessibility()
                        }
                    }
                }
            }

            SettingsGroup(title: "权限说明") {
                permissionExplanation(
                    "辅助功能",
                    "读取窗口和通知层级，并执行清理通知操作。"
                )
                Divider()
                permissionExplanation(
                    "自动化",
                    "在你确认后控制 Finder 清空废纸篓。"
                )
                Divider()
                permissionExplanation(
                    "媒体控制",
                    "读取正在播放曲目和播放进度，不会在每次切歌时重复申请。"
                )
            }
        }
    }

    private var updatesPage: some View {
        SettingsPage(
            title: "更新",
            subtitle: "检查 GitHub Release，下载完成后验证并重启应用。",
            symbol: "arrow.trianglehead.2.clockwise.rotate.90"
        ) {
            SettingsGroup(title: "当前版本") {
                HStack {
                    SettingsRowLabel(
                        title: "Notch Triage",
                        subtitle: updateStatusDescription,
                        symbol: "checkmark.seal"
                    )
                    Spacer()
                    Text("v\(model.currentVersion)")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                }

                if let progress = model.updateDownloadProgress {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(model.updateStatus.menuTitle)
                                .font(.callout.weight(.medium))
                            Spacer()
                            Text("\(Int((progress.fraction * 100).rounded()))%")
                                .font(.callout.monospacedDigit().weight(.semibold))
                        }
                        ProgressView(value: progress.fraction)
                        Text("\(Self.byteCount(progress.receivedBytes)) / \(Self.byteCount(progress.totalBytes))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsGroup(title: "操作") {
                HStack {
                    Button {
                        model.handleSettingsUpdateAction()
                    } label: {
                        Label(updateButtonTitle, systemImage: model.updateStatus.symbol)
                    }
                    .disabled(model.updateStatus.isBusy)

                    Spacer()

                    if let release = model.availableUpdate {
                        Text(release.displayVersion)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
            }

            if let release = model.availableUpdate {
                SettingsGroup(title: "版本说明") {
                    Text(release.notes.isEmpty ? "此版本没有附加说明。" : release.notes)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var diagnosticsPage: some View {
        SettingsPage(
            title: "诊断",
            subtitle: "查看服务健康状态、最近事件和后台调度情况。",
            symbol: "waveform.path.ecg"
        ) {
            DiagnosticsDashboardView(model: model)
                .frame(minHeight: 480)
        }
    }

    private var aboutPage: some View {
        SettingsPage(
            title: "关于",
            subtitle: "原生、轻量、常驻的 macOS 刘海工具。",
            symbol: "info.circle"
        ) {
            SettingsGroup(title: "Notch Triage") {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notch Triage")
                            .font(.title3.weight(.semibold))
                        Text("版本 v\(model.currentVersion)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("Codex · 媒体 · 电源 · 通知 · 系统 HUD")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
            }

            SettingsGroup(title: "快捷操作") {
                Button {
                    model.refreshDiagnostics()
                } label: {
                    Label("立即刷新全部服务", systemImage: "arrow.clockwise")
                }
                Button {
                    model.copyDiagnosticReport()
                } label: {
                    Label("复制诊断报告", systemImage: "doc.on.doc")
                }
                Button("退出 Notch Triage", role: .destructive) {
                    model.quitApplication()
                }
            }
        }
    }

    private func settingsPicker(
        title: String,
        symbol: String,
        selection: Binding<NotchWingContent>
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title)
            Spacer()
            Picker(title, selection: selection) {
                ForEach(NotchWingContent.allCases) { content in
                    Label(content.title, systemImage: content.symbol)
                        .tag(content)
                }
            }
            .labelsHidden()
            .frame(width: 220)
        }
    }

    private func permissionExplanation(_ title: String, _ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var accessibilityTitle: String {
        switch model.notificationHealth {
        case .ready:
            return "辅助功能已授权"
        case .loading:
            return "正在检查辅助功能"
        case .warning, .failed:
            return "需要辅助功能权限"
        }
    }

    private var accessibilityColor: Color {
        switch model.notificationHealth {
        case .ready: return .green
        case .loading: return .orange
        case .warning, .failed: return .red
        }
    }

    private var updateStatusDescription: String {
        switch model.updateStatus {
        case .idle: return "等待检查"
        case .checking: return "正在检查 GitHub Release"
        case .available(let version): return "发现可安装版本 v\(version)"
        case .downloading(let version): return "正在下载 v\(version)"
        case .installing(let version): return "正在安装 v\(version)"
        case .upToDate(let version): return "当前已是最新版 v\(version)"
        case .failed(let message): return message
        }
    }

    private var updateButtonTitle: String {
        if model.availableUpdate != nil {
            return "下载并安装"
        }
        return model.updateStatus.isBusy ? model.updateStatus.menuTitle : "检查更新"
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

    private static func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

private struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.bottom, 2)

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.primary.opacity(0.08), lineWidth: 0.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsRowLabel: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

private struct SettingsStatusRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
        }
    }
}

private struct WingPreviewCard: View {
    let title: String
    let content: NotchWingContent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Image(systemName: content.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tint)
                Text(content.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct RingThemeSwatch: View {
    let metric: RingMetric
    let style: RingStyle

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .stroke(style.shapeStyle, lineWidth: 3)
                .frame(width: 22, height: 22)
            Text(metric.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AdvancedRingAppearanceView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("开启单项覆盖后，该圆环不再跟随全局主题。颜色支持环形渐变，也可以切换为纯色。")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(RingMetric.allCases) { metric in
                RingStyleEditor(model: model, metric: metric)

                if metric != RingMetric.allCases.last {
                    Divider()
                }
            }

            Button {
                model.resetRingAppearance()
            } label: {
                Label("恢复所有圆环默认", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
        }
    }
}

private struct RingStyleEditor: View {
    @ObservedObject var model: AppModel
    let metric: RingMetric

    private var override: RingStyleOverride {
        model.ringOverride(for: metric)
    }

    private var style: RingStyle {
        override.style
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { override.isEnabled },
                set: { model.setRingOverrideEnabled($0, for: metric) }
            )) {
                Label(metric.title, systemImage: metric.symbol)
                    .font(.callout.weight(.medium))
            }

            HStack(spacing: 14) {
                ColorPicker(
                    "起始色",
                    selection: colorBinding(.start),
                    supportsOpacity: true
                )
                ColorPicker(
                    "结束色",
                    selection: colorBinding(.end),
                    supportsOpacity: true
                )
                ColorPicker(
                    "轨道",
                    selection: colorBinding(.track),
                    supportsOpacity: true
                )
            }
            .disabled(!override.isEnabled)

            HStack(spacing: 10) {
                Text("渐变模板")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(
                    "渐变模板",
                    selection: Binding(
                        get: { style.gradientMode },
                        set: { model.setRingGradientMode($0, for: metric) }
                    )
                ) {
                    ForEach(RingGradientMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .disabled(!override.isEnabled)

                Circle()
                    .stroke(style.shapeStyle, lineWidth: 4)
                    .frame(width: 24, height: 24)
                    .opacity(override.isEnabled ? 1 : 0.45)
            }
        }
    }

    private func colorBinding(_ component: RingColorComponent) -> Binding<Color> {
        Binding(
            get: {
                switch component {
                case .start: return style.start.color
                case .end: return style.end.color
                case .track: return style.track.color
                }
            },
            set: { model.setRingColor($0, for: metric, component: component) }
        )
    }
}
