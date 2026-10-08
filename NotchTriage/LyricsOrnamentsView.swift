import SwiftUI

struct LyricsOrnamentsView: View {
    var appearance: LyricsAppearance
    var textWidth: CGFloat
    var centerY: CGFloat
    var spectrum: LyricsSpectrum?
    var demonstration: Bool
    var paused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if let spectrum, !demonstration {
                LiveLyricsOrnaments(appearance: appearance, textWidth: textWidth, centerY: centerY, spectrum: spectrum, reduceMotion: reduceMotion, paused: paused)
            } else {
                LyricsOrnamentCanvas(appearance: appearance, textWidth: textWidth, centerY: centerY, frame: .silent, demonstration: demonstration, reduceMotion: reduceMotion, paused: paused)
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
private struct LiveLyricsOrnaments: View {
    var appearance: LyricsAppearance
    var textWidth: CGFloat
    var centerY: CGFloat
    @ObservedObject var spectrum: LyricsSpectrum
    var reduceMotion: Bool
    var paused = false
    var body: some View {
        LyricsOrnamentCanvas(appearance: appearance, textWidth: textWidth, centerY: centerY, frame: spectrum.frame, demonstration: false, reduceMotion: reduceMotion, paused: paused)
    }
}
private struct LyricsOrnamentCanvas: View {
    var appearance: LyricsAppearance
    var textWidth: CGFloat
    var centerY: CGFloat
    var frame: LyricsSpectrumFrame
    var demonstration: Bool
    var reduceMotion: Bool
    var paused = false
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: paused || reduceMotion || (!demonstration && frame.bands.allSatisfy { $0 < 0.001 } && frame.previous.allSatisfy { $0 < 0.001 }))) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let levels = levels(at: time)
            Canvas { context, size in
                let width = appearance.sideWidth
                let height = appearance.sideHeight
                // Anchor to the actual longest rendered row, not the window width.
                for side in 0..<2 {
                    let edge = size.width / 2 + (side == 0 ? -1 : 1) * (textWidth / 2 + appearance.sideGap)
                    let origin = side == 0 ? edge - width : edge
                    let rect = CGRect(x: origin, y: centerY - height / 2, width: width, height: height)
                    let colors = side == 0 ? [appearance.endColor.color, appearance.highlight.color] : [appearance.highlight.color, appearance.endColor.color]
                    let gradient = GraphicsContext.Shading.linearGradient(Gradient(colors: colors), startPoint: CGPoint(x: rect.minX, y: rect.midY), endPoint: CGPoint(x: rect.maxX, y: rect.midY))
                    let energy = levels.reduce(0, +) / Double(levels.count)
                    switch appearance.ornament {
                    case .spectrum:
                        let pitch = width / Double(levels.count)
                        for i in levels.indices {
                            let index = side == 0 ? levels.count - 1 - i : i
                            let amplitude = levels[index]
                            let h = max(2, height * amplitude)
                            let path = Path(roundedRect: CGRect(x: rect.minX + (Double(i) + 0.5) * pitch - max(1.5, pitch * 0.36) / 2, y: rect.midY - h / 2, width: max(1.5, pitch * 0.36), height: h), cornerRadius: pitch / 2)
                            fill(path, context: context, gradient: gradient, activation: amplitude)
                        }
                    case .waveform:
                        for trace in 0..<3 {
                            var path = Path()
                            for step in 0...80 {
                                let u = Double(step) / 80
                                let position = (side == 0 ? 1 - u : u) * Double(levels.count - 1)
                                let index = min(levels.count - 1, Int(position))
                                let next = min(levels.count - 1, index + 1)
                                let blend = position - Double(index)
                                let smooth = blend * blend * (3 - 2 * blend)
                                let amplitude = levels[index] + (levels[next] - levels[index]) * smooth
                                let envelope = sin(u * .pi)
                                let phase = reduceMotion || energy < 0.005 ? 0 : time * (1.5 + energy * 2)
                                let displacement = sin(u * .pi * 4 - phase + Double(trace) * 0.65) * amplitude * height * 0.42 * envelope
                                let point = CGPoint(x: rect.minX + width * u, y: rect.midY + displacement)
                                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                            }
                            stroke(path, context: context, gradient: gradient, width: trace == 0 ? 1.8 : 1, opacity: trace == 0 ? 0.9 : 0.35, activation: energy)
                        }
                    case .ripple:
                        if energy < 0.005 || reduceMotion {
                            let path = Path(ellipseIn: rect.insetBy(dx: width * 0.38, dy: height * 0.30))
                            stroke(path, context: context, gradient: gradient, width: 1, opacity: 0.18, activation: 0)
                        } else {
                            for ring in 0..<4 {
                                let phase = (time * 0.55 + Double(ring) / 4).truncatingRemainder(dividingBy: 1)
                                let scale = 0.16 + phase * 0.84
                                let waveHeight = height * scale * (0.35 + energy * 0.65)
                                let waveWidth = width * scale
                                let path = Path(ellipseIn: CGRect(x: rect.midX - waveWidth / 2, y: rect.midY - waveHeight / 2, width: waveWidth, height: waveHeight))
                                stroke(path, context: context, gradient: gradient, width: 1.1 + energy, opacity: (1 - phase) * (0.3 + energy * 0.7), activation: energy)
                            }
                        }
                    }
                }
            }
        }
    }
    private func levels(at time: Double) -> [Double] {
        if reduceMotion { return [Double](repeating: 0, count: 14) }
        if !demonstration { return frame.interpolated(at: ProcessInfo.processInfo.systemUptime) }
        return (0..<14).map { index -> Double in
            let band = Double(index)
            let slow = 0.4 * sin(time * 2.4 + band * 0.52)
            let fast = 0.16 * sin(time * 4.1 - band * 0.3)
            return max(0, 0.22 + slow + fast)
        }
    }
    private func fill(_ path: Path, context: GraphicsContext, gradient: GraphicsContext.Shading, activation: Double) {
        var glow = context
        glow.opacity = appearance.glow * activation * 0.7
        glow.addFilter(.blur(radius: 4))
        glow.drawLayer { $0.fill(path, with: gradient) }
        var core = context; core.opacity = 0.18 + activation * 0.82
        core.fill(path, with: gradient)
    }
    private func stroke(_ path: Path, context: GraphicsContext, gradient: GraphicsContext.Shading, width: Double, opacity: Double, activation: Double) {
        var glow = context; glow.opacity = appearance.glow * activation * opacity * 0.6
        glow.addFilter(.blur(radius: 4))
        glow.drawLayer { $0.stroke(path, with: gradient, style: StrokeStyle(lineWidth: width + 1, lineCap: .round)) }
        var core = context; core.opacity = opacity
        core.stroke(path, with: gradient, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
}
