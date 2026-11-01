import SwiftUI

struct AIUsageCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(15)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(.primary.opacity(0.08), lineWidth: 0.6)
            }
    }
}

struct AIUsageStatusBadge: View {
    let health: ServiceHealth
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: health.symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(LocalizedStringKey(title))
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(Color(nsColor: health.color))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: health.color).opacity(0.1), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct AIUsageQuotaCard: View {
    @Environment(\.locale) private var locale
    let limit: CodexLimitBucket

    private var usedPercent: Double {
        guard limit.usedPercent.isFinite else { return 0 }
        return min(100, max(0, limit.usedPercent))
    }

    private var windowLabel: String {
        if limit.windowMinutes >= 1_440, limit.windowMinutes.isMultiple(of: 1_440) {
            return "\(limit.windowMinutes / 1_440)d"
        }
        if limit.windowMinutes >= 60, limit.windowMinutes.isMultiple(of: 60) {
            return "\(limit.windowMinutes / 60)h"
        }
        return "\(limit.windowMinutes)m"
    }

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .stroke(.primary.opacity(0.10), lineWidth: 5)
                if usedPercent > 0 {
                    Circle()
                        .trim(from: 0, to: usedPercent / 100)
                        .stroke(
                            AngularGradient(
                                colors: [Color.accentColor.opacity(0.45), Color.accentColor],
                                center: .center,
                                startAngle: .degrees(-90),
                                endAngle: .degrees(270)
                            ),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
                VStack(spacing: 0) {
                    Text("\(Int(usedPercent.rounded()))%")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("已用")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(limit.name))
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                Text(windowLabel)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                if let reset = limit.resetsAt {
                    Label(
                        reset.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)),
                        systemImage: "clock"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                } else {
                    Text("重置时间未提供")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct AIUsageMetricCard: View {
    let metric: AIUsageMetric

    private var symbol: String {
        switch metric.kind {
        case .balance: "creditcard"
        case .spend: "chart.line.uptrend.xyaxis"
        case .estimate: "sparkles"
        case .credits: "circle.hexagongrid"
        case .count: "number"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(LocalizedStringKey(metric.title))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            Text(metric.formatted)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct AIUsageUsageRow: View {
    let limit: CodexLimitBucket

    private var usedPercent: Double {
        guard limit.usedPercent.isFinite else { return 0 }
        return min(100, max(0, limit.usedPercent))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(LocalizedStringKey(limit.name))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(Int(usedPercent.rounded()))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: usedPercent, total: 100)
                .tint(.accentColor)
        }
    }
}

struct AIUsageEmptyCard: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        AIUsageCard {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 5) {
                    Text(LocalizedStringKey(title))
                        .font(.callout.weight(.semibold))
                    Text(LocalizedStringKey(message))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
