import SwiftUI

struct AIUsageSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var usage: AIUsageStore
    @State private var inspectedID = AIUsageConnection.codexID
    @State private var adding = false
    @State private var provider = AIUsageProvider.claude
    @State private var name = ""
    @State private var secret = ""
    @State private var context = ""
    @State private var replacement = ""
    @State private var codexPath = UserDefaults.standard.string(forKey: "aiUsage.codexExecutable") ?? ""
    @State private var removeTarget: AIUsageConnection?
    init(model: AppModel) { self.model = model; usage = model.aiUsage }
    private var inspected: AIUsageConnection { usage.connections.first { $0.id == inspectedID } ?? .codex }

    var body: some View {
        SettingsPage(title: "AI 套餐用量", subtitle: "查看订阅额度、API 余额和消费，并选择在刘海中显示的账户。", symbol: "gauge.with.dots.needle.67percent") {
            SettingsGroup(title: "平台与账户") {
                ForEach(usage.connections) { connection in
                    Button {
                        inspectedID = connection.id; replacement = ""
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: usage.status(for: connection).symbol)
                                .foregroundStyle(Color(nsColor: usage.status(for: connection).color))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.localized(connection.name)).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                                Text(LocalizedStringKey(connection.provider.title)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if usage.selectedID == connection.id { Text("刘海显示").font(.caption).foregroundStyle(.tint) }
                            Image(systemName: inspectedID == connection.id ? "chevron.down" : "chevron.right").font(.caption)
                        }
                        .padding(10)
                        .background(inspectedID == connection.id ? Color.accentColor.opacity(0.09) : Color.clear, in: .rect(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.localized(connection.name) + "，" + model.localized(usage.status(for: connection).message))
                }
                Button { adding = true; secret = ""; name = ""; context = ""; usage.feedback = nil } label: {
                    Label("添加平台连接", systemImage: "plus.circle")
                }
            }

            SettingsGroup(title: "连接状态") {
                Label(LocalizedStringKey(usage.status(for: inspected).message), systemImage: usage.status(for: inspected).symbol)
                    .foregroundStyle(Color(nsColor: usage.status(for: inspected).color))
                Text(LocalizedStringKey(inspected.provider.guidance)).font(.caption).foregroundStyle(.secondary)
                if let snapshot = usage.snapshots[inspected.id] {
                    LabeledContent("最后成功读取", value: snapshot.updatedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(model.appLanguage.locale)))
                    if usage.isStale(inspected) {
                        Label("显示上次数据，可能已过期", systemImage: "clock.badge.exclamationmark")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text(LocalizedStringKey(snapshot.source)).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("立即刷新") { refreshInspected() }.disabled(!inspected.enabled)
                    if inspected.provider == .codex { Button("重新连接") { model.reconnectCodex() } }
                    Spacer()
                    if inspected.id != AIUsageConnection.codexID {
                        Button("移除连接", role: .destructive) { removeTarget = inspected }
                    }
                }
                if inspected.provider != .codex {
                    Toggle("启用此连接", isOn: Binding(get: { inspected.enabled }, set: { usage.setEnabled($0, for: inspected) }))
                }
                if inspected.provider == .claude {
                    Toggle("连接 Claude Code 状态栏", isOn: Binding(get: { ClaudeUsageBridge.enabled }, set: { usage.setClaudeBridge($0) }))
                    Text("开启会备份 Claude 设置，并保留原状态栏输出；关闭会恢复。只同步额度、会话估算成本和更新时间。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !inspected.provider.isLocal {
                    DisclosureGroup("更新凭证") {
                        SecureField("新的 API Key / Token", text: $replacement)
                        Button("保存到钥匙串") { usage.replaceKey(replacement, for: inspected); replacement = "" }
                            .disabled(replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if inspected.provider == .codex {
                    DisclosureGroup("客户端与路径") {
                        LabeledContent("客户端版本", value: model.codexClientVersion ?? "尚未识别")
                        Text(model.codexExecutablePath.isEmpty ? "未找到可执行文件" : model.codexExecutablePath)
                            .font(.caption.monospaced()).textSelection(.enabled)
                        TextField("指定可执行文件路径（留空自动发现）", text: $codexPath)
                        HStack {
                            Button("选择文件…") {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = false; panel.canChooseFiles = true
                                panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
                                if panel.runModal() == .OK { codexPath = panel.url?.path ?? "" }
                            }
                            Button("应用并重新连接") {
                                UserDefaults.standard.set(codexPath.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "aiUsage.codexExecutable")
                                model.reconnectCodex()
                            }
                        }
                        Text("自动发现已安装应用、新旧应用目录、PATH 和常见 CLI 安装位置；不可连接时继续尝试其他路径。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            SettingsGroup(title: "当前用量") {
                AIUsageDetailsView(snapshot: usage.snapshots[inspected.id], health: usage.status(for: inspected))
            }

            SettingsGroup(title: "刘海显示") {
                Picker("显示平台与账户", selection: $usage.selectedID) {
                    ForEach(usage.connections) { connection in
                        Text(model.localized(connection.name) + " · " + model.localized(connection.provider.title)).tag(connection.id)
                    }
                }
                Picker("显示内容", selection: $model.codexDisplayMode) {
                    Text("套餐额度").tag(AppModel.CodexDisplayMode.weekly)
                    Text("余额 / 消费").tag(AppModel.CodexDisplayMode.balance)
                }
                Text("可以连接多个账户，刘海显示所选账户。平台未提供额度时会提示，可改选余额 / 消费；不会自动切换到其他账户。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text((model.appLanguage == .english ? "Current: " : "当前：") + model.localized(usage.selected.name)).font(.callout.weight(.medium))
                    Spacer()
                    Button("显示在左侧") { model.setLeftWingContent(.codex) }
                    Button("显示在右侧") { model.setRightWingContent(.codex) }
                }
                Picker("额度圆环布局", selection: $model.codexRingLayout) {
                    ForEach(CodexRingLayout.allCases) { layout in Text(model.localized(layout.title)).tag(layout) }
                }
                .pickerStyle(.segmented)
                Text(model.localized(model.codexRingLayout.legend)).font(.caption).foregroundStyle(.secondary)
            }
            if let feedback = usage.feedback { Text(LocalizedStringKey(feedback)).font(.caption).foregroundStyle(.secondary) }
            Text("Gemini、GLM、Cursor 等平台的自动采集仍待验证，当前不显示为可连接平台。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { inspectedID = usage.selectedID; usage.refreshAll() }
        .sheet(isPresented: $adding) { addSheet }
        .alert("移除平台连接？", isPresented: Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } })) {
            Button("取消", role: .cancel) { removeTarget = nil }
            Button("移除", role: .destructive) {
                if let connection = removeTarget { usage.remove(connection) }
                removeTarget = nil; inspectedID = AIUsageConnection.codexID
            }
        } message: { Text("会删除本机保存的凭证和连接；Claude 连接还会恢复原状态栏配置。") }
    }
    private func refreshInspected() {
        if inspected.provider == .codex { model.reconnectCodex() }
        else { usage.refresh(inspected) }
    }
    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加平台连接").font(.title2.weight(.semibold))
            Picker("平台", selection: $provider) {
                ForEach(AIUsageProvider.allCases.filter { $0 != .codex }) { value in Text(LocalizedStringKey(value.title)).tag(value) }
            }
            Text(LocalizedStringKey(provider.guidance)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("账户名称（可选）", text: $name)
            if !provider.isLocal {
                SecureField("API Key / Token", text: $secret)
                Text("仅保存在本机钥匙串，不进入诊断报告。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if provider == .copilot { TextField("GitHub 用户名", text: $context) }
            if let feedback = usage.feedback { Text(LocalizedStringKey(feedback)).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("取消") { secret = ""; adding = false }
                Spacer()
                Button("添加连接") {
                    let before = Set(usage.connections.map(\.id))
                    usage.add(provider: provider, name: name, secret: secret, context: context)
                    if let connection = usage.connections.first(where: { !before.contains($0.id) }) {
                        inspectedID = connection.id; secret = ""; adding = false
                    } else if provider.isLocal, let connection = usage.connections.first(where: { $0.provider == provider }) {
                        inspectedID = connection.id; adding = false
                    }
                }.buttonStyle(.borderedProminent)
                    .disabled(!provider.isLocal && secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(26).frame(width: 480)
        .onChange(of: provider) { _, _ in secret = ""; usage.feedback = nil }
    }
}

struct AIUsageDetailsView: View {
    @Environment(\.locale) private var locale
    private var isEnglish: Bool { locale.identifier.hasPrefix("en") }
    let snapshot: AIUsageSnapshot?
    let health: ServiceHealth
    var body: some View {
        if let snapshot {
            ForEach(snapshot.limits) { limit in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(isEnglish ? (limit.windowMinutes >= 1440 ? "\(limit.windowMinutes / 1440)d" : "\(limit.windowMinutes / 60)h") : (limit.name == "Codex" ? limit.windowLabel : limit.name))
                        Spacer()
                        Text(isEnglish ? "\(Int(limit.remainingPercent.rounded()))% remaining" : "剩余 \(Int(limit.remainingPercent.rounded()))%")
                    }.font(.callout)
                    ProgressView(value: limit.remainingFraction)
                    if let reset = limit.resetsAt {
                        Text((isEnglish ? "Resets: " : "重置：") + reset.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(snapshot.metrics) { metric in LabeledContent { Text(metric.formatted) } label: { Text(LocalizedStringKey(metric.title)) } }
            if !snapshot.note.isEmpty { Text(LocalizedStringKey(snapshot.note)).font(.caption).foregroundStyle(.secondary) }
            if snapshot.limits.isEmpty && snapshot.metrics.isEmpty && snapshot.note.isEmpty { Text("平台暂未提供用量数据") }
        } else { Text(LocalizedStringKey(health.message)).font(.callout).foregroundStyle(.secondary) }
    }
}
