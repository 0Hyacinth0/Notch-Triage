import AppKit
import CoreText
import SwiftUI

private struct LyricGlyph {
    var path: Path
    var fallback: String?
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var row: Int
    var word: Int?
    var wordLeft: CGFloat = 0
    var wordRight: CGFloat = 0
}
private struct LyricShape {
    var glyphs: [LyricGlyph] = []
    var rowWidths: [CGFloat] = []
    var inkTop: CGFloat = 0
    var height: CGFloat = 0
    init(line: LyricLine, appearance: LyricsAppearance, width: CGFloat) {
        let font = appearance.font
        let attributed = NSAttributedString(string: line.text, attributes: [.font: font])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let available = max(font.pointSize, width - 2 * LyricsDisplayMetrics.effectInset(appearance) - 24 - appearance.ornamentSpace - (appearance.motion == .dock ? font.pointSize * appearance.dockAmount * 3 : 0))
        var boundaries: [(Range<Int>, Int)] = []
        var offset = 0
        for (i, word) in line.words.enumerated() {
            let end = offset + word.text.utf16.count
            boundaries.append((offset..<end, i)); offset = end
        }
        let rowHeight = font.ascender - font.descender + font.leading + font.pointSize * 0.15
            + (appearance.motion == .dock ? font.pointSize * appearance.dockAmount : 0)
        var cursor = 0, row = 0
        while cursor < attributed.length {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, cursor, Double(available)))
            let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: cursor, length: min(count, attributed.length - cursor)))
            rowWidths.append(CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil)))
            for run in CTLineGetGlyphRuns(ctLine) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let rawFont = attributes[kCTFontAttributeName] else { continue }
                let runFont = rawFont as! CTFont
                var ids = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                var advances = [CGSize](repeating: .zero, count: count)
                var indices = [CFIndex](repeating: 0, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &ids)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
                for i in 0..<count {
                    let outline = CTFontCreatePathForGlyph(runFont, ids[i], nil)
                    let fallback = outline == nil && indices[i] >= 0 && indices[i] < attributed.length ? (line.text as NSString).substring(with: (line.text as NSString).rangeOfComposedCharacterSequence(at: indices[i])) : nil
                    let y = CGFloat(row) * rowHeight
                    let transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: positions[i].x, ty: font.ascender + y - positions[i].y)
                    glyphs.append(LyricGlyph(path: outline.map { Path($0).applying(transform) } ?? Path(), fallback: fallback, x: positions[i].x, y: y, width: advances[i].width, row: row, word: boundaries.first { $0.0.contains(indices[i]) }?.1))
                }
            }
            cursor += count; row += 1
        }
        let ink = glyphs.filter { !$0.path.isEmpty }.reduce(CGRect.null) { $0.union($1.path.boundingRect) }
        inkTop = ink.isNull ? 0 : ink.minY
        height = max(font.pointSize, ink.isNull ? CGFloat(row) * rowHeight : ink.maxY - inkTop)
        var bounds: [String: (CGFloat, CGFloat)] = [:]
        for glyph in glyphs {
            guard let word = glyph.word else { continue }
            let key = "\(glyph.row):\(word)"
            let existing = bounds[key] ?? (glyph.x, glyph.x + glyph.width)
            bounds[key] = (min(existing.0, glyph.x), max(existing.1, glyph.x + glyph.width))
        }
        for i in glyphs.indices {
            if let word = glyphs[i].word, let bound = bounds["\(glyphs[i].row):\(word)"] {
                glyphs[i].wordLeft = bound.0; glyphs[i].wordRight = bound.1
            }
        }
    }
}

@MainActor private enum LyricShapeCache {
    private static var entries: [String: LyricShape] = [:]
    static func shape(for line: LyricLine?, appearance: LyricsAppearance, width: CGFloat) -> LyricShape {
        let line = line ?? LyricLine(start: 0, end: 1, text: "")
        let key = "\(appearance.fontFamily)|\(appearance.fontSize)|\(width)|\(appearance.motion.rawValue)|\(appearance.dockAmount)|\(appearance.hasOrnaments)|\(appearance.sideGap)|\(appearance.sideWidth)|\(LyricsDisplayMetrics.effectInset(appearance))|\(line.text)|\(line.words.map(\.text).joined(separator: "\u{1}"))"
        if let cached = entries[key] { return cached }
        let shape = LyricShape(line: line, appearance: appearance, width: width)
        if entries.count >= 360 { entries.removeAll(keepingCapacity: true) }
        entries[key] = shape
        return shape
    }
}

