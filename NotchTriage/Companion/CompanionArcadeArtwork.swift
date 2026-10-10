import AppKit

/// Original transparent imagegen art. Frame rectangles are measured from the
/// atlas; animation rows share their framing so expanding bursts never jitter.
@MainActor enum CompanionArcadeArtwork {
    private struct Region: Decodable {
        var x: Double, y: Double, width: Double, height: Double, extent: Double
    }
    private static var sprites: [Int: NSImage] = [:]
    private static let atlas = NSImage(named: "CompanionArcade")
    private static let regions: [Region] = {
        guard let url = Bundle.main.url(forResource: "CompanionArcade", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { return [] }
        return (try? JSONDecoder().decode([Region].self, from: data)) ?? []
    }()
    private static func sprite(_ index: Int) -> NSImage? {
        if let cached = sprites[index] { return cached }
        guard let atlas, regions.indices.contains(index), let rep = atlas.representations.first else {
            return nil
        }
        atlas.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        let region = regions[index]
        let image = NSImage(size: .init(width: 128, height: 128))
        let scale = 128 / region.extent
        let w = region.width * scale
        let h = region.height * scale
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        atlas.draw(
            in: NSRect(x: (128 - w) / 2, y: (128 - h) / 2, width: w, height: h),
            from: .init(
                x: region.x, y: atlas.size.height - region.y - region.height,
                width: region.width, height: region.height),
            operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        sprites[index] = image
        return image
    }
    @discardableResult
    static func draw(_ index: Int, at point: NSPoint, size: Double, alpha: Double = 1, rotated: Bool = false)
        -> Bool
    {
        guard let image = sprite(index) else { return false }
        let scale = size / max(image.size.width, image.size.height)
        let w = image.size.width * scale
        let h = image.size.height * scale
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .none
        if rotated {
            let transform = NSAffineTransform()
            transform.translateX(by: point.x, yBy: point.y)
            transform.rotate(byDegrees: 180)
            transform.translateX(by: -point.x, yBy: -point.y)
            transform.concat()
        }
        image.draw(
            in: .init(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h),
            from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return true
    }
}
