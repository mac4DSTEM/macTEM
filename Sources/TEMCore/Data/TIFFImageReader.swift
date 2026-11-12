//
//  TIFFImageReader.swift
//  Role: open one 2D TIFF image as macTEM's `CalibratedImage`. The reading is FormatoKit's `TIFFAppImage` (FormatoTIFF, the first
//        consumer's named option, pinned in the kit to this app's source and to RosettaSciIO 049e7d70 + tifffile 2026.9.20: a
//        baseline TIFF's first directory, uncompressed or LZW (FormatoKit 0.15.0), striped, chunky; one sample of 8/16/32 bits or float, or an
//        equal-channel 8-bit RGB read as a grey render; the Velox XML, FEI SEM INI, Digital Micrograph and ImageJ
//        calibrations in that order; everything else refused by name). This file is the seam: the app's refusal wording
//        (`Refusal.reason`), the Cocoa error for an unreadable file, and `KitImages` (the one conversion of a kit image to a
//        `CalibratedImage`). The parity against RosettaSciIO and tifffile is FormatoKit's.
//
//  ONE STRICTER CASE (accepted at the switch, FormatoKit 0.5.0): a tag whose value lies outside the file, or of a type the
//  reader does not know, was ignored by the app's former reader; `TIFFAppImage` refuses the file as truncated. A valid
//  TIFF reads as before.
//

import Foundation
import FormatoCore
import FormatoTIFF

package nonisolated enum TIFFImageReader {
    /// Why a TIFF is not read. Each names what the file holds, so the refusal is specific.
    package enum Refusal: Error, Equatable {
        case notTIFF
        case truncated
        case multiPage
        case compressed(scheme: Int)
        case tiled
        case unequalChannels(row: Int, column: Int)
        case sampleFormat(String)

        /// The kit's refusal in the app's type (the wording below is the app's).
        package init(_ refusal: TIFFAppImage.Refusal) {
            switch refusal {
            case .notTIFF: self = .notTIFF
            case .truncated: self = .truncated
            case .multiPage: self = .multiPage
            case .compressed(let scheme): self = .compressed(scheme: scheme)
            case .tiled: self = .tiled
            case .unequalChannels(let row, let column): self = .unequalChannels(row: row, column: column)
            case .sampleFormat(let what): self = .sampleFormat(what)
            }
        }

        /// One sentence for the person who opened the file.
        package var reason: String {
            switch self {
            case .notTIFF: "it is not a TIFF file."
            case .truncated: "the file ends before its image does."
            case .multiPage: "it holds more than one page, and they are not grey frames of one size; other image stacks are not read yet."
            case .compressed(let scheme): "its pixels are compressed with \(TIFFImageReader.compressionName(scheme)), which macEM does not read yet."
            case .tiled: "its pixels are stored in tiles; only striped TIFF is read."
            case .unequalChannels:
                "it is a colour image whose colours could not be read as one picture."
            case .sampleFormat(let what): "its pixel layout is not read (\(what))."
            }
        }
    }

    /// TIFF Compression tag values by name (TIFF 6.0, libtiff's tiff.h), so a refusal names the scheme, not its number.
    package static func compressionName(_ scheme: Int) -> String {
        switch scheme {
        case 2, 3, 4: "CCITT fax coding"
        case 5: "LZW"
        case 6, 7, 34892: "JPEG"
        case 8, 32946: "Deflate (ZIP)"
        case 32773: "PackBits"
        case 34925: "LZMA"
        case 50000: "Zstandard"
        case 50001: "WebP"
        case 34933, 50002: "JPEG XL"
        default: "a scheme it does not know"
        }
    }

    /// The notes a reading can attach (`CalibratedImage.notes`), worded once.
    package enum Note {
        package static let render = TIFFAppImage.Note.render
        package static let veloxUnvalidated = TIFFAppImage.Note.veloxUnvalidated
        package static let veloxDisagree = TIFFAppImage.Note.veloxDisagree
        /// A colour TIFF opened as grey (#541): what is on screen is the file's picture, not its data.
        package static let colourRender = "Colour render (the file's colour table and any annotations burnt in), shown as grey: "
            + "each pixel is the brightest of its red, green and blue, not counts"
    }

    // MARK: - Reading

    package static func read(path: String) throws -> CalibratedImage {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        let fileName = formatoDisplayFileName(path)
        do {
            return try read(data: data, fileName: fileName)
        } catch Refusal.unequalChannels {
            return try colourRender(path: path, data: data, fileName: fileName)
        }
    }

    /// An 8-bit RGB TIFF whose channels differ, as Gatan DigitalMicrograph exports a displayed image (its colour table and
    /// annotations burnt in; real-file sweep, #541), opens as grey: each pixel the brightest of its three channels (HSV value),
    /// which keeps a one-colour table's ramp exact and leaves annotations visible. The calibration is the kit's for the file.
    /// App-side until FormatoKit's `TIFFAppImage` reads it: delete at FormatoKit 0.16.0.
    static func colourRender(path: String, data: Data, fileName: String) throws -> CalibratedImage {
        let calibrated: TIFFAppImage.Image
        do {
            calibrated = try TIFFAppImage.read(data: data, fileName: fileName, acceptUnequalChannels: true)
        } catch let refusal as TIFFAppImage.Refusal {
            throw Refusal(refusal)
        }
        let rgb = try TIFFSignals(path: path).signal(series: 0).load().data
        let count = calibrated.width * calibrated.height
        guard rgb.dataType == .rgb8, rgb.shape == [calibrated.height, calibrated.width], rgb.bytes.count == 3 * count else {
            throw Refusal.unequalChannels(row: 0, column: 0)
        }
        var pixels = [Float](repeating: 0, count: count)
        rgb.bytes.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for i in 0..<count { pixels[i] = Float(max(p[3 * i], p[3 * i + 1], p[3 * i + 2])) }
        }
        let notes = calibrated.notes.filter { $0 != Note.render } + [Note.colourRender]
        return CalibratedImage(width: calibrated.width, height: calibrated.height, pixels: pixels,
                               x: calibrated.x.map(AxisCalibration.init), y: calibrated.y.map(AxisCalibration.init),
                               fileName: calibrated.fileName,
                               source: calibrated.source.replacingOccurrences(of: Note.render, with: "colour render shown as grey, not counts"),
                               voltage: nil, notes: notes)
    }

    package static func read(data: Data, fileName: String) throws -> CalibratedImage {
        do {
            return CalibratedImage(try TIFFAppImage.read(data: data, fileName: fileName))
        } catch let refusal as TIFFAppImage.Refusal {
            throw Refusal(refusal)
        }
    }
}
