//
//  NORDIFBitmap.swift
//  Role: the 8-bit greyscale Windows bitmaps a NORDIF acquisition writes beside `Pattern.dat` (`Background
//        acquisition pattern.bmp`, `Background calibration pattern.bmp`, `Calibration (x,y).bmp`), decoded to the
//        pixel values kikuchipy's `matplotlib.pyplot.imread` returns for them: a (height, width) uint8 array, top row
//        first. Pillow opens such a file as mode "L" only when its palette is the identity greyscale ramp (index i is
//        grey i); any other bitmap reads as a different shape in kikuchipy and is refused here with a sentence.
//
//  Own decoder, not ImageIO: ImageIO colour-manages, and the parity is bit-exact. BITMAPINFOHEADER (or longer) with
//  BI_RGB, 8 bits per pixel, bottom-up or top-down rows, each row padded to four bytes.
//

import Foundation

package nonisolated enum NORDIFBitmap {
    /// Pixels in row-major order, the top row first.
    package struct Image: Equatable, Sendable {
        package var width: Int
        package var height: Int
        package var pixels: [UInt8]

        package init(width: Int, height: Int, pixels: [UInt8]) {
            self.width = width
            self.height = height
            self.pixels = pixels
        }

        package subscript(row: Int, column: Int) -> UInt8 { pixels[row * width + column] }
    }

    package enum Refusal: Error, Equatable {
        case notBitmap(String)
        case bitsPerPixel(String, Int)
        case compressed(String)
        case palette(String)
        case truncated(String)

        /// The app's words, after "<file> cannot be read: ".
        package var reason: String {
            switch self {
            case .notBitmap(let name): "\(name) is not a Windows bitmap."
            case .bitsPerPixel(let name, let bits): "\(name) is a \(bits)-bit bitmap; NORDIF patterns are 8-bit greyscale."
            case .compressed(let name): "\(name) is a compressed bitmap; NORDIF patterns are uncompressed."
            case .palette(let name): "\(name) has a palette that is not the greyscale ramp; NORDIF patterns are 8-bit greyscale."
            case .truncated(let name): "\(name) ends before its pixels do."
            }
        }
    }

    package static func read(path: String) throws -> Image {
        try decode(try Data(contentsOf: URL(fileURLWithPath: path)), fileName: (path as NSString).lastPathComponent)
    }

    package static func decode(_ data: Data, fileName: String) throws -> Image {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        func i32(_ at: Int) -> Int { Int(Int32(truncatingIfNeeded: UInt32(u32(at)))) }

        guard bytes.count >= 54, bytes[0] == 0x42, bytes[1] == 0x4D else { throw Refusal.notBitmap(fileName) }
        let pixelOffset = u32(10)
        let headerSize = u32(14)
        guard headerSize >= 40 else { throw Refusal.notBitmap(fileName) }
        let width = i32(18)
        let signedHeight = i32(22)
        let bitsPerPixel = u16(28)
        let compression = u32(30)
        guard width > 0, signedHeight != 0 else { throw Refusal.notBitmap(fileName) }
        guard bitsPerPixel == 8 else { throw Refusal.bitsPerPixel(fileName, bitsPerPixel) }
        guard compression == 0 else { throw Refusal.compressed(fileName) }
        let height = abs(signedHeight)
        let topDown = signedHeight < 0

        // The palette follows the DIB header: `colours used` entries of B, G, R, 0 (0 means all 256).
        var colours = headerSize >= 48 ? u32(46) : 0
        if colours == 0 || colours > 256 { colours = 256 }
        let paletteStart = 14 + headerSize
        guard paletteStart + colours * 4 <= bytes.count else { throw Refusal.truncated(fileName) }
        guard colours == 256 else { throw Refusal.palette(fileName) }
        for index in 0 ..< colours {
            let at = paletteStart + index * 4
            guard bytes[at] == index, bytes[at + 1] == index, bytes[at + 2] == index else { throw Refusal.palette(fileName) }
        }

        let stride = (width + 3) / 4 * 4
        guard pixelOffset + stride * height <= bytes.count else { throw Refusal.truncated(fileName) }
        var pixels = [UInt8](repeating: 0, count: width * height)
        for row in 0 ..< height {
            let source = pixelOffset + (topDown ? row : height - 1 - row) * stride
            pixels.replaceSubrange(row * width ..< (row + 1) * width, with: bytes[source ..< source + width])
        }
        return Image(width: width, height: height, pixels: pixels)
    }
}
