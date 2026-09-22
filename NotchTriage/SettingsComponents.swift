import AppKit
import SwiftUI

struct SettingsPage<Content: View>: View {
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

struct SettingsGroup<Content: View>: View {
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

struct SettingsRowLabel: View {
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

struct SettingsStatusRow: View {
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

struct WingPreviewCard: View {
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

struct LiquidGlassStylePreview: View {
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
            .nativeLiquidGlassSurface(
                level: level,
                cornerRadius: 19,
                contentSize: CGSize(width: 290, height: 58)
            )
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

struct RingThemeSwatch: View {
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

struct AdvancedRingAppearanceView: View {
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

struct RingStyleEditor: View {
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
