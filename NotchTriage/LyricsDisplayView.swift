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
    var wordGlyphRanges: [Int: ClosedRange<Int>] = [:]
    var inkTop: CGFloat = 0
    var height: CGFloat = 0
    init(line: LyricLine, appearance: LyricsAppearance, width: CGFloat) {
        let font = appearance.font
        let attributed = NSAttributedString(string: line.text, attributes: [.font: font])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
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
            let count = attributed.length // Single line; the viewport scrolls rather than wrapping.
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
                let first = wordGlyphRanges[word]?.lowerBound ?? i
                wordGlyphRanges[word] = first...i
            }
        }
    }
}

@MainActor private enum LyricShapeCache {
    private static var entries: [String: LyricShape] = [:]
    static func shape(for line: LyricLine?, appearance: LyricsAppearance, width: CGFloat) -> LyricShape {
        let line = line ?? LyricLine(start: 0, end: 1, text: "")
        let key = "\(appearance.fontFamily)|\(appearance.fontSize)|\(appearance.motion.rawValue)|\(appearance.dockAmount)|\(line.text)|\(line.words.map(\.text).joined(separator: "\u{1}"))"
        if let cached = entries[key] { return cached }
        let shape = LyricShape(line: line, appearance: appearance, width: width)
        if entries.count >= 360 { entries.removeAll(keepingCapacity: true) }
        entries[key] = shape
        return shape
    }
}

@MainActor private final class LyricViewShapeMemo {
    private var line: LyricLine?
    private var appearance: LyricsAppearance?
    private var value: LyricShape?
    func shape(_ line: LyricLine?, appearance: LyricsAppearance, width: CGFloat) -> LyricShape {
        if self.line == line, self.appearance == appearance, let value { return value }
        let shape = LyricShapeCache.shape(for: line, appearance: appearance, width: width)
        self.line = line; self.appearance = appearance; self.value = shape
        return shape
    }
}
@MainActor private enum LyricsDisplayCache {
    static var original: LyricsDocument?
    static var variant: LyricsChineseVariant?
    static var converted: LyricsDocument?
    static func document(_ value: LyricsDocument, variant: LyricsChineseVariant) -> LyricsDocument {
        let sameDocument = value.revisionID != nil && original?.revisionID == value.revisionID
            || original == value
        if sameDocument, self.variant == variant, let converted { return converted }
        let display = value.displaying(variant)
        original = value; self.variant = variant; converted = display
        return display
    }
}
private struct LyricPaint {
    var path: Path
    var tint: Color
    var core: Color
    var opacity: Double
    var outer: Double
    var inner: Double
    var boundary: CGFloat?
    var shineX: CGFloat
    var shineWidth: CGFloat
}

