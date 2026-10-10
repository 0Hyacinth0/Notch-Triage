import AppKit
import SwiftUI

/// Pixel-art relic emblems generated for the two game inventories.
@MainActor enum CompanionRelicArtwork {
    private struct Region: Decodable {
        var x: Double, y: Double, width: Double, height: Double
    }
    private static let atlas = NSImage(named: "CompanionRelics")
    private static let regions: [Region] = {
        guard let url = Bundle.main.url(forResource: "CompanionRelics", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { return [] }
        return (try? JSONDecoder().decode([Region].self, from: data)) ?? []
    }()
    private static var cache: [Int: NSImage] = [:]

    static func image(game: CompanionGame, number: Int) -> NSImage? {
        let index = (game == .snake ? 0 : 8) + number - 1
        guard (0..<16).contains(index) else { return nil }
        if let cached = cache[index] { return cached }
        guard let atlas, regions.indices.contains(index), let rep = atlas.representations.first else {
            return nil
        }
        atlas.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        let r = regions[index]
        let image = NSImage(size: .init(width: 128, height: 128))
        let scale = 100 / max(r.width, r.height)
        let w = r.width * scale
        let h = r.height * scale
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        atlas.draw(
            in: .init(x: (128 - w) / 2, y: (128 - h) / 2, width: w, height: h),
            from: .init(
                x: r.x, y: atlas.size.height - r.y - r.height,
                width: r.width, height: r.height),
            operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        cache[index] = image
        return image
    }
}

struct CompanionRelicGlyph: View {
    let game: CompanionGame
    let number: Int
    var size: CGFloat
    var rank: Int? = nil

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image = CompanionRelicArtwork.image(game: game, number: number) {
                    Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
                } else {
                    Image(systemName: "sparkles").resizable().scaledToFit().padding(size * 0.2)
                        .foregroundStyle(game == .snake ? Color.mint : Color.cyan)
                }
            }
            .padding(size * 0.08)
            .frame(width: size, height: size)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: size * 0.22))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.22).strokeBorder(
                    (game == .snake ? Color.mint : Color.cyan).opacity(0.32), lineWidth: 0.7))
            if let rank {
                Text("R\(rank)").font(.system(size: max(7, size * 0.19), weight: .bold, design: .rounded))
                    .padding(.horizontal, 2).background(.black.opacity(0.78), in: Capsule())
                    .offset(x: 2, y: 2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(CompanionCatalog.relics(game)[number - 1].name)
    }
}