enum LyricsDisplayMetrics {
    // The window extends upwards by this amount, so the resting glyph ink,
    // rather than its shadow or motion padding, sits at the configured gap.
    static func topInset(_ appearance: LyricsAppearance) -> CGFloat {
        effectInset(appearance) + (appearance.motion == .wave ? appearance.lift : 0) + (appearance.hasOrnaments ? max(0, appearance.sideHeight - appearance.font.pointSize) / 2 : 0)
    }
    // Gaussian blur needs roughly three radii before its tail is invisible.
    // Reserve that space inside the canvas and transparent window on all sides.
    static func effectInset(_ appearance: LyricsAppearance) -> CGFloat {
        max(12, appearance.outerGlowRadius * 3) + 4
    }
    static func width(contentWidth: CGFloat, appearance: LyricsAppearance) -> CGFloat {
        let dockRoom = appearance.motion == .dock ? appearance.font.pointSize * appearance.dockAmount * 3 : 0
        let minimum = appearance.font.pointSize + dockRoom + 24 + appearance.ornamentSpace
        return max(contentWidth, minimum) + 2 * effectInset(appearance)
    }
    @MainActor static func height(document: LyricsDocument, time: Double, appearance: LyricsAppearance, width: CGFloat) -> CGFloat {
        let display = document.displaying(appearance.variant)
        let line = display.index(at: time).map { display.lines[$0] }
        let shape = LyricShapeCache.shape(for: line, appearance: appearance, width: width)
        return canvasHeight(shape: shape, appearance: appearance) + (appearance.showNext ? max(12, appearance.fontSize * 0.56) * 1.5 + 7 : 0)
    }
    fileprivate static func canvasHeight(shape: LyricShape, appearance: LyricsAppearance) -> CGFloat {
        topInset(appearance) + max(shape.height, appearance.hasOrnaments ? appearance.sideHeight : 0) + (appearance.motion == .dock ? appearance.fontSize * appearance.dockAmount : 0) + effectInset(appearance)
    }
}

