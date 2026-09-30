import Foundation
import CoreFoundation

/// Stable provider IDs and existing `codex` preferences survive upgrades.
enum AIUsageProvider: String, CaseIterable, Codable, Identifiable {
    case codex, claude, deepseek, kimi, kimiInternational, openrouter
    case minimax, minimaxInternational, openai, anthropic, copilot
    var id: String { rawValue }
    var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .deepseek: return "DeepSeek API"
        case .kimi: return "Kimi API · 中国"
        case .kimiInternational: return "Kimi API · 国际"
        case .openrouter: return "OpenRouter"
        case .minimax: return "MiniMax · 中国"
        case .minimaxInternational: return "MiniMax · 国际"
        case .openai: return "OpenAI API"
        case .anthropic: return "Anthropic API"
        case .copilot: return "GitHub Copilot"
        }
    }
    var isLocal: Bool { self == .codex || self == .claude }
    var guidance: String {
        switch self {
        case .codex: return "读取本机已登录的 Codex：套餐额度、重置时间和 credits。"
        case .claude: return "Claude Code 2.1.251+ 的 Pro/Max 额度。开启连接后，正常会话首次响应会更新数据；无需额外发送提示词。"
        case .deepseek: return "使用 API Key 查询可用余额、赠金与充值余额。"
        case .kimi, .kimiInternational: return "查询 API 可用余额、现金和代金券。国内与国际 Key 独立；不代表 Kimi Code 订阅额度。"
        case .openrouter: return "Management Key 可查询账户余额；普通 API Key 仅查询此 Key 的预算和消费。"
        case .minimax, .minimaxInternational: return "使用 Token Plan 订阅 Key 查询套餐用量；不是按量付费 API 钱包。"
        case .openai: return "使用具有组织消费查询权限的 Admin Key，查看最近 30 天消费；不是预付钱包余额。"
        case .anthropic: return "使用组织 Admin API Key，查看最近 30 天消费。个人账户不支持该 Admin API。"
        case .copilot: return "使用具有 Plan 读取权限的个人 Token 和 GitHub 用户名，查看本月 premium requests 消费；组织分配的许可不在个人报告内。"
        }
    }
}

struct AIUsageConnection: Codable, Identifiable, Equatable {
    static let codexID = "local-codex"
    var id = UUID().uuidString
    var provider: AIUsageProvider
    var name: String
    var enabled = true
    var context = "" // Only a GitHub username; credentials live in Keychain.
    static let codex = Self(id: codexID, provider: .codex, name: "本机 Codex")
}

struct AIUsageMetric: Equatable, Identifiable {
    enum Kind: String { case balance, spend, estimate, credits, count }
    var id: String { title + unit + kind.rawValue }
    let title: String
    let amount: Decimal
    let unit: String
    let kind: Kind
    var formatted: String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = kind == .count ? 2 : 4
        let value = formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "—"
        switch unit {
        case "USD": return "US$" + value
        case "CNY": return "¥" + value
        default: return value + " " + unit
        }
    }
}

struct AIUsageSnapshot: Equatable {
    var limits: [CodexLimitBucket] = []
    var metrics: [AIUsageMetric] = []
    var updatedAt = Date()
    var source: String
    var note = ""
    var preferredMetric: AIUsageMetric? {
        metrics.first { $0.kind == .balance } ?? metrics.first { $0.kind == .credits }
            ?? metrics.first { $0.kind == .spend } ?? metrics.first
    }
    func isExpired(at date: Date = Date()) -> Bool { date.timeIntervalSince(updatedAt) > 180 }
}

/// Accept only complete, finite decimal strings. Decimal(string:) otherwise accepts prefixes.
enum AIUsageNumber {
    static func decimal(_ value: Any?) -> Decimal? {
        let string: String
        if let value = value as? String { string = value.trimmingCharacters(in: .whitespacesAndNewlines) }
        else if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { string = value.stringValue }
        else { return nil }
        guard string.range(of: #"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN, NSDecimalNumber(decimal: value).doubleValue.isFinite else { return nil }
        return value
    }
    static func double(_ value: Any?) -> Double? {
        decimal(value).map { NSDecimalNumber(decimal: $0).doubleValue }
    }
}
