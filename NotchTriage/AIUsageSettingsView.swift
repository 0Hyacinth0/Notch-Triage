import SwiftUI

private enum AIUsageDashboardTab: String, CaseIterable, Identifiable {
    case quota = "额度"
    case usage = "用量"
    case notch = "刘海显示"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .quota: "gauge.with.dots.needle.67percent"
        case .usage: "chart.bar"
        case .notch: "rectangle.topthird.inset.filled"
        }
    }
}

struct AIUsageSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var usage: AIUsageStore
    @State private var inspectedID = AIUsageConnection.codexID
    @State private var activeTab = AIUsageDashboardTab.quota
    @State private var adding = false
    @State private var provider = AIUsageProvider.claude
    @State private var name = ""
    @State private var secret = ""
    @State private var context = ""
    @State private var replacement = ""
    @State private var codexPath = UserDefaults.standard.string(forKey: "aiUsage.codexExecutable") ?? ""
    @State private var removeTarget: AIUsageConnection?

    init(model: AppModel) {
        self.model = model
        usage = model.aiUsage
    }

    private var inspected: AIUsageConnection {
        usage.connections.first { $0.id == inspectedID } ?? .codex
    }

    private var inspectedSnapshot: AIUsageSnapshot? {
        usage.snapshots[inspected.id]
    }

    private var inspectedHealth: ServiceHealth {
        usage.status(for: inspected)
    }

    var body: some View {
        SettingsPage(
            title: "AI 套餐用量",
            subtitle: "查看订阅额度、API 余额和消费，并选择在刘海中显示的账户。",
            symbol: "gauge.with.dots.needle.67percent"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                accountSelector
                dashboardTabs
                connectionSummary
                selectedTabContent
                connectionSettings

                if let feedback = usage.feedback {
                    Text(LocalizedStringKey(feedback))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Gemini、GLM、Cursor 等平台的自动采集仍待验证，当前不显示为可连接平台。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            inspectedID = usage.selectedID
            usage.refreshAll()
        }
        .onChange(of: usage.selectedID) { _, connectionID in
            inspectedID = connectionID
        }
        .sheet(isPresented: $adding) { addSheet }
        .alert(
            "移除平台连接？",
            isPresented: Binding(
                get: { removeTarget != nil },
                set: { if !$0 { removeTarget = nil } }
            )
        ) {
            Button("取消", role: .cancel) { removeTarget = nil }
            Button("移除", role: .destructive) {
                if let connection = removeTarget { usage.remove(connection) }
                removeTarget = nil
                inspectedID = AIUsageConnection.codexID
            }
        } message: {
            Text("会删除本机保存的凭证和连接；Claude 连接还会恢复原状态栏配置。")
        }
    }

    private var accountSelector: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("平台与账户")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    adding = true
                    secret = ""
                    name = ""
                    context = ""
                    usage.feedback = nil
                } label: {
                    Label("添加平台连接", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.borderless)
            }

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(usage.connections) { connection in
                        connectionChip(connection)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func connectionChip(_ connection: AIUsageConnection) -> some View {
        let selected = inspectedID == connection.id
        let health = usage.status(for: connection)

        return Button {
            inspectedID = connection.id
            replacement = ""
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(Color(nsColor: health.color))
                    .frame(width: 7, height: 7)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.localized(connection.name))
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(LocalizedStringKey(connection.provider.title))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if usage.selectedID == connection.id {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tint)
                        .accessibilityLabel(Text("刘海显示"))
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.06), lineWidth: 0.7)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            model.localized(connection.name) + "，"
                + model.localized(connection.provider.title) + "，"
                + model.localized(health.message)
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var dashboardTabs: some View {
        HStack(spacing: 4) {
            ForEach(AIUsageDashboardTab.allCases) { tab in
                Button {
                    withAnimation(NotchDesign.Motion.sectionChange) {
                        activeTab = tab
                    }
                } label: {
                    Label(LocalizedStringKey(tab.rawValue), systemImage: tab.symbol)
                        .font(.callout.weight(activeTab == tab ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .background(
                            activeTab == tab ? Color.accentColor.opacity(0.13) : .clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(activeTab == tab ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var connectionSummary: some View {
        AIUsageCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 11) {
                    Image(systemName: providerSymbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 38, height: 38)
                        .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(LocalizedStringKey(inspected.provider.title))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text(model.localized(inspected.name))
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    AIUsageStatusBadge(health: inspectedHealth, title: statusTitle)

                    Button(action: refreshInspected) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("立即刷新")
                    .disabled(!inspected.enabled)
                }

                Divider()

                HStack(alignment: .firstTextBaseline) {
                    Text(LocalizedStringKey(inspected.provider.isLocal ? "本机连接" : "API 连接"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let snapshot = inspectedSnapshot {
                        Text("最后成功读取")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(snapshot.updatedAt.formatted(
                            Date.FormatStyle(date: .abbreviated, time: .shortened)
                                .locale(model.appLanguage.locale)
                        ))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }

                if let snapshot = inspectedSnapshot {
                    HStack(spacing: 5) {
                        Image(systemName: "tray.and.arrow.down")
                        Text("数据来源")
                        Text(LocalizedStringKey(snapshot.source))
                            .lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                    if usage.isStale(inspected) {
                        Label("显示上次数据，可能已过期", systemImage: "clock.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text(LocalizedStringKey(inspectedHealth.message))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var statusTitle: String {
        switch inspectedHealth {
        case .loading: "同步中"
        case .ready: "已连接"
        case .warning: "需检查"
        case .failed: "连接失败"
        }
    }

    private var providerSymbol: String {
        switch inspected.provider {
        case .codex: "sparkle"
        case .claude: "bubble.left.and.bubble.right"
        case .deepseek: "water.waves"
        case .kimi, .kimiInternational: "moon.stars"
        case .openrouter: "point.3.connected.trianglepath.dotted"
        case .minimax, .minimaxInternational: "bolt"
        case .openai: "hexagon"
        case .anthropic: "a.circle"
        case .copilot: "chevron.left.forwardslash.chevron.right"
        }
    }

    @ViewBuilder
    private var selectedTabContent: some View {
        switch activeTab {
        case .quota:
            quotaContent
        case .usage:
            usageContent
        case .notch:
            notchDisplayContent
        }
    }

    @ViewBuilder
    private var quotaContent: some View {
        if let snapshot = inspectedSnapshot {
            VStack(alignment: .leading, spacing: 12) {
                if !snapshot.limits.isEmpty {
                    Text("额度窗口")
                        .font(.subheadline.weight(.semibold))

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(snapshot.limits) { limit in
                            AIUsageQuotaCard(limit: limit)
                        }
                    }
                }

                let balanceMetrics = snapshot.metrics.filter { $0.kind == .balance || $0.kind == .credits }
                if !balanceMetrics.isEmpty {
                    Text("余额与 credits")
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, snapshot.limits.isEmpty ? 0 : 4)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(balanceMetrics) { metric in
                            AIUsageMetricCard(metric: metric)
                        }
                    }
                }

                if snapshot.limits.isEmpty {
                    AIUsageEmptyCard(
                        symbol: "gauge.with.dots.needle.67percent",
                        title: "此连接未提供套餐额度，可选择余额 / 消费",
                        message: inspected.provider.guidance
                    )
                }
            }
        } else {
            AIUsageEmptyCard(
                symbol: "gauge.with.dots.needle.67percent",
                title: "暂无数据",
                message: inspectedHealth.message
            )
        }
    }

    @ViewBuilder
    private var usageContent: some View {
        if let snapshot = inspectedSnapshot {
            VStack(alignment: .leading, spacing: 12) {
                if !snapshot.metrics.isEmpty {
                    Text("当前用量")
                        .font(.subheadline.weight(.semibold))

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(snapshot.metrics) { metric in
                            AIUsageMetricCard(metric: metric)
                        }
                    }
                }

                if !snapshot.limits.isEmpty {
                    AIUsageCard {
                        VStack(alignment: .leading, spacing: 13) {
                            Text("额度窗口使用")
                                .font(.subheadline.weight(.semibold))
                            ForEach(snapshot.limits) { limit in
                                AIUsageUsageRow(limit: limit)
                            }
                        }
                    }
                }

                if snapshot.metrics.isEmpty && snapshot.limits.isEmpty {
                    AIUsageEmptyCard(
                        symbol: "chart.bar",
                        title: "暂无数据",
                        message: inspectedHealth.message
                    )
                }

                if !snapshot.note.isEmpty {
                    AIUsageCard {
                        Label(LocalizedStringKey(snapshot.note), systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else {
            AIUsageEmptyCard(
                symbol: "chart.bar",
                title: "暂无数据",
                message: inspectedHealth.message
            )
        }
    }

    private var notchDisplayContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            AIUsageCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("显示平台与账户")
                        .font(.subheadline.weight(.semibold))

                    Picker("显示平台与账户", selection: $usage.selectedID) {
                        ForEach(usage.connections) { connection in
                            Text(model.localized(connection.name) + " · "
                                + model.localized(connection.provider.title))
                                .tag(connection.id)
                        }
                    }

                    Text("可以连接多个账户，刘海显示所选账户。平台未提供额度时会提示，可改选余额 / 消费；不会自动切换到其他账户。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            AIUsageCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("显示内容")
                        .font(.subheadline.weight(.semibold))

                    Picker("显示内容", selection: $model.codexDisplayMode) {
                        Text("套餐额度").tag(AppModel.CodexDisplayMode.weekly)
                        Text("余额 / 消费").tag(AppModel.CodexDisplayMode.balance)
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 8) {
                        Button {
                            model.setLeftWingContent(.codex)
                        } label: {
                            Label(
                                "显示在左侧",
                                systemImage: model.leftWingContent == .codex ? "checkmark.circle.fill" : "circle"
                            )
                        }
                        .buttonStyle(.bordered)

                        Button {
                            model.setRightWingContent(.codex)
                        } label: {
                            Label(
                                "显示在右侧",
                                systemImage: model.rightWingContent == .codex ? "checkmark.circle.fill" : "circle"
                            )
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            AIUsageCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("额度圆环布局")
                        .font(.subheadline.weight(.semibold))

                    Picker("额度圆环布局", selection: $model.codexRingLayout) {
                        ForEach(CodexRingLayout.allCases) { layout in
                            Text(model.localized(layout.title)).tag(layout)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(model.localized(model.codexRingLayout.legend))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var connectionSettings: some View {
        AIUsageCard {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    Text(LocalizedStringKey(inspected.provider.guidance))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button("立即刷新") { refreshInspected() }
                            .disabled(!inspected.enabled)
                        if inspected.provider == .codex {
                            Button("重新连接") { model.reconnectCodex() }
                        }
                        Spacer()
                        if inspected.id != AIUsageConnection.codexID {
                            Button("移除连接", role: .destructive) { removeTarget = inspected }
                        }
                    }

                    if inspected.provider != .codex {
                        Toggle(
                            "启用此连接",
                            isOn: Binding(
                                get: { inspected.enabled },
                                set: { usage.setEnabled($0, for: inspected) }
                            )
                        )
                    }

                    if inspected.provider == .claude {
                        Toggle(
                            "连接 Claude Code 状态栏",
                            isOn: Binding(
                                get: { ClaudeUsageBridge.enabled },
                                set: { usage.setClaudeBridge($0) }
                            )
                        )
                        Text("开启会备份 Claude 设置，并保留原状态栏输出；关闭会恢复。只同步额度、会话估算成本和更新时间。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !inspected.provider.isLocal {
                        DisclosureGroup("更新凭证") {
                            SecureField("新的 API Key / Token", text: $replacement)
                            Button("保存到钥匙串") {
                                usage.replaceKey(replacement, for: inspected)
                                replacement = ""
                            }
                            .disabled(replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    if inspected.provider == .codex {
                        DisclosureGroup("客户端与路径") {
                            LabeledContent("客户端版本", value: model.codexClientVersion ?? "尚未识别")
                            Text(model.codexExecutablePath.isEmpty ? "未找到可执行文件" : model.codexExecutablePath)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            TextField("指定可执行文件路径（留空自动发现）", text: $codexPath)
                            HStack {
                                Button("选择文件…") {
                                    let panel = NSOpenPanel()
                                    panel.canChooseDirectories = false
                                    panel.canChooseFiles = true
                                    panel.allowsMultipleSelection = false
                                    panel.showsHiddenFiles = true
                                    if panel.runModal() == .OK { codexPath = panel.url?.path ?? "" }
                                }
                                Button("应用并重新连接") {
                                    UserDefaults.standard.set(
                                        codexPath.trimmingCharacters(in: .whitespacesAndNewlines),
                                        forKey: "aiUsage.codexExecutable"
                                    )
                                    model.reconnectCodex()
                                }
                            }
                            Text("自动发现已安装应用、新旧应用目录、PATH 和常见 CLI 安装位置；不可连接时继续尝试其他路径。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 10)
            } label: {
                Label("连接设置与诊断", systemImage: "gearshape.2")
                    .font(.callout.weight(.semibold))
            }
        }
    }

    private func refreshInspected() {
        if inspected.provider == .codex { model.reconnectCodex() }
        else { usage.refresh(inspected) }
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加平台连接").font(.title2.weight(.semibold))
            Picker("平台", selection: $provider) {
                ForEach(AIUsageProvider.allCases.filter { $0 != .codex }) { value in
                    Text(LocalizedStringKey(value.title)).tag(value)
                }
            }
            Text(LocalizedStringKey(provider.guidance))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("账户名称（可选）", text: $name)
            if !provider.isLocal {
                SecureField("API Key / Token", text: $secret)
                Text("仅保存在本机钥匙串，不进入诊断报告。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if provider == .copilot { TextField("GitHub 用户名", text: $context) }
            if let feedback = usage.feedback {
                Text(LocalizedStringKey(feedback))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("取消") {
                    secret = ""
                    adding = false
                }
                Spacer()
                Button("添加连接") {
                    let before = Set(usage.connections.map(\.id))
                    usage.add(provider: provider, name: name, secret: secret, context: context)
                    if let connection = usage.connections.first(where: { !before.contains($0.id) }) {
                        inspectedID = connection.id
                        secret = ""
                        adding = false
                    } else if provider.isLocal,
                              let connection = usage.connections.first(where: { $0.provider == provider }) {
                        inspectedID = connection.id
                        adding = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!provider.isLocal && secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(26)
        .frame(width: 480)
        .onChange(of: provider) { _, _ in
            secret = ""
            usage.feedback = nil
        }
    }
}