struct LyricsDisplayView: View {
    var document: LyricsDocument
    var appearance: LyricsAppearance
    var elapsed: (Date) -> Double
    var playing = true
    var demo = false
    var spectrum: LyricsSpectrum? = nil
    var demonstrateSpectrum = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let display = document.displaying(appearance.variant)
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !playing)) { timeline in
                let time = demo ? timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 15) : elapsed(timeline.date)
                let index = display.index(at: time)
                let line = index.map { display.lines[$0] }
                let shape = LyricShapeCache.shape(for: line, appearance: appearance, width: geometry.size.width)
                let focus = readingFocus(line: line, shape: shape, time: time)
                let envelopes = shape.glyphs.indices.map { i -> Double in
                    guard !reduceMotion else { return 0 }
                    let distance = abs(Double(i) - focus)
                    let reach = appearance.motion == .dock ? 2.4 : 0.85
                    return distance < reach ? pow(cos(distance / reach * .pi / 2), 2) : 0
                }
                let ornamentTextWidth = shape.rowWidths.indices.map { row -> CGFloat in
                    let expansion = appearance.motion == .dock ? shape.glyphs.indices.reduce(CGFloat(0)) { total, i in
                        total + (shape.glyphs[i].row == row ? shape.glyphs[i].width * appearance.dockAmount * envelopes[i] : 0)
                    } : 0
                    return shape.rowWidths[row] + expansion
                }.max() ?? 0
                VStack(spacing: 7) {
                    Canvas { context, size in
                        guard let line else { return }
                        let progress = min(1, max(0, (time - line.start) / max(0.01, line.end - line.start)))
                        var extras: [Int: CGFloat] = [:]
                        if appearance.motion == .dock {
                            for i in shape.glyphs.indices {
                                extras[shape.glyphs[i].row, default: 0] += shape.glyphs[i].width * appearance.dockAmount * envelopes[i]
                            }
                        }
                        var preceding: [Int: CGFloat] = [:]
                        for (i, glyph) in shape.glyphs.enumerated() {
                            let envelope = envelopes[i]
                            let magnification = appearance.motion == .dock ? 1 + appearance.dockAmount * envelope : 1
                            let lift = appearance.motion == .wave ? appearance.lift * envelope : 0
                            let dx = (size.width - shape.rowWidths[glyph.row] - (extras[glyph.row] ?? 0)) / 2 + (preceding[glyph.row] ?? 0)
                            preceding[glyph.row, default: 0] += glyph.width * (magnification - 1)
                            // Dock enlargement is anchored to the glyph's top. It grows
                            // downwards without disappearing behind the physical notch.
                            let anchorY = glyph.y + shape.inkTop
                            let transform = CGAffineTransform(a: magnification, b: 0, c: 0, d: magnification,
                                tx: dx + glyph.x * (1 - magnification),
                                ty: LyricsDisplayMetrics.topInset(appearance) - shape.inkTop - lift + anchorY * (1 - magnification))
                            let word = glyph.word.flatMap { line.words.indices.contains($0) ? line.words[$0] : nil }
                            let sung = word.map { min(1, max(0, (time - $0.start) / max(0.01, $0.end - $0.start))) } ?? (appearance.usesEstimatedTiming ? min(1, max(0, progress * Double(shape.glyphs.count) - Double(i))) : 1)
                            let path = glyph.path.applying(transform)
                            var base = context
                            base.addFilter(.shadow(color: .black.opacity(0.75), radius: 3, x: 0, y: 1))
                            if let fallback = glyph.fallback {
                                base.draw(Text(fallback).font(.system(size: appearance.fontSize * magnification)), at: CGPoint(x: dx + glyph.x + glyph.width * magnification / 2, y: LyricsDisplayMetrics.topInset(appearance) - shape.inkTop + glyph.y + appearance.fontSize * magnification / 2 - lift))
                                continue
                            }
                            base.fill(path, with: .color(appearance.resting.color))
                            var lit = context
                            if appearance.motion == .sweep {
                                let boundary = glyph.wordLeft + (glyph.wordRight - glyph.wordLeft) * sung
                                let fraction = word == nil ? sung : min(1, max(0, (boundary - glyph.x) / max(1, glyph.width)))
                                guard fraction > 0 else { continue }
                                if fraction < 1 { lit.clip(to: Path(CGRect(x: 0, y: 0, width: max(0, dx + glyph.x + glyph.width * fraction), height: size.height))) }
                            } else {
                                lit.opacity = max(min(1, sung * 4), envelope * 0.85)
                            }
                            let position = min(1, max(0, (glyph.x + glyph.width / 2) / max(1, shape.rowWidths[glyph.row])))
                            let tint = mixed(appearance.highlight, appearance.endColor, position)
                            let breath = !reduceMotion && appearance.hasBreathing ? 0.88 + 0.12 * sin(time * 2.1 + position * 1.8) : 1
                            // Blur dedicated glyph layers instead of attenuating a shadow
                            // multiple times. Keep the crisp core outside both filters.
                            // Start from the unclipped context so sweep highlights can glow
                            // beyond their advancing edge instead of cutting the halo off.
                            if appearance.glow > 0 {
                                let strength = max(0, min(1, appearance.glow))
                                let activation = lit.opacity
                                var bloom = context
                                bloom.opacity = min(1, activation * strength * (0.9 + envelope * 0.3) * breath)
                                bloom.addFilter(.blur(radius: appearance.outerGlowRadius * 0.65))
                                bloom.drawLayer { layer in
                                    layer.fill(path, with: .color(tint.color))
                                }
                                var inner = context
                                inner.opacity = min(1, activation * strength * (0.85 + envelope * 0.25) * breath)
                                inner.addFilter(.blur(radius: max(1.2, appearance.fontSize * 0.075)))
                                inner.drawLayer { layer in
                                    layer.fill(path, with: .color(tint.color))
                                }
                            }
                            let core = appearance.lightPreset == .aurora ? mixed(tint, .white, 0.78) : appearance.lightPreset == .custom || appearance.lightPreset == nil ? tint : mixed(tint, .white, 0.2)
                            lit.fill(path, with: .color(core.color))
                        }
                    }
                    .frame(height: LyricsDisplayMetrics.canvasHeight(shape: shape, appearance: appearance))
                    .overlay {
                        if appearance.hasOrnaments, line != nil {
                            LyricsOrnamentsView(appearance: appearance, textWidth: ornamentTextWidth, centerY: LyricsDisplayMetrics.topInset(appearance) + shape.height / 2, spectrum: spectrum, demonstration: demo || demonstrateSpectrum, paused: !playing)
                        }
                    }
                    .id(line?.start)
                    .transition(.opacity)
                    if appearance.showNext {
                        Text(index.flatMap { $0 + 1 < display.lines.count ? display.lines[$0 + 1].text : nil } ?? " ")
                            .font(appearance.fontFamily == "System" ? .system(size: max(12, appearance.fontSize * 0.56), weight: .medium) : .custom(appearance.fontFamily, size: max(12, appearance.fontSize * 0.56)))
                            .foregroundStyle(appearance.resting.color.opacity(0.75))
                            .lineLimit(1).minimumScaleFactor(0.5)
                            .shadow(color: .black.opacity(0.8), radius: 3)
                            .padding(.horizontal, 18)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: index)
            }
        }
        .accessibilityLabel(display.lines.map(\.text).joined(separator: "，"))
    }
    private func mixed(_ a: RingColor, _ b: RingColor, _ t: Double) -> RingColor {
        RingColor(red: a.red + (b.red - a.red) * t, green: a.green + (b.green - a.green) * t, blue: a.blue + (b.blue - a.blue) * t, opacity: a.opacity + (b.opacity - a.opacity) * t)
    }
    private func readingFocus(line: LyricLine?, shape: LyricShape, time: Double) -> Double {
        guard let line, time >= line.start, time < line.end else { return -10 }
        if let wordIndex = line.words.firstIndex(where: { time >= $0.start && time < $0.end }) {
            let word = line.words[wordIndex]
            let indices = shape.glyphs.indices.filter { shape.glyphs[$0].word == wordIndex }
            if let first = indices.first, let last = indices.last {
                let t = (time - word.start) / max(0.01, word.end - word.start)
                return Double(first) - 0.5 + t * Double(last - first + 1)
            }
        }
        if !line.words.isEmpty || !appearance.usesEstimatedTiming { return -10 }
        let t = (time - line.start) / max(0.01, line.end - line.start)
        return -0.5 + t * Double(shape.glyphs.count)
    }
}
