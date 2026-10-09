import AppKit
import SwiftUI

struct LyricsSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: LyricsStore
    @State private var previewWidth: CGFloat = 500
    @State private var previewPaused = false
    init(model: AppModel) { self.model = model; store = model.lyrics }
    var body: some View {
        SettingsPage(title: "歌词显示", subtitle: "让歌词在刘海下方随音乐流动。", symbol: "text.quote") {
            SettingsGroup(title: "实时示意") {
                Toggle("启用歌词显示", isOn: $store.appearance.enabled)
                HStack(spacing: 7) {
                    Circle().fill(store.document == nil ? Color.secondary : Color.green).frame(width: 6, height: 6)
                    Text(model.localized(store.status)).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    if store.media != .idle {
                        Text("播放器").foregroundStyle(.tertiary)
                        Text(model.localized(store.media.sourceName))
                    }
                    if let document = store.document {
                        if store.media != .idle {
                            Divider().frame(height: 12).padding(.horizontal, 4)
                        }
                        Text("歌词来源").foregroundStyle(.tertiary)
                        Text(model.localized(document.source))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                preview
                HStack {
                    Text("修改后立即预览").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { previewPaused.toggle() } label: {
                        Image(systemName: previewPaused ? "play.fill" : "pause.fill")
                    }.buttonStyle(.borderless)
                    .help(model.localized(previewPaused ? "继续示意" : "暂停示意"))
                    .accessibilityLabel(model.localized(previewPaused ? "继续示意" : "暂停示意"))
                    Button(store.previewing ? "结束刘海预览" : "在刘海下方预览 30 秒") { store.togglePreview() }
                }
            }
            SettingsGroup(title: "视觉与动画") {
                Picker("歌词视觉效果", selection: Binding(get: { store.appearance.style }, set: { store.appearance.visualStyle = $0 })) {
                    ForEach(LyricsVisualStyle.allCases, id: \.self) { style in
                        Text(LocalizedStringKey(style.title)).tag(style)
                    }
                }.pickerStyle(.segmented)
                Text(LocalizedStringKey(store.appearance.style.detail))
                    .font(.caption).foregroundStyle(.secondary)
                Picker("高亮形式", selection: $store.appearance.motion) {
                    ForEach(LyricsAnimation.allCases, id: \.self) { Text(LocalizedStringKey($0.title)).tag($0) }
                }.pickerStyle(.segmented)
                Text(LocalizedStringKey(motionDescription)).font(.caption).foregroundStyle(.secondary)
                if store.appearance.motion == .wave { slider("波浪高度", value: $store.appearance.lift, range: 0...40, suffix: "pt") }
                if store.appearance.motion == .dock {
                    slider("放大幅度", value: Binding(get: { store.appearance.dockAmount }, set: { store.appearance.dockScale = $0 }), range: 0.1...1.2, suffix: "")
                }
                DisclosureGroup("逐字时间轴") {
                    Toggle("无逐字数据时估算动画", isOn: Binding(get: { store.appearance.usesEstimatedTiming }, set: { store.appearance.estimatedAnimation = $0 }))
                    Text("估算会将整句时间分配给文字，不能保证与演唱同步。默认只对真实逐字数据播放逐字动画。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            SettingsGroup(title: "文字与位置") {
                Picker("字体", selection: $store.appearance.fontFamily) {
                    Text("系统字体").tag("System")
                    ForEach(NSFontManager.shared.availableFontFamilies.sorted(), id: \.self) { Text($0).tag($0) }
                }
                slider("字号", value: $store.appearance.fontSize, range: 8...120, suffix: "pt")
                Picker("中文显示", selection: Binding(get: { store.appearance.variant }, set: { store.appearance.chineseVariant = $0 })) {
                    ForEach(LyricsChineseVariant.allCases, id: \.self) { Text(LocalizedStringKey($0.title)).tag($0) }
                }
                Toggle("显示下一句", isOn: $store.appearance.showNext)
                slider("显示宽度", value: $store.appearance.width, range: 200...2000, suffix: "pt")
                slider("距刘海间隔", value: $store.appearance.gap, range: -30...160, suffix: "pt")
                DisclosureGroup("显示说明") {
                    Text("间隔按可见文字计算；长句保持单行并横向滚动，逐字歌词跟随演唱位置。刘海面板展开时暂时隐藏歌词。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            SettingsGroup(title: "更多外观选项") {
                DisclosureGroup {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(LyricsLightPreset.allCases.filter { $0 != .custom }, id: \.self) { preset in
                            presetCard(preset)
                        }
                    }
                    Text("预设只改变颜色与光晕强度，保留字号、位置和视觉效果。")
                        .font(.caption).foregroundStyle(.secondary)
                    ColorPicker("光效主色", selection: colorBinding(\.highlight))
                    ColorPicker("光效尾色", selection: Binding(get: { store.appearance.endColor.color }, set: {
                        store.appearance.glowEnd = RingColor($0); store.appearance.lightPreset = .custom
                    }))
                    ColorPicker("待唱颜色", selection: colorBinding(\.resting))
                    slider("光效强度", value: $store.appearance.glow, range: 0...1, suffix: "")
                    slider("柔光范围", value: Binding(get: { store.appearance.spread }, set: { store.appearance.glowSpread = $0 }), range: 0...1, suffix: "")
                        .disabled(store.appearance.glow == 0)
                    Toggle("呼吸光效", isOn: Binding(get: { store.appearance.hasBreathing }, set: { store.appearance.breathing = $0 }))
                        .disabled(store.appearance.glow == 0)
                } label: {
                    HStack {
                        Text("配色与光晕")
                        Spacer()
                        Text(LocalizedStringKey((store.appearance.lightPreset ?? .custom).title))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("两侧律动装饰", isOn: Binding(get: { store.appearance.hasOrnaments }, set: { store.appearance.ornaments = $0 }))
                if store.appearance.hasOrnaments {
                    DisclosureGroup("律动细节") {
                        Picker("律动样式", selection: Binding(get: { store.appearance.ornament }, set: { store.appearance.ornamentStyle = $0 })) {
                            ForEach(LyricsOrnamentStyle.allCases, id: \.self) { Text(LocalizedStringKey($0.title)).tag($0) }
                        }.pickerStyle(.segmented)
                        slider("装饰距文字", value: Binding(get: { store.appearance.sideGap }, set: { store.appearance.ornamentGap = $0 }), range: 0...160, suffix: "pt")
                        slider("单侧装饰宽度", value: Binding(get: { store.appearance.sideWidth }, set: { store.appearance.ornamentWidth = $0 }), range: 24...180, suffix: "pt")
                        slider("装饰高度", value: Binding(get: { store.appearance.sideHeight }, set: { store.appearance.ornamentHeight = $0 }), range: 8...120, suffix: "pt")
                        Toggle("启用真实频谱", isOn: Binding(get: { store.appearance.capturesSpectrum }, set: { store.appearance.spectrumEnabled = $0 }))
                        LyricsSpectrumStatus(spectrum: store.spectrum, model: model)
                        HStack {
                            Button("重试音频连接") { store.retrySpectrum() }.disabled(!store.appearance.capturesSpectrum || !store.appearance.enabled)
                            Button("系统音频权限设置") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                            }
                        }
                        Text("真实频谱分析系统输出音频，首次启用需要系统音频权限；音频不保存、不上传，也不使用麦克风。关闭歌词、暂停播放或锁屏时停止采集。未启用或没有信号时保持静止。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("预览中的频谱为示意动画；实际显示使用音频信号。系统“减少动态效果”会关闭律动动画。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            SettingsGroup(title: "歌词来源与同步") {
                if store.media != .idle { Text("\(store.media.title) · \(store.media.artist)").font(.callout).lineLimit(2) }
                HStack {
                    Button("重新查找") { store.retry() }.disabled(!store.appearance.enabled)
                    Button("导入歌词…") { store.importLyrics() }
                }
                slider("歌词提前量", value: $store.appearance.offset, range: -5...5, suffix: "s")
                DisclosureGroup("同步说明与隐私") {
                    Text("自动查询网易云音乐、QQ 音乐与 LRCLIB，会发送歌名和歌手，并用专辑和时长筛选版本。优先使用真实逐字时间轴；逐行数据默认整句显示。支持导入 LRC、增强 LRC、YRC 和解码后的 QRC。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("正值使歌词提前，负值使歌词延后。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("恢复歌词外观默认值") {
                var defaults = LyricsAppearance()
                defaults.enabled = store.appearance.enabled
                defaults.offset = store.appearance.offset
                store.appearance = defaults
            }.foregroundStyle(.secondary)
        }
    }
    private func colorBinding(_ key: WritableKeyPath<LyricsAppearance, RingColor>) -> Binding<Color> {
        Binding(get: { store.appearance[keyPath: key].color }, set: {
            store.appearance[keyPath: key] = RingColor($0)
            store.appearance.lightPreset = .custom
        })
    }
    private func presetCard(_ preset: LyricsLightPreset) -> some View {
        let selected = store.appearance.lightPreset == preset
        return Button {
            var appearance = store.appearance; appearance.apply(preset); store.appearance = appearance
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(LocalizedStringKey(preset.title)).font(.callout.weight(.semibold))
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(preset.colors.0.color) }
                }
                Text("让音乐流动").font(.system(size: 20, weight: .medium))
                    .foregroundStyle(LinearGradient(colors: [preset.colors.0.color, preset.colors.1.color], startPoint: .leading, endPoint: .trailing))
                    .shadow(color: preset.colors.0.color.opacity(preset == .clean ? 0 : 0.45), radius: 5)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.white)
            .background(LinearGradient(colors: [Color(red: 0.09, green: 0.13, blue: 0.21), Color(red: 0.14, green: 0.13, blue: 0.23)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? preset.colors.0.color.opacity(0.85) : Color.white.opacity(0.08), lineWidth: selected ? 1.5 : 0.5))
        }.buttonStyle(.plain)
        .accessibilityLabel(LocalizedStringKey(preset.title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var virtualWidth: CGFloat {
        min(LyricsDisplayMetrics.width(contentWidth: store.appearance.width, appearance: store.appearance), (NotchScreen.preferred?.frame.width ?? 1440) - 8)
    }
    private var preview: some View {
        let scale = min(1, previewWidth / virtualWidth)
        let lyricHeight = LyricsDocument.demo.lines.map {
            LyricsDisplayMetrics.height(document: .demo, time: $0.start, appearance: store.appearance, width: virtualWidth)
        }.max() ?? 140
        let height = model.menuBarHeight + store.appearance.gap - LyricsDisplayMetrics.topInset(store.appearance) + lyricHeight
        return GeometryReader { geometry in
            VStack(spacing: 0) {
                UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18)
                    .fill(.black).frame(width: model.notchWidth, height: model.menuBarHeight)
                LyricsDisplayView(document: .demo, appearance: store.appearance, elapsed: { _ in 0 }, playing: !previewPaused, demo: true)
                    .frame(width: virtualWidth, height: lyricHeight)
                    .padding(.top, store.appearance.gap - LyricsDisplayMetrics.topInset(store.appearance))
            }
            .frame(width: virtualWidth, height: height, alignment: .top)
            .scaleEffect(scale, anchor: .top)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .frame(height: min(600, max(80, height * scale)))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { previewWidth = $0 }
        .background(LinearGradient(colors: [Color(red: 0.1, green: 0.13, blue: 0.24), Color(red: 0.2, green: 0.14, blue: 0.29)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
        .clipped()
    }
    private var motionDescription: String {
        switch store.appearance.motion {
        case .sweep: return "高亮沿文字从左向右连续推进，类似播放器的卡拉 OK。"
        case .wave: return "唱到的字发光并轻轻抬起、落下，形成连续的波浪。"
        case .dock: return "像程序坞一样，当前文字放大，邻近文字平滑过渡并向两侧让开。"
        }
    }
    private func clamped(_ value: Binding<Double>, _ range: ClosedRange<Double>) -> Binding<Double> {
        Binding(get: { value.wrappedValue }, set: { value.wrappedValue = max(range.lowerBound, min(range.upperBound, $0)) })
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(LocalizedStringKey(title)); Spacer()
                Group {
                    if suffix.isEmpty {
                        TextField("", value: clamped(value, range), format: .percent.precision(.fractionLength(0)))
                    } else {
                        TextField("", value: clamped(value, range), format: .number.precision(.fractionLength(0...1)))
                    }
                }
                .textFieldStyle(.roundedBorder).frame(width: 70).multilineTextAlignment(.trailing)
                .accessibilityLabel(LocalizedStringKey(title))
                Text(suffix).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}

private struct LyricsSpectrumStatus: View {
    @ObservedObject var spectrum: LyricsSpectrum
    @ObservedObject var model: AppModel
    var body: some View { Text(model.localized(spectrum.status)).font(.caption).foregroundStyle(.secondary) }
}
