import SwiftUI

enum CodexRingLayout: String, CaseIterable, Identifiable, Sendable {
    case concentric
    case longAndShort
    case leftAndRight

    var id: String { rawValue }

    static func restored(from value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? .concentric
    }

    var title: String {
        switch self {
        case .concentric: return "内外双弧"
        case .longAndShort: return "长弧＋底部短弧"
        case .leftAndRight: return "左右双弧"
        }
    }

    var legend: String {
        switch self {
        case .concentric: return "外圈：5h · 内圈：周额度"
        case .longAndShort: return "长弧：5h · 底部短弧：周额度"
        case .leftAndRight: return "左弧：5h · 右弧：周额度"
        }
    }
}

/// Shared by the compact notch, hover view and settings preview.
struct CodexQuotaRings: View {
    let layout: CodexRingLayout
    let fiveHour: Double
    let weekly: Double?
    let style: RingStyle
    var diameter: CGFloat = 22

    var body: some View {
        ZStack {
            switch layout {
            case .concentric:
                arc(progress: fiveHour, start: -90, sweep: 360, width: diameter == 20 ? 2.2 : 2.7)
                if let weekly {
                    arc(progress: weekly, start: -90, sweep: 360, width: diameter == 20 ? 1.6 : 1.8)
                        .frame(width: diameter == 20 ? 13 : diameter * 14 / 22,
                               height: diameter == 20 ? 13 : diameter * 14 / 22)
                        .opacity(0.72)
                }
            case .longAndShort:
                arc(progress: fiveHour, start: 144, sweep: 252, width: 2.7)
                arc(progress: weekly ?? 0, start: 60, sweep: 60, width: 2.7, consumeFromStart: true)
                    .opacity(0.72)
            case .leftAndRight:
                arc(progress: fiveHour, start: 102, sweep: 156, width: 2.7)
                arc(progress: weekly ?? 0, start: -78, sweep: 156, width: 2.7, consumeFromStart: true)
                    .opacity(0.72)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    private func arc(
        progress: Double, start: Double, sweep: Double, width: CGFloat,
        consumeFromStart: Bool = false
    ) -> some View {
        let fraction = progress.isFinite ? min(1, max(0, progress)) : 0
        let length = sweep / 360
        // Keep the surviving end anchored: left for the bottom arc, bottom
        // for the right arc. Their consumption then matches the other arc.
        let lower = consumeFromStart ? length * (1 - fraction) : 0
        let upper = consumeFromStart ? length : length * fraction
        return ZStack {
            Circle().trim(from: 0, to: sweep / 360)
                .stroke(style.track.color, style: StrokeStyle(lineWidth: width, lineCap: .round))
            if fraction > 0 {
                Circle().trim(from: lower, to: upper)
                    .stroke(style.shapeStyle, style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
        }
        .rotationEffect(.degrees(start))
    }
}
