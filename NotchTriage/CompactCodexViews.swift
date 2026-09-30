import AppKit
import SwiftUI

struct CodexBalancePresentation: Equatable {
    enum State: Equatable {
        case connecting(message: String)
        case unlimited
        case unavailable
        case unknown
        case available(estimatedUSD: Decimal, credits: Decimal)
    }

    let state: State

    init(credits: CodexCreditsBalance?, healthMessage: String) {
        guard let credits else {
            let message = healthMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            state = .connecting(
                message: message.isEmpty ? "正在连接 Codex" : message
            )
            return
        }

        if credits.unlimited {
            state = .unlimited
        } else if !credits.hasCredits {
            state = .unavailable
        } else if let value = credits.credits,
                  let estimatedUSD = credits.estimatedUSD {
            state = .available(
                estimatedUSD: estimatedUSD,
                credits: value
            )
        } else {
            state = .unknown
        }
    }

    var estimatedUSDLabel: String {
        switch state {
        case .connecting:
            return "正在连接"
        case .unlimited:
            return "无限"
        case .unavailable:
            return "不可用"
        case .unknown:
            return "余额未知"
        case .available(let value, _):
            let formatted = Self.usdFormatter.string(
                from: NSDecimalNumber(decimal: value)
            ) ?? "US$—"
            return "≈ " + formatted
        }
    }

    var creditsLabel: String {
        switch state {
        case .connecting(let message):
            return message
        case .unlimited:
            return "credits 无上限"
        case .unavailable:
            return "当前没有可用 credits"
        case .unknown:
            return "credits 暂未返回"
        case .available(_, let value):
            let formatted = Self.creditsFormatter.string(
                from: NSDecimalNumber(decimal: value)
            ) ?? "—"
            return formatted + " credits"
        }
    }

    var hint: String {
        switch state {
        case .available:
            return "按 25 credits ≈ US$1"
        default:
            return "来自本机 Codex 会话"
        }
    }

    var accessibilityLabel: String {
        "Codex 余额，" + estimatedUSDLabel + "，" + creditsLabel
    }

    private static let usdFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static let creditsFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter
    }()
}

struct FileDropTargetContent: View {
    let acceptance: FileDropAcceptance
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.14), in: .rect(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(LocalizedStringKey(subtitle))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 38)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch acceptance {
        case .accepted:
            return "tray.and.arrow.down.fill"
        case .partial:
            return "exclamationmark.triangle.fill"
        case .rejected:
            return "circle.slash"
        }
    }

    private var tint: Color {
        switch acceptance {
        case .accepted:
            return .mint
        case .partial:
            return .yellow
        case .rejected:
            return .red
        }
    }

    private var title: String {
        let isEnglish = locale.identifier.hasPrefix("en")
        switch acceptance {
        case .accepted(let count):
            return isEnglish
                ? "Release to add \(count) item\(count == 1 ? "" : "s")"
                : "松手加入 \(count) 项"
        case .partial(let acceptedCount, let rejectedCount, _):
            return isEnglish
                ? "\(acceptedCount) item\(acceptedCount == 1 ? "" : "s") to add · \(rejectedCount) skipped"
                : "\(acceptedCount) 项可加入 · \(rejectedCount) 项跳过"
        case .rejected:
            return isEnglish ? "Cannot Add to Shelf" : "不能加入暂存架"
        }
    }

    private var subtitle: String {
        let isEnglish = locale.identifier.hasPrefix("en")
        switch acceptance {
        case .accepted:
            return isEnglish
                ? "Only references are saved; original files are not moved or copied"
                : "只保存引用，不会移动或复制原文件"
        case .partial(_, _, let reason), .rejected(_, let reason):
            return reason
        }
    }
}

struct CompactCodexContent: View {
    @ObservedObject var model: AppModel
    let limits: [CodexLimitBucket]
    let health: ServiceHealth
    let style: RingStyle

    private var fiveHour: CodexLimitBucket? {
        AppModel.fiveHourCodexLimit(from: model.aiUsage.selectedSnapshot?.limits ?? [])
    }

    private var weekly: CodexLimitBucket? {
        AppModel.weeklyCodexLimit(from: model.aiUsage.selectedSnapshot?.limits ?? [])
    }

    private var balance: (main: String, detail: String, hint: String) { model.aiUsage.selectedValue }
    private var valueLabel: String { model.aiUsage.selected.name + "，" + balance.main + "，" + balance.detail }


    var body: some View {
        AttentionRing(
            model: model,
            diameter: 22
        ) {
            switch model.codexDisplayMode {
            case .weekly:
                CodexQuotaRings(
                    layout: model.codexRingLayout,
                    fiveHour: fiveHour?.remainingFraction ?? 0,
                    weekly: weekly?.id != fiveHour?.id ? weekly?.remainingFraction : nil,
                    style: style
                )
            case .balance:
                ZStack {
                    UsageArc(
                        progress: model.aiUsage.selectedHasValue ? 1 : 0,
                        style: style,
                        lineWidth: 3.2
                    )

                    Image(systemName: model.aiUsage.selectedSymbol)
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                }
            }
        }
        .foregroundStyle(.white)
        .animation(NotchDesign.Motion.value, value: fiveHour?.remainingPercent)
        .animation(NotchDesign.Motion.value, value: weekly?.remainingPercent)
        .animation(NotchDesign.Motion.value, value: model.codexDisplayMode)
        .help(helpLabel)
        .accessibilityLabel(
            accessibilityLabel
        )
    }

    private var helpLabel: String {
        switch model.codexDisplayMode {
        case .weekly:
            return quotaLabel(separator: " · ")
        case .balance:
            return valueLabel + " · " + balance.hint
        }
    }

    private var accessibilityLabel: String {
        switch model.codexDisplayMode {
        case .weekly:
            return quotaLabel(separator: "，")
        case .balance:
            return valueLabel
        }
    }

    private func quotaLabel(separator: String) -> String {
        let labels = [
            fiveHour.map { "5 小时剩余 \(Int($0.remainingPercent.rounded()))%" },
            weekly.flatMap { bucket in
                bucket.id == fiveHour?.id
                    ? nil
                    : "周额度剩余 \(Int(bucket.remainingPercent.rounded()))%"
            }
        ].compactMap { $0 }

        guard !labels.isEmpty else {
            return model.aiUsage.selected.provider.title + separator + model.aiQuotaMessage
        }
        return model.aiUsage.selected.provider.title + " " + labels.joined(separator: separator) + (model.aiUsage.isStale(model.aiUsage.selected) ? separator + "上次数据 · 可能已过期" : "")
    }

}
