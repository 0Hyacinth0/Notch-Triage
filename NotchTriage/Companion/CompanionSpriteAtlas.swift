import AppKit

/// Original imagegen sprite atlases. The JSON stores measured source bounds:
/// illustrations have uneven gutters, so uniform grid slicing would cut tails
/// and accidentally display parts of another stage. Source PNG alpha is kept.
@MainActor enum CompanionSpriteAtlas {
    private struct Region: Decodable {
        let x: Double, y: Double, width: Double, height: Double
        let spans: [[Int]]
    }
    private struct Atlas {
        let image: NSImage
        let regions: [Region]
    }
    private static var atlases: [String: Atlas] = [:]
    private static var missing = Set<String>()
    private static func atlas(_ name: String) -> Atlas? {
        if let saved = atlases[name] { return saved }
        guard !missing.contains(name) else { return nil }
        guard let image = NSImage(named: name),
            let url = Bundle.main.url(forResource: name, withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let regions = try? JSONDecoder().decode([Region].self, from: data), regions.count == 24
        else {
            missing.insert(name)
            return nil
        }
        // The atlas coordinates use actual source pixels, not a @2x point size.
        if let rep = image.representations.first {
            image.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        let loaded = Atlas(image: image, regions: regions)
        atlases[name] = loaded
        return loaded
    }
    static func sprite(family: Int, form: Int, pose: CompanionPose, frame: Int) -> NSImage? {
        let name: String
        let alternate: Int
        switch pose {
        case .carried:
            name = "CompanionIdleCarry"
            alternate = 1
        case .sleep:
            name = "CompanionRestStretch"
            alternate = 0
        case .stretch:
            name = "CompanionRestStretch"
            alternate = 1
        case .wave, .cuddle, .groom:
            name = "CompanionWaveEat"
            alternate = 0
        case .eat:
            name = "CompanionWaveEat"
            alternate = 1
        case .idle, .walk, .look:
            name = "CompanionIdleCarry"
            alternate = 0
        }
        guard let atlas = atlas(name) else { return nil }
        let region = atlas.regions[family * 8 + form * 2 + alternate]
        let source = NSRect(
            x: region.x, y: atlas.image.size.height - region.y - region.height,
            width: region.width, height: region.height)
        // Preserve source proportions and keep a consistent foot baseline.
        // Babies intentionally occupy less space than adults.
        let maxSize: Double = [72, 94, 116, 116][form]
        let neutral = Self.atlas("CompanionIdleCarry")?.regions[family * 8 + form * 2] ?? region
        let scale = min(maxSize / max(neutral.width, neutral.height), 120 / max(source.width, source.height))
        let size = NSSize(width: source.width * scale, height: source.height * scale)
        let phase = [0.0, 1.0, 0.0, -1.0][frame % 4]
        var destination = NSRect(x: (128 - size.width) / 2, y: 8, width: size.width, height: size.height)
        if pose == .carried { destination.origin.y += phase * 1.2 }
        if pose == .stretch { destination.origin.y += abs(phase) * 2 }
        func drawSource(in rect: NSRect) {
            NSGraphicsContext.saveGraphicsState()
            let contour = NSBezierPath()
            for span in region.spans where span.count == 3 {
                contour.appendRect(
                    NSRect(
                        x: rect.minX + Double(span[1]) / source.width * rect.width,
                        y: rect.minY + (source.height - Double(span[0]) - 1) / source.height * rect.height,
                        width: Double(span[2]) / source.width * rect.width,
                        height: rect.height / source.height))
            }
            contour.addClip()
            atlas.image.draw(in: rect, from: source, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }
        let image = NSImage(size: NSSize(width: 128, height: 128))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        if pose == .walk {
            // Animate the lower body as two alternating leg strips while the
            // upper body keeps its silhouette and all the original details.
            let split = destination.minY + destination.height * 0.22
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: 0, y: split, width: 128, height: 128 - split).clip()
            drawSource(in: destination)
            NSGraphicsContext.restoreGraphicsState()
            for side in 0..<2 {
                NSGraphicsContext.saveGraphicsState()
                NSRect(
                    x: destination.minX + Double(side) * destination.width / 2, y: 0,
                    width: destination.width / 2, height: split
                ).clip()
                var leg = destination
                leg.origin.y += (side == 0 ? phase : -phase) * 1.8
                drawSource(in: leg)
                NSGraphicsContext.restoreGraphicsState()
            }
        } else {
            if pose == .wave || pose == .cuddle || pose == .groom {
                let transform = NSAffineTransform()
                transform.translateX(by: 64, yBy: 8)
                transform.rotate(byDegrees: phase * 2)
                transform.translateX(by: -64, yBy: -8)
                transform.concat()
            }
            drawSource(in: destination)
        }
        image.unlockFocus()
        return image
    }
}
