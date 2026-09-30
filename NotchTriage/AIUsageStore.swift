import Combine
import Foundation

@MainActor
final class AIUsageStore: ObservableObject {
    @Published private(set) var connections: [AIUsageConnection]
    @Published private(set) var snapshots: [String: AIUsageSnapshot] = [:]
    @Published private(set) var health: [String: ServiceHealth] = [:]
    @Published var selectedID: String = AIUsageConnection.codexID {
        didSet { defaults.set(selectedID, forKey: "aiUsage.selectedConnection") }
    }
    @Published var feedback: String?
    private let defaults: UserDefaults
    private var tasks: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]
    var selected: AIUsageConnection { connections.first { $0.id == selectedID } ?? .codex }
    var selectedSnapshot: AIUsageSnapshot? { snapshots[selected.id] }
    var selectedHealth: ServiceHealth { status(for: selected) }
    var selectedHasValue: Bool { selectedSnapshot?.preferredMetric != nil || selectedSnapshot?.note == "credits 无上限" }
    var selectedSymbol: String {
        if isStale(selected) { return "exclamationmark" }
        guard let metric = selectedSnapshot?.preferredMetric else { return selectedSnapshot?.note == "credits 无上限" ? "infinity" : "questionmark" }
        if metric.kind == .credits { return "creditcard" }
        if metric.unit == "CNY" { return "yensign" }
        if metric.unit == "USD" { return "dollarsign" }
        return "number"
    }
    var selectedValue: (main: String, detail: String, hint: String) {
        let snapshot = selectedSnapshot
        let value = snapshot?.preferredMetric
        let stale = isStale(selected)
        return (value?.formatted ?? (snapshot?.note == "credits 无上限" ? "无限" : "—"),
                value?.title ?? (snapshot?.note.isEmpty == false ? snapshot!.note : selectedHealth.message),
                stale ? "上次读取 · 数据可能已过期" : (snapshot?.note.isEmpty == false ? snapshot!.note : selected.provider.title))
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "aiUsage.connections"),
           let restored = try? JSONDecoder().decode([AIUsageConnection].self, from: data) {
            var ids = Set<String>()
            connections = restored.filter { ids.insert($0.id).inserted && $0.id != AIUsageConnection.codexID && !$0.provider.isLocal }
            connections.insert(.codex, at: 0)
            if let claude = restored.first(where: { $0.provider == .claude }) { connections.append(claude) }
        } else { connections = [.codex] }
        let preferred = defaults.string(forKey: "aiUsage.selectedConnection") ?? AIUsageConnection.codexID
        selectedID = connections.contains { $0.id == preferred } ? preferred : AIUsageConnection.codexID
    }
    func status(for connection: AIUsageConnection) -> ServiceHealth {
        guard connection.enabled else { return .warning("连接已停用") }
        return health[connection.id] ?? .warning(connection.provider.isLocal ? "等待连接" : "尚未读取")
    }
    func isStale(_ connection: AIUsageConnection) -> Bool {
        guard let snapshot = snapshots[connection.id] else { return false }
        if snapshot.isExpired() { return true }
        if case .ready = status(for: connection) { return false }
        return true
    }
    private func save() {
        if let data = try? JSONEncoder().encode(connections) { defaults.set(data, forKey: "aiUsage.connections") }
    }
    func add(provider: AIUsageProvider, name: String, secret: String, context: String) {
        do {
            if provider.isLocal, let existing = connections.first(where: { $0.provider == provider }) {
                selectedID = existing.id; return
            }
            var connection = AIUsageConnection(provider: provider, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
            if connection.name.isEmpty { connection.name = provider.title }
            connection.context = context.trimmingCharacters(in: .whitespacesAndNewlines)
            if !provider.isLocal {
                let token = secret.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty, token.count <= 4096, !token.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else { throw AIUsageError.noKey }
                _ = try AIUsageAPI.endpoint(connection)
                try AIUsageKeychain.save(token, for: connection.id)
            }
            connections.append(connection); save()
            feedback = provider.isLocal ? "已添加本机连接" : "已添加连接；凭证仅保存在本机钥匙串"
            refresh(connection)
        } catch { feedback = error.localizedDescription }
    }
    func remove(_ connection: AIUsageConnection) {
        guard connection.id != AIUsageConnection.codexID else { return }
        do {
            if connection.provider == .claude { try ClaudeUsageBridge.uninstall() }
            cancel(connection.id)
            AIUsageKeychain.remove(connection.id)
            snapshots.removeValue(forKey: connection.id); health.removeValue(forKey: connection.id)
            connections.removeAll { $0.id == connection.id }; save()
            if selectedID == connection.id { selectedID = AIUsageConnection.codexID }
            feedback = "已移除连接"
        } catch { feedback = error.localizedDescription }
    }
    func setEnabled(_ enabled: Bool, for connection: AIUsageConnection) {
        guard connection.provider != .codex, let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[index].enabled = enabled; cancel(connection.id); save()
        if enabled { refresh(connections[index]) }
    }
    func replaceKey(_ secret: String, for connection: AIUsageConnection) {
        do {
            let token = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, token.count <= 4096, !token.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else { throw AIUsageError.noKey }
            try AIUsageKeychain.save(token, for: connection.id)
            cancel(connection.id); snapshots.removeValue(forKey: connection.id)
            feedback = "凭证已更新"; refresh(connection)
        } catch { feedback = error.localizedDescription }
    }
    func setClaudeBridge(_ enabled: Bool) {
        do {
            if enabled { try ClaudeUsageBridge.install() } else { try ClaudeUsageBridge.uninstall() }
            for connection in connections where connection.provider == .claude {
                snapshots.removeValue(forKey: connection.id); refresh(connection)
            }
            feedback = enabled ? "已开启；重启已有 Claude Code 会话后使用即可同步" : "已恢复原状态栏配置"
        } catch { feedback = "无法修改 Claude 状态栏连接，请检查设置文件权限" }
    }
    func acceptCodex(limits: [CodexLimitBucket], credits: CodexCreditsBalance?) {
        var metrics: [AIUsageMetric] = []
        if let credits, credits.hasCredits, !credits.unlimited, let value = credits.credits {
            metrics.append(.init(title: "Credits 余额", amount: value, unit: "credits", kind: .credits))
            if let usd = credits.estimatedUSD { metrics.append(.init(title: "美元估算（25 credits ≈ US$1）", amount: usd, unit: "USD", kind: .estimate)) }
        }
        var snapshot = AIUsageSnapshot(limits: limits, metrics: metrics, source: "本机 Codex App Server")
        if credits?.unlimited == true { snapshot.note = "credits 无上限" }
        else if credits?.hasCredits == false { snapshot.note = "当前没有可用 credits" }
        else if credits == nil { snapshot.note = "平台暂未返回 credits" }
        snapshots[AIUsageConnection.codexID] = snapshot
    }
    func updateCodexHealth(_ value: ServiceHealth) { health[AIUsageConnection.codexID] = value }
    func invalidateCodex() { snapshots.removeValue(forKey: AIUsageConnection.codexID) }
    func refreshAll() {
        for connection in connections where connection.provider != .codex && connection.enabled { refresh(connection) }
        objectWillChange.send() // Time-based freshness must update even without new samples.
    }
    func refresh(_ connection: AIUsageConnection) {
        guard connection.provider != .codex, connection.enabled, tasks[connection.id] == nil else { return }
        let generation = UUID(); generations[connection.id] = generation
        health[connection.id] = .loading("正在读取用量")
        tasks[connection.id] = Task { [weak self] in
            guard let self else { return }
            defer { if self.generations[connection.id] == generation { self.tasks[connection.id] = nil } }
            do {
                let snapshot: AIUsageSnapshot
                if connection.provider == .claude { snapshot = try await ClaudeUsageBridge.read() }
                else {
                    guard let secret = AIUsageKeychain.read(connection.id), !secret.isEmpty else { throw AIUsageError.noKey }
                    snapshot = try await AIUsageAPI.read(connection, secret: secret)
                }
                guard !Task.isCancelled, self.generations[connection.id] == generation else { return }
                self.snapshots[connection.id] = snapshot
                self.health[connection.id] = snapshot.isExpired() ? .warning("会话数据已过期，等待下一次正常响应") : .ready("已读取用量")
            } catch {
                guard !Task.isCancelled, self.generations[connection.id] == generation else { return }
                if connection.provider == .claude { self.snapshots.removeValue(forKey: connection.id) }
                self.health[connection.id] = .failed(error is AIUsageError ? error.localizedDescription : "网络读取失败，请检查连接后重试")
            }
        }
    }
    private func cancel(_ id: String) { tasks[id]?.cancel(); tasks[id] = nil; generations[id] = UUID() }
    func stop() { for id in Array(tasks.keys) { cancel(id) } }
}