enum LyricsDisplayMetrics {
    static func secondaryHeight(_ appearance: LyricsAppearance, count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let textHeight = max(12, appearance.fontSize * 0.56) * 1.25
        // Secondary rows sit inside the canvas's transparent glow tail.
        return max(0, 4 - effectInset(appearance) + CGFloat(count) * textHeight + CGFloat(count - 1) * 2)
    }
    static func secondaryCount(_ appearance: LyricsAppearance) -> Int {
        (appearance.showNext ? 1 : 0) + (appearance.showsTranslation ? 1 : 0) + (appearance.showsRomanization ? 1 : 0)
    }
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
    static func maximumHeight(_ appearance: LyricsAppearance) -> CGFloat {
        let ink = max(appearance.font.ascender - appearance.font.descender, appearance.font.pointSize * 1.2)
        return topInset(appearance) + max(ink, appearance.hasOrnaments ? appearance.sideHeight : 0)
            + (appearance.motion == .dock ? appearance.fontSize * appearance.dockAmount : 0) + effectInset(appearance)
            + secondaryHeight(appearance, count: secondaryCount(appearance))
    }
    @MainActor static func height(document: LyricsDocument, time: Double, appearance: LyricsAppearance, width: CGFloat) -> CGFloat {
        let display = LyricsDisplayCache.document(document, variant: appearance.variant)
        let line = display.index(at: time).map { display.lines[$0] }
        let shape = LyricShapeCache.shape(for: line, appearance: appearance, width: width)
        let count = (appearance.showNext ? 1 : 0)
            + (appearance.showsTranslation && line?.translation != nil ? 1 : 0)
            + (appearance.showsRomanization && line?.romanization != nil ? 1 : 0)
        return canvasHeight(shape: shape, appearance: appearance) + secondaryHeight(appearance, count: count)
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
    @State private var shapeMemo = LyricViewShapeMemo()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let display = LyricsDisplayCache.document(document, variant: appearance.variant)
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: document.hasWordTiming ? 1.0 / 60 : 1.0 / 30, paused: !playing)) { timeline in
                let time = demo ? timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 15) : elapsed(timeline.date)
                let index = display.index(at: time)
                let line = index.map { display.lines[$0] }
                let shape = shapeMemo.shape(line, appearance: appearance, width: geometry.size.width)
                let focus = readingFocus(line: line, shape: shape, time: time)
                let motion = appearance.motion
                let elasticWidth = motion == .dock ? 0.05 : 0.18
                let elasticHeight = motion == .dock ? 0.12 : 0.23
                let viewport = max(appearance.font.pointSize, geometry.size.width - 2 * LyricsDisplayMetrics.effectInset(appearance) - 24 - appearance.ornamentSpace - (motion == .dock ? appearance.fontSize * appearance.dockAmount * 3 : 0))
                let overflow = (shape.rowWidths.max() ?? 0) > viewport
                let motionActivation = line.map { line -> Double in
                    guard line.hasWordTiming, let previous = line.words.last(where: { $0.start <= time }) else { return 1 }
                    return time <= previous.end ? 1 : max(0, 1 - (time - previous.end) / 0.18)
                } ?? 0
                let envelopes = shape.glyphs.indices.map { i -> Double in
                    guard !reduceMotion else { return 0 }
                    let distance = abs(Double(i) - focus)
                    let reach = motion == .dock ? 2.4 : 0.85
                    return distance < reach ? pow(cos(distance / reach * .pi / 2), 2) * motionActivation : 0
                }
                let elasticEnvelopes = shape.glyphs.indices.map { i -> Double in
                    guard appearance.style == .elastic, !reduceMotion else { return 0 }
                    let distance = abs(Double(i) - focus)
                    let reach = 1.2
                    return distance < reach ? pow(cos(distance / reach * .pi / 2), 2) * motionActivation : 0
                }
                let ornamentTextWidth = shape.rowWidths.indices.map { row -> CGFloat in
                    let expansion = shape.glyphs.indices.reduce(CGFloat(0)) { total, i in
                        guard shape.glyphs[i].row == row else { return total }
                        let dock = motion == .dock ? appearance.dockAmount * envelopes[i] : 0
                        return total + shape.glyphs[i].width * (dock + elasticWidth * elasticEnvelopes[i])
                    }
                    return shape.rowWidths[row] + expansion
                }.max() ?? 0
                VStack(spacing: 0) {
                    Canvas(rendersAsynchronously: true) { context, size in
                        guard let line else { return }
                        let progress = min(1, max(0, (time - line.start) / max(0.01, line.end - line.start)))
                        var extras: [Int: CGFloat] = [:]
                        if motion == .dock || appearance.style == .elastic {
                            for i in shape.glyphs.indices {
                                let dock = motion == .dock ? appearance.dockAmount * envelopes[i] : 0
                                extras[shape.glyphs[i].row, default: 0] += shape.glyphs[i].width * (dock + elasticWidth * elasticEnvelopes[i])
                            }
                        }
                        let scroll = scrollingOffset(line: line, shape: shape, time: time, viewport: viewport, expansion: extras[0] ?? 0)
                        var paints: [LyricPaint] = []; paints.reserveCapacity(shape.glyphs.count)
                        var resting = Path()
                        var fallbacks: [(String, CGPoint, Double)] = []
                        var preceding: [Int: CGFloat] = [:]
                        for (i, glyph) in shape.glyphs.enumerated() {
                            let envelope = envelopes[i]
                            let word = glyph.word.flatMap { line.words.indices.contains($0) ? line.words[$0] : nil }
                            let sung = word.map { min(1, max(0, (time - $0.start) / max(0.01, $0.end - $0.start))) } ?? (appearance.usesEstimatedTiming ? min(1, max(0, progress * Double(shape.glyphs.count) - Double(i))) : 1)
                            let glyphSung: Double
                            if let wordIndex = glyph.word, let word, let range = shape.wordGlyphRanges[wordIndex] {
                                let count = Double(range.upperBound - range.lowerBound + 1)
                                let position = (time - word.start) / max(0.01, word.end - word.start) * count - Double(i - range.lowerBound)
                                glyphSung = min(1, max(0, position))
                            } else {
                                glyphSung = appearance.usesEstimatedTiming ? min(1, max(0, progress * Double(shape.glyphs.count) - Double(i))) : 1
                            }
                            let elastic = elasticEnvelopes[i]
                            let dock = motion == .dock ? appearance.dockAmount * envelope : 0
                            let magnification = 1 + dock + elasticWidth * elastic
                            let phase = (focus - Double(i)) * 3.2
                            let verticalScale = 1 + dock + elasticHeight * elastic * (0.88 + 0.12 * cos(phase))
                            let shear = 0.065 * elastic * sin(phase)
                            let lift = (motion == .wave ? appearance.lift * envelope : 0) + appearance.fontSize * 0.045 * elastic
                            let origin = overflow ? (size.width - viewport) / 2 - scroll : (size.width - shape.rowWidths[glyph.row] - (extras[glyph.row] ?? 0)) / 2
                            let dx = origin + (preceding[glyph.row] ?? 0)
                            preceding[glyph.row, default: 0] += glyph.width * (magnification - 1)
                            // Dock enlargement is anchored to the glyph's top. It grows
                            // downwards without disappearing behind the physical notch.
                            let anchorY = glyph.y + shape.inkTop + (appearance.style == .elastic ? appearance.fontSize * 0.5 : 0)
                            let transform = CGAffineTransform(a: magnification, b: 0, c: shear, d: verticalScale,
                                tx: dx + glyph.x * (1 - magnification) - shear * anchorY,
                                ty: LyricsDisplayMetrics.topInset(appearance) - shape.inkTop - lift + anchorY * (1 - verticalScale))
                            let viewportLeft = (size.width - viewport) / 2
                            let bleed = LyricsDisplayMetrics.effectInset(appearance)
                            if overflow && (dx + glyph.x + glyph.width * magnification < viewportLeft - bleed || dx + glyph.x > viewportLeft + viewport + bleed) { continue }
                            let transformed = glyph.path.applying(transform)
                            let path = elastic > 0.015 ? liquidWobble(transformed, amount: appearance.fontSize * 0.06 * elastic, phase: phase) : transformed
                            if let fallback = glyph.fallback {
                                fallbacks.append((fallback, CGPoint(x: dx + glyph.x + glyph.width * magnification / 2, y: LyricsDisplayMetrics.topInset(appearance) - shape.inkTop + glyph.y + appearance.fontSize * magnification / 2 - lift), appearance.fontSize * magnification))
                                continue
                            }
                            resting.addPath(path)
                            var boundaryX: CGFloat?
                            var activation = 1.0
                            if motion == .sweep || appearance.style != .flowing {
                                guard glyphSung > 0 else { continue }
                                if glyphSung < 1 { boundaryX = max(0, dx + glyph.x + glyph.width * glyphSung) }
                            } else {
                                activation = max(min(1, glyphSung * 4), envelope * 0.35)
                            }
                            let position = min(1, max(0, (glyph.x + glyph.width / 2) / max(1, shape.rowWidths[glyph.row])))
                            let tint = mixed(appearance.highlight, appearance.endColor, position)
                            let breath = !reduceMotion && appearance.hasBreathing ? 0.88 + 0.12 * sin(time * 2.1 + position * 1.8) : 1
                            let strength = max(0, min(1, appearance.glow))
                            let core = appearance.style == .classic ? mixed(tint, .white, 0.18)
                                : appearance.lightPreset == .aurora ? mixed(tint, .white, 0.78)
                                : appearance.lightPreset == .custom || appearance.lightPreset == nil ? tint : mixed(tint, .white, 0.2)
                            let shineX = word == nil
                                ? origin + shape.rowWidths[glyph.row] * progress
                                : dx + glyph.wordLeft + (glyph.wordRight - glyph.wordLeft) * sung
                            paints.append(LyricPaint(path: path, tint: tint.color, core: core.color, opacity: activation,
                                outer: min(1, activation * strength * (0.9 + envelope * 0.3) * breath),
                                inner: min(1, activation * strength * (0.85 + envelope * 0.25) * breath), boundary: boundaryX,
                                shineX: shineX, shineWidth: max(appearance.fontSize * 0.42, glyph.width * 0.7)))
                        }
                        var base = context
                        base.addFilter(.shadow(color: .black.opacity(0.75), radius: 3, x: 0, y: 1))
                        base.fill(resting, with: .color(appearance.resting.color))
                        for (text, point, size) in fallbacks { context.draw(Text(text).font(.system(size: size)), at: point) }
                        // Exactly two blur composites for the visible line, independent
                        // of its character count. Glyph cores remain sharp and unclipped.
                        if appearance.glow > 0 {
                            var outer = context; outer.addFilter(.blur(radius: appearance.outerGlowRadius * 0.65))
                            outer.drawLayer { layer in
                                for paint in paints where paint.outer > 0 {
                                    var glyphLayer = layer
                                    if let boundary = paint.boundary { glyphLayer.clip(to: Path(CGRect(x: 0, y: 0, width: boundary, height: size.height))) }
                                    glyphLayer.fill(paint.path, with: .color(paint.tint.opacity(paint.outer)))
                                }
                            }
                            var inner = context; inner.addFilter(.blur(radius: max(1.2, appearance.fontSize * (appearance.style == .flowing ? 0.045 : 0.075))))
                            inner.drawLayer { layer in
                                for paint in paints where paint.inner > 0 {
                                    var glyphLayer = layer
                                    if let boundary = paint.boundary { glyphLayer.clip(to: Path(CGRect(x: 0, y: 0, width: boundary, height: size.height))) }
                                    if appearance.style == .flowing {
                                        glyphLayer.stroke(paint.path, with: .color(paint.core.opacity(paint.inner)), lineWidth: max(1.2, appearance.fontSize * 0.085))
                                    } else {
                                        glyphLayer.fill(paint.path, with: .color(paint.tint.opacity(paint.inner)))
                                    }
                                }
                            }
                        }
                        for paint in paints where paint.opacity > 0 {
                            var lit = context; lit.opacity = paint.opacity
                            if let boundary = paint.boundary { lit.clip(to: Path(CGRect(x: 0, y: 0, width: boundary, height: size.height))) }
                            if appearance.style == .flowing {
                                let band = paint.shineWidth
                                let gradient = Gradient(colors: [paint.tint, paint.tint, paint.core, .white, paint.core, paint.tint, paint.tint])
                                lit.fill(paint.path, with: .linearGradient(gradient,
                                    startPoint: CGPoint(x: paint.shineX - band, y: 0),
                                    endPoint: CGPoint(x: paint.shineX + band, y: 0)))
                                if appearance.glow > 0 {
                                    lit.stroke(paint.path, with: .color(paint.core.opacity(0.16 * appearance.glow)), lineWidth: max(0.5, appearance.fontSize * 0.018))
                                }
                            } else {
                                lit.fill(paint.path, with: .color(paint.core))
                            }
                        }
                    }
                    .frame(height: LyricsDisplayMetrics.canvasHeight(shape: shape, appearance: appearance))
                    .mask {
                        if overflow {
                            let edge = max(0, (geometry.size.width - viewport) / 2)
                            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: max(0, (edge - 14) / geometry.size.width)), .init(color: .white, location: edge / geometry.size.width), .init(color: .white, location: min(1, (edge + viewport) / geometry.size.width)), .init(color: .clear, location: min(1, (edge + viewport + 14) / geometry.size.width)), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
                        } else { Color.white }
                    }
                    .overlay {
                        if appearance.hasOrnaments, line != nil {
                            LyricsOrnamentsView(appearance: appearance, textWidth: overflow ? viewport : ornamentTextWidth, centerY: LyricsDisplayMetrics.topInset(appearance) + shape.height / 2, spectrum: spectrum, demonstration: demo || demonstrateSpectrum, paused: !playing)
                        }
                    }
                    .id(line?.start)
                    .transition(.opacity)
                    if appearance.showNext || (appearance.showsTranslation && line?.translation != nil)
                        || (appearance.showsRomanization && line?.romanization != nil) {
                        VStack(spacing: 2) {
                            if appearance.showsTranslation, let translation = line?.translation {
                                Text(translation)
                                    .font(appearance.fontFamily == "System" ? .system(size: max(12, appearance.fontSize * 0.56), weight: .medium) : .custom(appearance.fontFamily, size: max(12, appearance.fontSize * 0.56)))
                                    .foregroundStyle(appearance.resting.color)
                                    .lineLimit(1).minimumScaleFactor(0.5)
                                    .shadow(color: .black.opacity(0.8), radius: 3)
                                    .padding(.horizontal, 18)
                            }
                            if appearance.showsRomanization, let romanization = line?.romanization {
                                Text(romanization)
                                    .font(appearance.fontFamily == "System" ? .system(size: max(12, appearance.fontSize * 0.48), weight: .medium) : .custom(appearance.fontFamily, size: max(12, appearance.fontSize * 0.48)))
                                    .foregroundStyle(appearance.resting.color.opacity(0.8))
                                    .lineLimit(1).minimumScaleFactor(0.5)
                                    .padding(.horizontal, 18)
                            }
                            if appearance.showNext {
                                Text(index.flatMap { $0 + 1 < display.lines.count ? display.lines[$0 + 1].text : nil } ?? " ")
                                    .font(appearance.fontFamily == "System" ? .system(size: max(12, appearance.fontSize * 0.56), weight: .medium) : .custom(appearance.fontFamily, size: max(12, appearance.fontSize * 0.56)))
                                    .foregroundStyle(appearance.resting.color.opacity(0.75))
                                    .lineLimit(1).minimumScaleFactor(0.5)
                                    .shadow(color: .black.opacity(0.8), radius: 3)
                                    .padding(.horizontal, 18)
                            }
                        }
                        .padding(.top, -LyricsDisplayMetrics.effectInset(appearance) + 4)
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
    private func liquidWobble(_ path: Path, amount: CGFloat, phase: Double) -> Path {
        let bounds = path.boundingRect
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return path }
        let result = CGMutablePath()
        func warped(_ point: CGPoint) -> CGPoint {
            let vertical = (point.y - bounds.midY) / bounds.height
            let horizontal = (point.x - bounds.midX) / bounds.width
            return CGPoint(
                x: point.x + amount * sin(vertical * .pi * 2 + phase),
                y: point.y + amount * 0.28 * sin(horizontal * .pi * 2 + phase)
            )
        }
        path.cgPath.applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint: result.move(to: warped(points[0]))
            case .addLineToPoint: result.addLine(to: warped(points[0]))
            case .addQuadCurveToPoint: result.addQuadCurve(to: warped(points[1]), control: warped(points[0]))
            case .addCurveToPoint: result.addCurve(to: warped(points[2]), control1: warped(points[0]), control2: warped(points[1]))
            case .closeSubpath: result.closeSubpath()
            @unknown default: break
            }
        }
        return Path(result)
    }
    private func scrollingOffset(line: LyricLine, shape: LyricShape, time: Double, viewport: CGFloat, expansion: CGFloat) -> CGFloat {
        let overflow = max(0, (shape.rowWidths.first ?? 0) + expansion - viewport)
        guard overflow > 0 else { return 0 }
        if line.hasWordTiming {
            let focus = max(0, min(Double(max(0, shape.glyphs.count - 1)), readingFocus(line: line, shape: shape, time: time)))
            let i = Int(focus)
            guard shape.glyphs.indices.contains(i) else { return 0 }
            let glyph = shape.glyphs[i]
            let next = shape.glyphs[min(shape.glyphs.count - 1, i + 1)]
            let currentCenter = glyph.x + glyph.width / 2
            let nextCenter = next.x + next.width / 2
            let position = currentCenter + (nextCenter - currentCenter) * (focus - Double(i))
            return max(0, min(overflow, position - viewport * 0.45))
        }
        let progress = min(1, max(0, (time - line.start) / max(0.01, line.end - line.start)))
        return overflow * progress
    }
    private func readingFocus(line: LyricLine?, shape: LyricShape, time: Double) -> Double {
        guard let line, time >= line.start else { return -10 }
        if line.hasWordTiming, let index = line.words.lastIndex(where: { $0.start <= time }), let glyphs = shape.wordGlyphRanges[index] {
            let word = line.words[index]
            let t = min(1, max(0, (time - word.start) / max(0.01, word.end - word.start)))
            return Double(glyphs.lowerBound) - 0.5 + t * Double(glyphs.count)
        }
        if line.hasWordTiming || !appearance.usesEstimatedTiming { return -10 }
        let t = min(1, max(0, (time - line.start) / max(0.01, line.end - line.start)))
        return -0.5 + t * Double(shape.glyphs.count)
    }
}
