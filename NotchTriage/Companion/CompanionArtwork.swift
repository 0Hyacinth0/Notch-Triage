import AppKit
import SwiftUI

enum CompanionPose: String, CaseIterable {
    case idle, walk, carried, cuddle, wave, sleep, stretch, eat, look, groom
}

@MainActor enum CompanionArtwork {
    private static var cache: [String: NSImage] = [:]
    static let palettes: [NSColor] = [
        NSColor(red: 0.62, green: 0.89, blue: 0.73, alpha: 1),
        NSColor(red: 0.84, green: 0.91, blue: 0.99, alpha: 1),
        NSColor(red: 1, green: 0.77, blue: 0.82, alpha: 1),
    ]
    // Production uses faithful illustrated pixel atlases. The native renderer below
    // remains a fallback if an asset cannot be loaded.
    static func sprite(
        family: Int, form: Int, blink: Bool = false,
        pose: CompanionPose = .idle, frame: Int = 0
    ) -> NSImage {
        let family = min(2, max(0, family))
        let form = min(3, max(0, form))
        let frame = frame % 4
        let key = "\(family)-\(form)-\(blink)-\(pose.rawValue)-\(frame)"
        if let image = cache[key] { return image }
        if let image = CompanionSpriteAtlas.sprite(family: family, form: form, pose: pose, frame: frame) {
            cache[key] = image
            return image
        }
        var pixels = [Int](repeating: 0, count: 64 * 64)
        func dot(_ x: Int, _ y: Int, _ c: Int) {
            if (0..<64).contains(x) && (0..<64).contains(y) { pixels[y * 64 + x] = c }
        }
        func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: Int) {
            guard w > 0, h > 0 else { return }
            for j in y..<(y + h) { for i in x..<(x + w) { dot(i, j, c) } }
        }
        func oval(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: Int) {
            guard w > 0, h > 0 else { return }
            for j in y..<(y + h) {
                for i in x..<(x + w) {
                    let dx = (Double(i - x) + 0.5) / Double(w) * 2 - 1
                    let dy = (Double(j - y) + 0.5) / Double(h) * 2 - 1
                    if dx * dx + dy * dy <= 1 { dot(i, j, c) }
                }
            }
        }
        func line(_ x: Int, _ y: Int, _ xx: Int, _ yy: Int, _ c: Int, _ width: Int = 2) {
            let steps = max(1, max(abs(xx - x), abs(yy - y)))
            for i in 0...steps {
                rect(x + (xx - x) * i / steps, y + (yy - y) * i / steps, width, width, c)
            }
        }
        let asleep = pose == .sleep
        let held = pose == .carried
        let walk = pose == .walk ? [0, 2, 0, -2][frame] : 0
        let sway = [0, 1, 0, -1][frame]
        let stretch = pose == .stretch
        let happy = pose == .cuddle || pose == .wave || pose == .eat || pose == .groom
        func star(_ x: Int, _ y: Int, _ size: Int = 7) {
            rect(x + size / 2, y, 2, size, 9)
            rect(x, y + size / 2, size, 2, 9)
            rect(x + 2, y + 2, max(2, size - 4), max(2, size - 4), 9)
            dot(x + size / 2, y + size / 2, 3)
        }
        func flower(_ x: Int, _ y: Int) {
            oval(x - 3, y, 5, 5, 11)
            oval(x + 3, y, 5, 5, 11)
            oval(x, y - 3, 5, 5, 11)
            oval(x, y + 3, 5, 5, 11)
            oval(x, y, 5, 5, 9)
            dot(x + 1, y + 1, 3)
        }
        func lamp(_ x: Int, _ y: Int) {
            rect(x + 2, y - 1, 5, 2, 1)
            oval(x, y, 9, 10, 10)
            oval(x + 1, y + 1, 7, 8, 9)
            rect(x + 3, y + 2, 2, 6, 3)
            line(x + 3, y + 9, x + 3 + sway, y + 13, 10, 1)
        }
        func face(_ y: Int, _ baby: Bool = false) {
            let x1 = baby ? 26 : 22
            let x2 = baby ? 36 : 36
            let eyeW = baby ? 5 : 7
            let eyeH = baby ? 6 : 9
            let look = pose == .look ? (frame < 2 ? -1 : 1) : 0
            if blink || asleep || happy {
                for x in [x1, x2] {
                    line(x, y + 3, x + 2, y + 1, 4, 1)
                    line(x + 2, y + 1, x + eyeW - 1, y + 3, 4, 1)
                }
            } else {
                for x in [x1, x2] {
                    oval(x + look, y, eyeW, eyeH, 4)
                    rect(x + 1 + look, y + 3, eyeW - 2, eyeH - 3, family == 0 ? 6 : family == 1 ? 8 : 10)
                    rect(x + look, y + 1, 2, 2, 3)
                }
            }
            oval(baby ? 23 : 18, y + (baby ? 5 : 7), baby ? 5 : 7, 3, 11)
            oval(baby ? 40 : 40, y + (baby ? 5 : 7), baby ? 5 : 7, 3, 11)
            if pose == .eat || stretch {
                oval(30, y + 9, 5, 4 + frame % 2, 4)
                oval(31, y + 11, 3, 2, 11)
            } else {
                line(30, y + 9, 32, y + 11, 4, 1)
                line(32, y + 11, 34, y + 9, 4, 1)
            }
        }
        if form == 0 {
            // Babies are small round beans with buds, not shrunken adults.
            let top = asleep ? 38 : stretch ? 27 : 31 + abs(walk) / 2
            let height = asleep ? 18 : held ? 24 : 22
            if family == 0 {
                line(31, top, 31, top - 8, 6, 1)
                oval(23 - sway, top - 11, 9, 5, 7)
                oval(32 + sway, top - 14, 7, 9, 7)
            } else if family == 1 {
                oval(23, top - 5, 9, 10, 8)
                oval(31, top - 7, 10, 10, 8)
                oval(25, top - 6, 13, 11, 3)
            } else {
                oval(27 + sway, top - 11, 11, 15, 10)
                oval(29 + sway, top - 10, 6, 11, 11)
                oval(31 + sway, top - 9, 3, 8, 9)
            }
            oval(19, top, 27, height, 1)
            oval(20, top, 25, height - 1, 2)
            oval(21, top, 23, height - 3, 3)
            let pawY = held ? top + height - 2 : top + height - 4
            oval(23, pawY + walk / 2, 6, 5, 2)
            oval(36, pawY - walk / 2, 6, 5, 2)
            let handY = happy ? top + 9 - frame % 2 : top + 15
            oval(17, handY, 6, held ? 8 : 5, 2)
            oval(42, handY, 6, held ? 8 : 5, 2)
            face(top + 8, true)
        } else {
            let young = form == 1
            let headY = asleep ? 32 : stretch ? 14 : young ? 25 : 20 + abs(walk) / 2
            let bodyY = asleep ? 43 : young ? 41 : held ? 35 : 36
            let bodyH = asleep ? 12 : young ? 14 : held ? 21 : 18
            let bodyX = young ? 22 : 19
            let bodyW = young ? 23 : 27
            let headW = young ? 32 : 38
            let headX = 32 - headW / 2
            // Each tail belongs to its actual form, including both branches.
            if family == 0 {
                if young {
                    oval(44, 43 + sway, 9, 8, 7)
                    oval(49, 39 + sway, 6, 8, 6)
                } else if form == 2 {
                    oval(44, 35 + sway, 17, 20, 6)
                    oval(46, 37 + sway, 12, 15, 7)
                    oval(49, 39 + sway, 6, 9, 0)
                    line(44, 50, 53, 51 + sway, 6)
                    oval(52, 32 + sway, 9, 7, 7)
                } else {
                    line(43, 48, 57, 43 + sway, 6)
                    line(57, 43 + sway, 57, 25 + sway, 6)
                    oval(53, 28 + sway, 8, 5, 7)
                    for y in [29, 39] {
                        oval(54, y + sway, 9, 8, 11)
                        rect(55, y + 6 + sway, 7, 3, 3)
                    }
                }
            } else if family == 1 {
                if young {
                    oval(44, 43 + sway, 11, 10, 8)
                    oval(45, 42 + sway, 8, 8, 3)
                } else if form == 2 {
                    oval(44, 35 + sway, 17, 20, 8)
                    for part in [(44, 32), (50, 35), (51, 43), (44, 45)] {
                        oval(part.0, part.1 + sway, 11, 11, 3)
                    }
                    oval(47, 39 + sway, 8, 8, 8)
                    oval(48, 40 + sway, 5, 5, 3)
                } else {
                    line(44, 48, 57, 34 + sway, 8, 3)
                    line(48, 49, 61, 38 + sway, 8)
                    star(52, 30 + sway, 10)
                }
            } else {
                if young {
                    oval(44, 45 + sway, 10, 7, 10)
                    oval(49, 42 + sway, 7, 5, 11)
                } else if form == 2 {
                    line(45, 48, 56, 44 + sway, 10, 3)
                    oval(50, 34 + sway, 11, 14, 11)
                    oval(53, 36 + sway, 6, 11, 9)
                    line(55, 47, 53, 55 + sway, 10, 2)
                } else {
                    oval(45, 37 + sway, 16, 18, 10)
                    oval(48, 40 + sway, 10, 11, 0)
                    line(44, 51, 54, 53 + sway, 10)
                    oval(51, 47 + sway, 7, 7, 11)
                    oval(57, 48 + sway, 6, 7, 11)
                    oval(55, 49 + sway, 4, 4, 9)
                }
            }
            oval(bodyX, bodyY, bodyW, bodyH, 1)
            oval(bodyX + 2, bodyY, bodyW - 4, bodyH - 2, 2)
            oval(bodyX + 5, bodyY + 1, bodyW - 10, bodyH - 5, 3)
            let feetY = held ? 54 : 50
            oval(young ? 23 : 20, feetY + walk, young ? 8 : 10, 7, 1)
            oval(young ? 35 : 35, feetY - walk, young ? 8 : 10, 7, 1)
            oval(young ? 24 : 22, feetY + walk, young ? 6 : 7, 5, 3)
            oval(36, feetY - walk, young ? 6 : 7, 5, 3)
            if family == 0 {
                if young {
                    oval(11 - sway, headY - 1, 19, 9, 6)
                    oval(13 - sway, headY - 1, 14, 6, 7)
                    oval(36 + sway, headY - 2, 17, 10, 6)
                    oval(38 + sway, headY - 2, 12, 7, 7)
                    oval(29, headY - 7, 7, 11, 7)
                } else if form == 2 {
                    for x in [6, 39] {
                        oval(x + sway, headY - 7, 20, 18, 6)
                        oval(x + 2 + sway, headY - 6, 16, 13, 7)
                        oval(x + 2 - sway, headY + 1, 17, 15, 6)
                        oval(x + 3 - sway, headY + 1, 13, 10, 7)
                    }
                    oval(25, headY - 13, 10, 18, 7)
                    oval(34, headY - 11, 8, 17, 6)
                } else {
                    oval(8 - sway, headY + 1, 18, 21, 6)
                    oval(9 - sway, headY + 1, 14, 17, 11)
                    oval(39 + sway, headY + 1, 18, 21, 6)
                    oval(41 + sway, headY + 1, 14, 17, 11)
                }
            } else if family == 1 {
                for x in young ? [14, 39] : [8, 39] {
                    oval(x, headY - (young ? 3 : 6), young ? 12 : 18, young ? 13 : 21, 8)
                    oval(x + 2, headY - 6, young ? 9 : 13, young ? 10 : 16, 3)
                    if !young { oval(x - 1, headY + 2, 13, 11, 3) }
                }
                oval(27, headY - (young ? 5 : 10), young ? 10 : 14, young ? 9 : 14, 3)
                if form == 3 {
                    oval(26, headY - 14, 13, 16, 8)
                    oval(29, headY - 12, 8, 10, 3)
                    oval(29, headY - 11, 5, 6, 0)
                    star(9, headY - 2)
                    star(49, headY + 2)
                }
            } else if form == 3 {
                for x in [14 - sway, 40 + sway] {
                    oval(x, headY - 14, 12, 24, 10)
                    oval(x + 2, headY - 13, 8, 19, 11)
                    oval(x - 2, headY - 17, 12, 10, 10)
                    oval(x + 1, headY - 15, 6, 5, 0)
                }
                line(15 - sway, headY - 7, 10 - sway, headY + 2, 10, 1)
                lamp(5 - sway, headY + 2)
                line(49 + sway, headY - 7, 54 + sway, headY + 2, 10, 1)
                lamp(51 + sway, headY + 2)
            } else {
                oval(young ? 15 : 8, headY - 2, young ? 13 : 19, young ? 11 : 16, 10)
                oval(young ? 37 : 40, headY - 2, young ? 13 : 19, young ? 11 : 16, 11)
                oval(26, headY - (young ? 9 : 15), young ? 13 : 16, young ? 13 : 21, 10)
                oval(29, headY - (young ? 9 : 14), young ? 7 : 10, young ? 9 : 16, 11)
                oval(31, headY - 10, 5, 11, 9)
            }
            oval(headX - 1, headY, headW + 2, asleep ? 22 : 28, 1)
            oval(headX, headY, headW, asleep ? 20 : 26, 2)
            oval(headX + 2, headY, headW - 4, asleep ? 18 : 24, 3)
            for x in [headX, headX + headW - 4] { rect(x, headY + 10, 4, 8, 3) }
            face(headY + (asleep ? 10 : 12))
            let armY = held ? 43 : stretch ? 29 : happy ? 31 - frame % 2 * 3 : young ? 44 : 40 + walk
            let leftY = pose == .wave ? 43 : pose == .groom ? headY + 13 + frame % 2 * 2 : armY
            oval(happy || stretch ? 12 : young ? 19 : 15, leftY, young ? 8 : 10, held ? 13 : 8, 1)
            oval(happy || stretch ? 13 : young ? 20 : 16, leftY, young ? 6 : 8, held ? 11 : 6, 3)
            oval(
                happy || stretch ? 43 : young ? 39 : 40, held ? armY : armY - walk * 2, young ? 8 : 10,
                held ? 13 : 8, 1)
            oval(
                happy || stretch ? 44 : young ? 40 : 41, held ? armY : armY - walk * 2, young ? 6 : 8,
                held ? 11 : 6, 3)
            if family == 0 {
                if form == 3 {
                    for x in [19, 27, 35, 43] {
                        oval(x, 43, 7, 13, 11)
                        oval(x + 1, 43, 5, 6, 7)
                    }
                    for x in [19, 28, 37] { flower(x, headY - 2) }
                    flower(30, 44)
                } else {
                    for x in young ? [26, 34] : [20, 27, 34, 41] {
                        oval(x, young ? 46 : 43, 8, young ? 5 : 8, 7)
                    }
                    if !young {
                        oval(29, 46, 6, 7, 9)
                        rect(31, 47, 2, 3, 3)
                    }
                }
            } else if family == 1 {
                if young {
                    oval(27, 46, 10, 5, 8)
                } else {
                    rect(23, 43, 20, 4, 8)
                    rect(36, 45, 5, 10, 8)
                    if form == 3 {
                        star(27, 47, 7)
                        star(37, 49, 6)
                    } else {
                        rect(36, 51, 5, 2, 3)
                    }
                }
            } else if young {
                for x in [25, 31, 37] { oval(x, 45, 7, 6, 11) }
            } else if form == 2 {
                oval(23, 43, 19, 7, 10)
                lamp(23, 44)
                lamp(35, 44)
            } else {
                oval(29, 43, 8, 8, 9)
                oval(32, 42, 6, 7, 2)
                rect(23, 49, 19, 2, 10)
            }
        }
        // One shared palette keeps the twelve independently drawn silhouettes coherent.
        let colors: [NSColor] = [
            .clear,
            .init(red: 0.64, green: 0.48, blue: 0.40, alpha: 1),
            .init(red: 0.96, green: 0.87, blue: 0.71, alpha: 1),
            .init(red: 1, green: 0.97, blue: 0.87, alpha: 1),
            .init(red: 0.23, green: 0.28, blue: 0.32, alpha: 1),
            palettes[family],
            .init(red: 0.29, green: 0.58, blue: 0.40, alpha: 1),
            .init(red: 0.66, green: 0.88, blue: 0.61, alpha: 1),
            .init(red: 0.37, green: 0.68, blue: 0.84, alpha: 1),
            .init(red: 1, green: 0.78, blue: 0.36, alpha: 1),
            .init(red: 0.80, green: 0.48, blue: 0.66, alpha: 1),
            .init(red: 1, green: 0.72, blue: 0.77, alpha: 1),
        ]
        let image = NSImage(size: .init(width: 64, height: 64))
        image.lockFocus()
        NSGraphicsContext.current?.shouldAntialias = false
        for y in 0..<64 {
            for x in 0..<64 where pixels[y * 64 + x] != 0 {
                colors[pixels[y * 64 + x]].setFill()
                NSRect(x: x, y: 63 - y, width: 1, height: 1).fill()
            }
        }
        image.unlockFocus()
        cache[key] = image
        return image
    }
    static func drawPet(
        _ pet: CompanionPet, rect: NSRect, time: Double, effects: Double, reduced: Bool, action: String = "",
        actionAge: Double = 99, previousForm: Int? = nil, accessories: Set<Int> = [],
        pose: CompanionPose = .idle, facingLeft: Bool = false, lean: Double = 0, releaseAge: Double = 99,
        squash: Double = 0
    ) {
        let bob =
            reduced || pose == .sleep ? 0 : sin(time * (pose == .walk ? 12 : 2.3)) * (pose == .walk ? 2.5 : 1)
        let wave = reduced || actionAge > 1 ? 0 : sin(actionAge * .pi * 5) * exp(-actionAge * 3) * 0.12
        var r = rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.08)
        r.origin.y += bob
        r.size.width *= 1 + wave
        r.size.height *= 1 - wave
        if !reduced { r = r.insetBy(dx: -r.width * squash / 2, dy: r.height * squash / 2) }
        if releaseAge < 0.8 && !reduced {
            let bounce = sin(releaseAge * 17) * exp(-releaseAge * 5)
            r.origin.y += max(0, bounce * 8)
            r = r.insetBy(dx: -r.width * bounce * 0.05, dy: r.height * bounce * 0.05)
        }
        if action == "hatch" && actionAge < 0.8 {
            let shake = reduced ? 0 : sin(actionAge * 35) * 3
            let egg = NSRect(
                x: rect.midX - rect.width * 0.2 + shake, y: rect.midY - rect.height * 0.22,
                width: rect.width * 0.4, height: rect.height * 0.45)
            NSColor(red: 1, green: 0.95, blue: 0.80, alpha: 1).setFill()
            egg.insetBy(dx: 4, dy: 0).fill()
            egg.insetBy(dx: 0, dy: 5).fill()
            palettes[pet.family].setFill()
            NSRect(x: egg.midX - 4, y: egg.midY - 3, width: 8, height: 6).fill()
            if actionAge > 0.4 {
                NSColor.darkGray.setFill()
                NSRect(x: egg.midX, y: egg.midY - 8, width: 2, height: 18).fill()
            }
            return
        }
        if action == "hatch" && actionAge < 1.4 { r.origin.y -= (1.4 - actionAge) * 15 }
        let shownForm = action == "evolve" && actionAge < 1.5 ? previousForm ?? pet.form : pet.form
        if pose == .cuddle && !reduced { r.origin.y += sin(time * 8) * 2 }
        if action == "evolve" && actionAge < 2.4 && !reduced {
            let pulse = sin(actionAge * .pi * 4) * 0.04
            r = r.insetBy(dx: -r.width * pulse, dy: r.height * pulse)
        }
        CompanionCareEffects.draw(
            action, in: rect, age: actionAge, intensity: effects,
            reduced: reduced, sleeping: pose == .sleep, behind: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .none
        if effects > 0 {
            let shadow = NSShadow()
            shadow.shadowColor = palettes[pet.family].withAlphaComponent(0.35 * min(1.5, effects))
            shadow.shadowBlurRadius = 8 * effects
            shadow.set()
        }
        var activePose = pose
        if actionAge < CompanionCareEffects.duration(action) && pose != .carried && pose != .sleep {
            if action == "pet" { activePose = .cuddle }
            if action == "meal" || action == "snack" { activePose = .eat }
            if action == "bath" { activePose = .groom }
            if action == "clean" { activePose = .look }
            if action == "rest" { activePose = .stretch }
            if action == "out" || action == "hatch" { activePose = .stretch }
        }
        let transform = NSAffineTransform()
        transform.translateX(by: r.midX, yBy: r.midY)
        if !reduced { transform.rotate(byDegrees: CGFloat(lean)) }
        transform.scaleX(by: facingLeft ? -1 : 1, yBy: 1)
        transform.translateX(by: -r.midX, yBy: -r.midY)
        transform.concat()
        sprite(
            family: pet.family, form: shownForm,
            blink: time.truncatingRemainder(dividingBy: 4) < 0.12,
            pose: activePose, frame: reduced ? 0 : Int(time * (activePose == .walk ? 9 : 4)) % 4
        )
        .draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
        if accessories.contains(1) || accessories.contains(3) {
            (accessories.contains(3) ? NSColor.systemMint : .init(red: 1, green: 0.93, blue: 0.77, alpha: 1))
                .setFill()
            NSRect(
                x: r.minX + r.width * 0.37, y: r.minY + r.height * 0.22, width: r.width * 0.26,
                height: r.height * 0.10
            ).fill()
        }
        if accessories.contains(6) {
            NSColor.systemGreen.setFill()
            NSRect(x: r.midX - 6, y: r.maxY - 10, width: 12, height: 4).fill()
        }
        if accessories.contains(8) {
            NSColor.systemYellow.setFill()
            NSRect(x: r.maxX - 10, y: r.minY + 10, width: 5, height: 5).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        if CompanionCareEffects.actions.contains(action) {
            CompanionCareEffects.draw(
                action, in: rect, age: actionAge, intensity: effects,
                reduced: reduced, sleeping: pose == .sleep, behind: false)
            return
        }
        let lightDuration = action == "evolve" ? 2.4 : 1.2
        if actionAge < lightDuration && effects > 0 {
            let n = max(2, Int(6 * effects))
            for i in 0..<n {
                let angle = Double(i) * .pi * 2 / Double(n)
                let radius = rect.width * (0.3 + actionAge * 0.5)
                palettes[pet.family].withAlphaComponent(max(0, 1 - actionAge / lightDuration)).setFill()
                NSRect(
                    x: rect.midX + cos(angle) * radius, y: rect.midY + sin(angle) * radius, width: 3,
                    height: 3
                ).fill()
            }
        }
    }
}

struct CompanionPortrait: View {
    let pet: CompanionPet
    var body: some View {
        Image(nsImage: CompanionArtwork.sprite(family: pet.family, form: pet.form))
            .interpolation(.none).resizable().scaledToFit()
            .shadow(color: Color(nsColor: CompanionArtwork.palettes[pet.family]).opacity(0.25), radius: 8)
    }
}
