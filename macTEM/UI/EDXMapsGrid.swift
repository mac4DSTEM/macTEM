//
//  EDXMapsGrid.swift
//  Role: what a map's pixels are (`EDXMapRaster`, pure, pinned by EDXRoomTests). The maps block itself is `EDXMapsBlock.swift`.
//
//        A map is net counts of one line window in each pixel, background taken off (the kit's `ElementWindows.maps`); the
//        picture is linear from 0 to the map's maximum, negative pixels black. It is a picture of counts, not a composition.
//

import ShellMetal
import ShellSpectroscopy
import SwiftUI
import CoreGraphics
import SpectroCore
import SpectroEDX
import TEMCore
import TEMSession

/// Pixels of a map, pure: row-major RGBA, opaque.
nonisolated enum EDXMapRaster {
    /// A map in `hue` (0...1): black at 0, the full colour at the map's maximum. A map with no positive pixel is black. With `width`
    /// (the grid's columns) a NaN pixel, a composition the kit could not make, is hatched in grey stripes, not drawn as zero.
    static func rgba(values: [Double], hue: Double, width: Int? = nil) -> [UInt8] {
        let top = values.reduce(0.0) { max($0, $1.isFinite ? $1 : 0) }
        var out = [UInt8](repeating: 255, count: values.count * 4)
        for (i, v) in values.enumerated() {
            if let width, width > 0, v.isNaN {
                let g: UInt8 = ((i % width) + (i / width)) % 6 < 3 ? 120 : 40
                out[4 * i] = g; out[4 * i + 1] = g; out[4 * i + 2] = g
                continue
            }
            let f = top > 0 && v.isFinite ? min(max(v / top, 0), 1) : 0
            let (r, g, b) = hsb(hue: hue, saturation: 0.85, brightness: f)
            out[4 * i] = UInt8((r * 255).rounded()); out[4 * i + 1] = UInt8((g * 255).rounded()); out[4 * i + 2] = UInt8((b * 255).rounded())
        }
        return out
    }

    static func cgImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, rgba.count == width * height * 4,
              let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func hsb(hue: Double, saturation s: Double, brightness v: Double) -> (Double, Double, Double) {
        let h = (hue - floor(hue)) * 6
        let i = Int(h), f = h - Double(i)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i % 6 {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    /// The pixel under a point of the fitted picture (`size`), clamped to the grid; nil outside the picture.
    static func pixel(at point: CGPoint, in size: CGSize, nx: Int, ny: Int) -> (x: Int, y: Int)? {
        guard size.width > 0, size.height > 0, point.x >= 0, point.y >= 0, point.x <= size.width, point.y <= size.height else { return nil }
        return (min(Int(point.x / size.width * Double(nx)), nx - 1), min(Int(point.y / size.height * Double(ny)), ny - 1))
    }
}
