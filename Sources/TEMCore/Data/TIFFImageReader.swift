//
//  TIFFImageReader.swift
//  Role: open one 2D TIFF image as macTEM's `CalibratedImage`. The reading is FormatoKit's `TIFFAppImage` (FormatoTIFF, the first
//        consumer's named option, pinned in the kit to this app's source and to RosettaSciIO 049e7d70 + tifffile 2026.9.20: a
//        baseline TIFF's first directory, uncompressed, striped, chunky; one sample of 8/16/32 bits or float, or an
//        equal-channel 8-bit RGB read as a grey render; the Velox XML, FEI SEM INI, Digital Micrograph and ImageJ
//        calibrations in that order; everything else refused by name). This file is the seam: the app's refusal wording
//        (`Refusal.reason`), the Cocoa error for an unreadable file, and `KitImages` (the one conversion of a kit image to a
//        `CalibratedImage`). Checked by tools/parity/tiff-reader-parity.
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
            case .compressed(let scheme): "its pixels are compressed (scheme \(scheme)); only uncompressed TIFF is read."
            case .tiled: "its pixels are stored in tiles; only striped TIFF is read."
            case .unequalChannels(let row, let column):
                "it is a colour image (row \(row), column \(column) differs between red, green and blue); only a grey render is read."
            case .sampleFormat(let what): "its pixel layout is not read (\(what))."
            }
        }
    }

    /// The notes a reading can attach (`CalibratedImage.notes`), worded once.
    package enum Note {
        package static let render = TIFFAppImage.Note.render
        package static let veloxUnvalidated = TIFFAppImage.Note.veloxUnvalidated
        package static let veloxDisagree = TIFFAppImage.Note.veloxDisagree
    }

    // MARK: - Reading

    package static func read(path: String) throws -> CalibratedImage {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        return try read(data: data, fileName: formatoDisplayFileName(path))
    }

    /// `acceptUnequalChannels` exists for one caller: tools/parity/tiff-reader-parity's negative control, which must
    /// show the unequal-channel refusal is live. It reads the red channel instead of refusing.
    package static func read(data: Data, fileName: String, acceptUnequalChannels: Bool = false) throws -> CalibratedImage {
        do {
            return CalibratedImage(try TIFFAppImage.read(data: data, fileName: fileName,
                                                         acceptUnequalChannels: acceptUnequalChannels))
        } catch let refusal as TIFFAppImage.Refusal {
            throw Refusal(refusal)
        }
    }
}
