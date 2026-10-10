import AppKit

/// Care feedback shares the desktop renderer and settings preview. Coordinates
/// follow the pet's canvas, so particles remain contained at every pet scale.
@MainActor
enum CompanionCareEffects {
    static let actions: Set<String> = ["pet", "meal", "snack", "bath", "clean", "rest"]
    static func duration(_ action: String) -> Double { actions.contains(action) ? 3.2 : 2.4 }

    static func draw(
        _ action: String, in rect: NSRect, age: Double, intensity: Double,
        reduced: Bool, sleeping: Bool, behind: Bool
    ) {
        guard actions.contains(action), age >= 0, age < duration(action), intensity > 0 else { return }
        let t = reduced ? 0.9 : age
        let alpha = min(1, age / 0.15) * min(1, (duration(action) - age) / 0.6) * min(1, intensity)
        let s = rect.width / 128
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.midX, yBy: rect.minY)
        transform.scale(by: s)
        transform.concat()
        func color(_ c: NSColor, _ a: Double = 1) -> NSColor { c.withAlphaComponent(alpha * a) }
        func ellipse(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ c: NSColor) {
            c.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: w, height: h)).fill()
        }
        func line(_ points: [NSPoint], _ c: NSColor, width: Double = 2) {
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.move(to: first)
            for p in points.dropFirst() { path.line(to: p) }
            path.lineWidth = width
            path.lineCapStyle = .round
            c.setStroke()
            path.stroke()
        }
        func spark(_ x: Double, _ y: Double, _ size: Double, _ c: NSColor) {
            let shadow = NSShadow()
            shadow.shadowColor = c
            shadow.shadowBlurRadius = 5 * intensity
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            line([.init(x: x - size, y: y), .init(x: x + size, y: y)], c)
            line([.init(x: x, y: y - size), .init(x: x, y: y + size)], c)
            NSGraphicsContext.restoreGraphicsState()
        }
        func heart(_ x: Double, _ y: Double, _ size: Double, _ c: NSColor) {
            let path = NSBezierPath()
            path.move(to: .init(x: x, y: y - size))
            path.curve(
                to: .init(x: x - size, y: y + size * 0.3),
                controlPoint1: .init(x: x - size * 0.5, y: y - size * 0.5),
                controlPoint2: .init(x: x - size * 1.4, y: y))
            path.curve(
                to: .init(x: x, y: y + size * 0.4), controlPoint1: .init(x: x - size, y: y + size * 1.3),
                controlPoint2: .init(x: x - size * 0.2, y: y + size))
            path.curve(
                to: .init(x: x + size, y: y + size * 0.3),
                controlPoint1: .init(x: x + size * 0.2, y: y + size),
                controlPoint2: .init(x: x + size, y: y + size * 1.3))
            path.curve(
                to: .init(x: x, y: y - size), controlPoint1: .init(x: x + size * 1.4, y: y),
                controlPoint2: .init(x: x + size * 0.5, y: y - size * 0.5))
            c.setFill()
            path.fill()
        }
        let pink = NSColor(calibratedRed: 1, green: 0.58, blue: 0.73, alpha: 1)
        let gold = NSColor(calibratedRed: 1, green: 0.82, blue: 0.43, alpha: 1)
        let blue = NSColor(calibratedRed: 0.52, green: 0.89, blue: 1, alpha: 1)
        if behind {
            if action == "pet" {
                let glow = NSShadow()
                glow.shadowColor = color(pink, 0.5)
                glow.shadowBlurRadius = 16
                glow.set()
                ellipse(-38, 10, 76, 82, color(pink, 0.08))
            } else if action == "bath" {
                ellipse(-48, 5, 96, 16, color(blue, 0.25))
                let ripple = NSBezierPath(
                    ovalIn: .init(x: -48 - t * 3, y: 5 - t, width: 96 + t * 6, height: 16 + t * 2))
                color(blue, 0.45).setStroke()
                ripple.lineWidth = 1.5
                ripple.stroke()
            } else if action == "rest" && sleeping {
                for i in 0..<4 { ellipse(-42 + Double(i) * 20, 3, 28, 13, color(.white, 0.65)) }
                ellipse(-38, 0, 76, 10, color(blue, 0.35))
            }
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        switch action {
        case "pet":
            for i in 0..<5 {
                let phase = (t * 0.48 + Double(i) * 0.19).truncatingRemainder(dividingBy: 1)
                let x = Double(i % 2 == 0 ? -1 : 1) * (36 + sin(t * 2 + Double(i)) * 7)
                heart(x, 45 + phase * 60, 4 + Double(i % 2), color(pink, 1 - phase * 0.8))
            }
            spark(-36, 77, 3, color(.white, 0.8))
        case "meal":
            color(.white, 0.9).setFill()
            NSBezierPath(roundedRect: .init(x: -20, y: 0, width: 40, height: 13), xRadius: 6, yRadius: 6)
                .fill()
            ellipse(-19, 9, 38, 8, color(gold))
            for i in 0..<4 {
                let p = (t * 0.85 + Double(i) * 0.24).truncatingRemainder(dividingBy: 1)
                ellipse(
                    -13 + Double(i) * 8, 13 + p * 35, 3 * (1 - p) + 1, 3 * (1 - p) + 1, color(gold, 1 - p))
            }
            spark(36, 54 + sin(t * 3) * 3, 5, color(gold))
            spark(-34, 72, 3, color(.white))
        case "snack":
            let p = min(1, t / 1.1)
            let cookie = NSBezierPath(
                roundedRect: .init(
                    x: 37 - p * 19, y: 38 + sin(p * .pi) * 10, width: 12 * (1 - p * 0.65),
                    height: 12 * (1 - p * 0.65)), xRadius: 3, yRadius: 3)
            color(gold).setFill()
            cookie.fill()
            for i in 0..<5 {
                let q = (t * 0.7 + Double(i) * 0.15).truncatingRemainder(dividingBy: 1)
                ellipse(23 + q * Double(i * 3 - 6), 43 - q * 22, 2, 2, color(gold, 1 - q))
            }
            heart(-36, 66 + sin(t * 2) * 4, 5, color(pink))
            spark(40, 85, 4, color(gold))
        case "bath":
            for i in 0..<9 {
                let p = (t * 0.35 + Double(i) * 0.11).truncatingRemainder(dividingBy: 1)
                let x = Double(i % 2 == 0 ? -1 : 1) * (29 + Double(i % 3) * 10 + sin(t + Double(i)) * 3)
                let size = 5 + Double(i % 3) * 3
                let y = 12 + p * 89
                ellipse(x, y, size, size, color(blue, (1 - p) * 0.22))
                let bubble = NSBezierPath(ovalIn: .init(x: x, y: y, width: size, height: size))
                color(blue, 1 - p * 0.65).setStroke()
                bubble.lineWidth = 1.2
                bubble.stroke()
                ellipse(x + size * 0.25, y + size * 0.6, 2, 2, color(.white, 0.8))
            }
            for i in 0..<6 {
                ellipse(-35 + Double(i) * 12, 8 + sin(t * 3 + Double(i)) * 2, 14, 8, color(.white, 0.7))
            }
            spark(39, 82, 4, color(.white))
        case "clean":
            let sweep = reduced ? 0.5 : (sin(t * 3.5) + 1) / 2
            let x = -42 + sweep * 84
            line([.init(x: x + 7, y: 26), .init(x: x, y: 9)], color(gold), width: 3)
            color(.systemMint, 0.9).setFill()
            NSBezierPath(roundedRect: .init(x: x - 8, y: 3, width: 17, height: 8), xRadius: 2, yRadius: 2)
                .fill()
            for i in 0..<5 {
                let p = (t * 0.6 + Double(i) * 0.19).truncatingRemainder(dividingBy: 1)
                ellipse(x - 12 - p * 15, 8 + p * 22, 4 * (1 - p) + 1, 3, color(.white, (1 - p) * 0.6))
            }
            spark(-35, 28, 3, color(.systemMint))
            spark(38, 35, 4, color(.white))
        case "rest":
            if sleeping {
                let moon = NSBezierPath()
                moon.move(to: .init(x: 38, y: 102))
                moon.curve(
                    to: .init(x: 48, y: 84), controlPoint1: .init(x: 25, y: 84),
                    controlPoint2: .init(x: 35, y: 77))
                moon.curve(
                    to: .init(x: 38, y: 102), controlPoint1: .init(x: 34, y: 86),
                    controlPoint2: .init(x: 34, y: 94))
                color(gold).setFill()
                moon.fill()
                for i in 0..<3 {
                    let p = (t * 0.3 + Double(i) * 0.28).truncatingRemainder(dividingBy: 1)
                    ("z" as NSString).draw(
                        at: .init(x: 18 + p * 22, y: 63 + p * 35),
                        withAttributes: [
                            .font: NSFont.monospacedSystemFont(ofSize: 9 + p * 4, weight: .medium),
                            .foregroundColor: color(blue, 1 - p),
                        ])
                }
                spark(-37, 92, 3, color(gold, 0.7))
            } else {
                ellipse(31, 86, 13, 13, color(gold))
                for i in 0..<8 {
                    let a = Double(i) * Double.pi / 4 + (reduced ? 0 : t * 0.25)
                    line(
                        [
                            .init(x: 37.5 + cos(a) * 10, y: 92.5 + sin(a) * 10),
                            .init(x: 37.5 + cos(a) * 15, y: 92.5 + sin(a) * 15),
                        ], color(gold))
                }
                spark(-36, 77, 4, color(.white))
                spark(31, 50, 3, color(gold))
            }
        default: break
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
