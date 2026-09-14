import SwiftUI

/// The full settings surface lives in a conventional macOS settings window.
/// The notch panel only exposes a single entry point so the panel does not
/// become a dense, nested menu as more options are added.
struct SettingsRootView: View {
    private enum Destination: String, Hashable {
        case appearance
        case behavior
        case permissions
        case updates
        case diagnostics
        case about

        var title: String {
            switch self {
            case .appearance: return "外观"
            case .behavior: return "通用"
            case .permissions: return "权限"
            case .updates: return "更新"
            case .diagnostics: return "诊断"
            case .about: return "关于"
            }
        }
    }

    @ObservedObject var model: AppModel
    let onPaneChange: @MainActor (String) -> Void
    @AppStorage("NotchTriage.Settings.selectedPane") private var selectedPane = "appearance"

    init(
        model: AppModel,
        onPaneChange: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.model = model
        self.onPaneChange = onPaneChange
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: selectionBinding) {
                Section("Notch Triage") {
                    sidebarItem("外观", symbol: "rectangle.on.rectangle", destination: .appearance)
                    sidebarItem("通用", symbol: "slider.horizontal.3", destination: .behavior)
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
        .environment(\.locale, model.appLanguage.locale)
        .onAppear {
            model.refreshLaunchAtLoginStatus()
            onPaneChange(localizedSettingsWindowTitle)
        }
        .onChange(of: selectedPane) { _, rawValue in
            let destination = Destination(rawValue: rawValue) ?? .appearance
            onPaneChange(localizedSettingsWindowTitle(for: destination))
        }
        .onChange(of: model.appLanguage) { _, _ in
            onPaneChange(localizedSettingsWindowTitle)
        }
        .alert(item: nonReleaseUpdatePrompt) { prompt in
            Alert(
                title: Text(model.localized(prompt.title)),
                message: Text(model.localized(prompt.message)),
                dismissButton: .default(Text("好"))
            )
        }
    }

    private var selectionBinding: Binding<Destination?> {
        Binding(
            get: {
                Destination(rawValue: selectedPane) ?? .appearance
            },
            set: { destination in
                selectedPane = (destination ?? .appearance).rawValue
            }
        )
    }

    private var currentDestination: Destination {
        Destination(rawValue: selectedPane) ?? .appearance
    }

    private var localizedSettingsWindowTitle: String {
        localizedSettingsWindowTitle(for: currentDestination)
    }

    private func localizedSettingsWindowTitle(for destination: Destination) -> String {
        "\(model.localized("Notch Triage 设置")) — \(model.localized(destination.title))"
    }

    @ViewBuilder
    private func sidebarItem(
        _ title: String,
        symbol: String,
        destination: Destination
    ) -> some View {
        Label(LocalizedStringKey(title), systemImage: symbol)
            .tag(destination)
    }

    @ViewBuilder
    private var detailView: some View {
        switch currentDestination {
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
            subtitle: "选择刘海内容、圆环配色和展开面板的材质。",
            symbol: "rectangle.on.rectangle"
        ) {
            SettingsGroup(title: "刘海布局") {
                notchPreview
                HStack(spacing: 12) {
                    wingSelector("左侧", selection: Binding(
                        get: { model.leftWingContent },
                        set: { model.setLeftWingContent($0) }
                    ))
                    Button { model.swapWingContents() } label: {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                    .buttonStyle(.borderless)
                    .help("左右互换")
                    .accessibilityLabel("左右互换")
                    wingSelector("右侧", selection: Binding(
                        get: { model.rightWingContent },
                        set: { model.setRightWingContent($0) }
                    ))
                }
                Button("重置布局") { model.resetWingContents() }
                    .buttonStyle(.borderless)
            }

            SettingsGroup(title: "圆环样式") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 8) {
                    ForEach(RingTheme.allCases) { theme in
                        Button { model.setRingTheme(theme) } label: {
                            VStack(spacing: 8) {
                                HStack(spacing: 8) {
                                    ForEach(RingMetric.allCases) { metric in
                                        Circle()
                                            .stroke(theme.style(for: metric).shapeStyle, lineWidth: 3)
                                            .frame(width: 18, height: 18)
                                    }
                                }
                                Text(LocalizedStringKey(theme.title)).font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                model.ringAppearance.theme == theme
                                    ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(model.ringAppearance.theme == theme ? Color.accentColor : .clear, lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(model.ringAppearance.theme == theme ? .isSelected : [])
                    }
                }
                if model.leftWingContent == .codex || model.rightWingContent == .codex {
                    DisclosureGroup("Codex 额度圆环") {
                Picker("圆环布局", selection: $model.codexRingLayout) {
                    ForEach(CodexRingLayout.allCases) { layout in
                        Text(model.localized(layout.title)).tag(layout)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 16) {
                    CodexQuotaRings(
                        layout: model.codexRingLayout,
                        fiveHour: 0.75,
                        weekly: 0.45,
                        style: model.ringAppearance.style(for: .codex)
                    )
                    .padding(14)
                    .background(.black, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.localized(model.codexRingLayout.legend))
                        Text("预览：5h 剩余 75% · 周额度剩余 45%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("仅影响限额圆环；悬停可查看精确数值。")
                    .font(.caption).foregroundStyle(.secondary)

                    }
                }
                DisclosureGroup("单独调整颜色") {
                    AdvancedRingAppearanceView(model: model)
                        .padding(.top, 8)
                }
            }

            SettingsGroup(title: "面板材质") {
                LiquidGlassStylePreview(level: model.liquidGlassLevel)

                HStack(spacing: 12) {
                    Text("清透")
                        .font(.caption)
                        .foregroundStyle(model.liquidGlassLevel < 0.5 ? .primary : .secondary)

                    Slider(
                        value: Binding(
                            get: { model.liquidGlassLevel },
                            set: { model.setLiquidGlassLevel($0) }
                        ),
                        in: 0...1
                    )
                    .accessibilityLabel("Liquid Glass 外观")
                    .accessibilityValue(
                        liquidGlassAccessibilityValue
                    )

                    Text("标准")
                        .font(.caption)
                        .foregroundStyle(model.liquidGlassLevel >= 0.5 ? .primary : .secondary)
                }

                Text(liquidGlassDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            SettingsGroup(title: "通知提示") {
                HStack(spacing: 14) {
                    previewRing(model.leftWingContent, notification: true)
                    previewRing(model.rightWingContent, notification: true)
                    Text("通知会显示在当前圆环中央")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(.black, in: RoundedRectangle(cornerRadius: 12))
                DisclosureGroup("调整通知提示") {
                VStack(spacing: 12) {
                    notificationPromptRow(
                        icon: model.notificationPromptIcon.symbol,
                        title: "提示图标",
                        subtitle: model.notificationPromptIcon.subtitle
                    ) {
                        Picker(
                            "提示图标",
                            selection: Binding(
                                get: { model.notificationPromptIcon },
                                set: { model.setNotificationPromptIcon($0) }
                            )
                        ) {
                            ForEach(NotificationPromptIcon.allCases) { icon in
                                Text(LocalizedStringKey(icon.title)).tag(icon)
                            }
                        }
                    }

                    notificationPromptRow(
                        icon: "circle.fill",
                        title: "提示颜色",
                        subtitle: model.notificationPromptColor.title,
                        iconColor: model.notificationPromptColor.color
                    ) {
                        Picker(
                            "提示颜色",
                            selection: Binding(
                                get: { model.notificationPromptColor },
                                set: { model.setNotificationPromptColor($0) }
                            )
                        ) {
                            ForEach(NotificationPromptColor.allCases) { color in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(color.color)
                                        .frame(width: 9, height: 9)
                                    Text(LocalizedStringKey(color.title))
                                }
                                .tag(color)
                            }
                        }
                    }

                    notificationPromptRow(
                        icon: model.notificationPromptAnimation.symbol,
                        title: "提示动画",
                        subtitle: model.notificationPromptAnimation.subtitle
                    ) {
                        Picker(
                            "提示动画",
                            selection: Binding(
                                get: { model.notificationPromptAnimation },
                                set: { model.setNotificationPromptAnimation($0) }
                            )
                        ) {
                            ForEach(NotificationPromptAnimation.allCases) { animation in
                                Text(LocalizedStringKey(animation.title)).tag(animation)
                            }
                        }
                    }
                }

                }
                Text("有通知或新提示时，当前显示的每个圆环中央都会出现提示图标；两侧使用同一个节拍同步播放。没有圆环的一侧不会显示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }


        }
    }


    private var notchPreview: some View {
        HStack(spacing: 0) {
            previewRing(model.leftWingContent)
                .frame(width: 58)
            RoundedRectangle(cornerRadius: 2)
                .fill(.white.opacity(0.18))
                .frame(width: 22, height: 3)
                .frame(width: 130, height: 54, alignment: .bottom)
                .padding(.bottom, 8)
            previewRing(model.rightWingContent)
                .frame(width: 58)
        }
        .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16))
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
        .accessibilityLabel("刘海布局预览")
    }

    @ViewBuilder
    private func previewRing(_ content: NotchWingContent, notification: Bool = false) -> some View {
        switch content {
        case .hidden:
            Color.clear.frame(width: 26, height: 26)
        case .codex:
            ZStack {
                CodexQuotaRings(layout: model.codexRingLayout, fiveHour: 0.75, weekly: 0.45,
                    style: model.ringAppearance.style(for: .codex))
                if notification { notificationPreviewIcon }
            }
        case .battery, .media:
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 3)
                Circle().trim(from: 0, to: 0.75)
                    .stroke(model.ringAppearance.style(for: content == .battery ? .battery : .media).shapeStyle,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if notification { notificationPreviewIcon }
            }
            .frame(width: 26, height: 26)
        }
    }

    private var notificationPreviewIcon: some View {
        Image(systemName: model.notificationPromptIcon.symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(model.notificationPromptColor.color)
    }

    private func wingSelector(_ title: String, selection: Binding<NotchWingContent>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(title)).font(.caption).foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(NotchWingContent.allCases) { content in
                    Text(LocalizedStringKey(content.title)).tag(content)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
    }

    private var liquidGlassAccessibilityValue: String {
        let percent = Int((model.liquidGlassLevel * 100).rounded())
        if percent == 0 { return model.localized("清透") }
        if percent == 100 { return model.localized("标准") }
        return "\(percent)%"
    }

    private var liquidGlassDescription: String {
        let percent = Int((model.liquidGlassLevel * 100).rounded())
        if percent == 0 {
            return model.localized(
                "清透端使用完整的 Apple Clear Glass，保留原生折射、散射与立体边缘。"
            )
        }
        if percent == 100 {
            return model.localized(
                "标准端在 Clear Glass 上完整叠加 Apple Regular Glass，增强磨砂与文字对比度。"
            )
        }
        if model.appLanguage == .english {
            return "Keeps full Clear Glass and gradually adds Apple Regular Glass (\(percent)%)."
        }
        return "保持完整 Clear Glass，并逐渐叠加 Apple Regular Glass（\(percent)%）。"
    }

    @ViewBuilder
    private func notificationPromptRow<PickerContent: View>(
        icon: String,
        title: String,
        subtitle: String,
        iconColor: Color = Color(nsColor: .controlAccentColor),
        @ViewBuilder picker: () -> PickerContent
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.14))
                    .frame(width: 24, height: 24)
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title))
                    .font(.callout.weight(.medium))
                Text(LocalizedStringKey(subtitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            picker()
                .labelsHidden()
                .frame(width: 150)
        }
    }

    private var behaviorPage: some View {
        SettingsPage(
            title: "通用",
            subtitle: "控制界面语言、通知横幅和登录后的启动方式。",
            symbol: "slider.horizontal.3"
        ) {
            SettingsGroup(title: "语言") {
                HStack(spacing: 12) {
                    SettingsRowLabel(
                        title: "界面语言",
                        subtitle: "选择 Notch Triage 的显示语言。",
                        symbol: "globe"
                    )

                    Spacer(minLength: 12)

                    Picker(
                        "界面语言",
                        selection: Binding(
                            get: { model.appLanguage },
                            set: { model.setAppLanguage($0) }
                        )
                    ) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
            }

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

            SettingsGroup(title: "剪贴板历史") {
                HStack(alignment: .center, spacing: 12) {
                    SettingsRowLabel(
                        title: model.clipboardHistoryEnabled
                            ? (model.isClipboardMonitoringActive ? "正在监控" : "监控已暂停或受阻")
                            : "默认关闭",
                        subtitle: "只记录白名单内容并保存在本机；无法保证识别所有密码或令牌。",
                        symbol: model.clipboardHistoryEnabled ? "clipboard.fill" : "clipboard"
                    )

                    Spacer(minLength: 12)

                    Button(LocalizedStringKey(
                        model.clipboardHistoryEnabled ? "停止并保留" : "启用"
                    )) {
                        if model.clipboardHistoryEnabled {
                            model.disableClipboardHistory(clearHistory: false)
                        } else {
                            model.enableClipboardHistory()
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(model.clipboardHistoryEnabled ? .secondary : .accentColor)
                }

                Divider()

                HStack(spacing: 12) {
                    SettingsRowLabel(
                        title: "保留期限",
                        subtitle: model.clipboardRetentionPolicy.privacyDescription,
                        symbol: "clock.arrow.circlepath"
                    )
                    Spacer(minLength: 12)
                    Picker(
                        "保留期限",
                        selection: Binding(
                            get: { model.clipboardRetentionPolicy },
                            set: { model.setClipboardRetentionPolicy($0) }
                        )
                    ) {
                        ForEach(ClipboardRetentionPolicy.allCases) { policy in
                            Text(LocalizedStringKey(policy.title)).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }

                if let notice = model.clipboardAccessNotice {
                    Divider()
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                HStack {
                    Text("清空历史不会更改当前系统剪贴板。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Button("清空历史", role: .destructive) {
                        model.clearClipboardHistory()
                    }
                    .disabled(model.clipboardHistoryItems.isEmpty)
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
                    Button(LocalizedStringKey(
                        model.accessibilityRepairSuggested ? "修复权限…" : "打开设置…"
                    )) {
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
                            Text(model.localized(model.updateStatus.menuTitle))
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
                        Text(model.appLanguage == .english
                             ? "Version v\(model.currentVersion)"
                             : "版本 v\(model.currentVersion)")
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
            Text(LocalizedStringKey(title))
            Spacer()
            Picker(title, selection: selection) {
                ForEach(NotchWingContent.allCases) { content in
                    Label(LocalizedStringKey(content.title), systemImage: content.symbol)
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
                Text(LocalizedStringKey(title))
                    .font(.callout.weight(.medium))
                Text(LocalizedStringKey(message))
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
        case .idle: return model.localized("等待检查")
        case .checking: return model.localized("正在检查 GitHub Release")
        case .available(let version):
            return model.appLanguage == .english
                ? "Found an installable version v\(version)"
                : "发现可安装版本 v\(version)"
        case .downloading(let version):
            return model.appLanguage == .english
                ? "Downloading v\(version)"
                : "正在下载 v\(version)"
        case .installing(let version):
            return model.appLanguage == .english
                ? "Installing v\(version)"
                : "正在安装 v\(version)"
        case .upToDate(let version):
            return model.appLanguage == .english
                ? "Already up to date at v\(version)"
                : "当前已是最新版 v\(version)"
        case .failed(let message): return message
        }
    }

    private var updateButtonTitle: String {
        if model.availableUpdate != nil {
            return model.localized("下载并安装")
        }
        return model.updateStatus.isBusy
            ? model.updateStatus.localizedMenuTitle(using: model.appLanguage)
            : model.localized("检查更新")
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
                Text(LocalizedStringKey(title))
                    .font(.system(size: 24, weight: .bold))
                Text(LocalizedStringKey(subtitle))
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
            Text(LocalizedStringKey(title))
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
                Text(LocalizedStringKey(title))
                    .font(.callout.weight(.medium))
                Text(LocalizedStringKey(subtitle))
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
                Text(LocalizedStringKey(title))
                    .font(.callout.weight(.medium))
                Text(LocalizedStringKey(subtitle))
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
            Text(LocalizedStringKey(title))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Image(systemName: content.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tint)
                Text(LocalizedStringKey(content.title))
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

private struct LiquidGlassStylePreview: View {
    let level: Double

    var body: some View {
        ZStack {
            Image("LiquidGlassPreviewBackground")
                .resizable()
                .scaledToFill()
                .overlay {
                    LinearGradient(
                        colors: [.black.opacity(0.02), .black.opacity(0.18)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .glassEffect(.regular.interactive(), in: .circle)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(previewTitle))
                        .font(.callout.weight(.semibold))
                    Text(LocalizedStringKey("Apple 原生 Liquid Glass"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(width: 290, height: 58)
            .nativeLiquidGlassSurface(level: level, cornerRadius: 19)
        }
        .frame(height: 108)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityHidden(true)
    }

    private var previewTitle: String {
        if level <= 0.01 { return "清透" }
        if level >= 0.99 { return "标准" }
        return "\(Int((level * 100).rounded()))%"
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
            Text(LocalizedStringKey(metric.title))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AdvancedRingAppearanceView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("开启自定义后，该圆环使用独立配色；关闭后跟随主题。")
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
                Label("重置圆环颜色", systemImage: "arrow.counterclockwise")
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
                Text("\(model.localized(metric.title)) · \(model.localized(override.isEnabled ? "自定义" : "跟随主题"))")
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
                        Text(LocalizedStringKey(mode.title)).tag(mode)
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
