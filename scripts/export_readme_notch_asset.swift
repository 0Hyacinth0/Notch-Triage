#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct RGBAImage {
    let width: Int
    let height: Int
    var pixels: [UInt8]
}

enum ExportError: Error, CustomStringConvertible {
    case usage
    case decode(String)
    case bitmap
    case emptyForeground
    case encode(String)

    var description: String {
        switch self {
        case .usage:
            return "usage: export_readme_notch_asset.swift INPUT OUTPUT [CANVAS_WIDTH CANVAS_HEIGHT]"
        case .decode(let path):
            return "cannot decode image: \(path)"
        case .bitmap:
            return "cannot create RGBA bitmap"
        case .emptyForeground:
            return "no notch foreground found"
        case .encode(let path):
            return "cannot encode PNG: \(path)"
        }
    }
}

func decode(_ path: String) throws -> RGBAImage {
    let url = URL(fileURLWithPath: path) as CFURL
    guard
        let source = CGImageSourceCreateWithURL(url, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        throw ExportError.decode(path)
    }

    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    let created = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return false
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }

    guard created else { throw ExportError.bitmap }
    return RGBAImage(width: width, height: height, pixels: pixels)
}

func foregroundBounds(_ image: RGBAImage) throws -> (minX: Int, minY: Int, maxX: Int, maxY: Int, rowBounds: [(Int, Int)?]) {
    var rowBounds = Array<(Int, Int)?>(repeating: nil, count: image.height)
    var minX = image.width
    var minY = image.height
    var maxX = -1
    var maxY = -1

    for y in 0..<image.height {
        var left = image.width
        var right = -1

        for x in 0..<image.width {
            let offset = (y * image.width + x) * 4
            let r = Int(image.pixels[offset])
            let g = Int(image.pixels[offset + 1])
            let b = Int(image.pixels[offset + 2])
            let distanceFromWhite = max(255 - r, max(255 - g, 255 - b))

            // Screen captures are JPEG-backed and the outer canvas is white.
            // Ignore compression noise, then fill between the two silhouette edges
            // so white labels inside the black notch remain opaque.
            if distanceFromWhite >= 18 {
                left = min(left, x)
                right = max(right, x)
            }
        }

        if right >= left {
            rowBounds[y] = (left, right)
            minX = min(minX, left)
            minY = min(minY, y)
            maxX = max(maxX, right)
            maxY = max(maxY, y)
        }
    }

    guard maxX >= minX, maxY >= minY else { throw ExportError.emptyForeground }
    return (minX, minY, maxX, maxY, rowBounds)
}

func centeredTransparentAsset(from source: RGBAImage, canvasWidth: Int, canvasHeight: Int) throws -> RGBAImage {
    let bounds = try foregroundBounds(source)
    let contentWidth = bounds.maxX - bounds.minX + 1
    let contentHeight = bounds.maxY - bounds.minY + 1
    guard contentWidth <= canvasWidth, contentHeight <= canvasHeight else {
        throw ExportError.bitmap
    }

    let destinationX = (canvasWidth - contentWidth) / 2
    let destinationY = (canvasHeight - contentHeight) / 2
    var output = RGBAImage(
        width: canvasWidth,
        height: canvasHeight,
        pixels: [UInt8](repeating: 0, count: canvasWidth * canvasHeight * 4)
    )

    for sourceY in bounds.minY...bounds.maxY {
        guard let (left, right) = bounds.rowBounds[sourceY] else { continue }
        let outputY = destinationY + sourceY - bounds.minY

        for sourceX in left...right {
            let outputX = destinationX + sourceX - bounds.minX
            let sourceOffset = (sourceY * source.width + sourceX) * 4
            let outputOffset = (outputY * output.width + outputX) * 4
            let edgeDistance = min(sourceX - left, right - sourceX)

            if edgeDistance <= 1 {
                let r = Int(source.pixels[sourceOffset])
                let g = Int(source.pixels[sourceOffset + 1])
                let b = Int(source.pixels[sourceOffset + 2])
                let luminance = (54 * r + 183 * g + 19 * b) / 256
                let alpha = UInt8(clamping: 255 - luminance)
                output.pixels[outputOffset] = 0
                output.pixels[outputOffset + 1] = 0
                output.pixels[outputOffset + 2] = 0
                output.pixels[outputOffset + 3] = alpha
            } else {
                output.pixels[outputOffset] = source.pixels[sourceOffset]
                output.pixels[outputOffset + 1] = source.pixels[sourceOffset + 1]
                output.pixels[outputOffset + 2] = source.pixels[sourceOffset + 2]
                output.pixels[outputOffset + 3] = 255
            }
        }
    }

    return output
}

func encodePNG(_ image: RGBAImage, to path: String) throws {
    let data = Data(image.pixels)
    guard
        let provider = CGDataProvider(data: data as CFData),
        let cgImage = CGImage(
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    else {
        throw ExportError.bitmap
    }

    let outputURL = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    guard
        let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        )
    else {
        throw ExportError.encode(path)
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw ExportError.encode(path)
    }
}

do {
    let arguments = CommandLine.arguments
    guard arguments.count == 3 || arguments.count == 5 else { throw ExportError.usage }
    let canvasWidth = arguments.count == 5 ? Int(arguments[3]) ?? 560 : 560
    let canvasHeight = arguments.count == 5 ? Int(arguments[4]) ?? 96 : 96
    let source = try decode(arguments[1])
    let output = try centeredTransparentAsset(
        from: source,
        canvasWidth: canvasWidth,
        canvasHeight: canvasHeight
    )
    try encodePNG(output, to: arguments[2])
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
