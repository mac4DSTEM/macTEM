//
//  MRCImageReader.swift
//  Role: open one MRC2014 image (nz = 1) as macTEM's `CalibratedImage`. The reading is FormatoKit's `MRCAppImage` (FormatoMRC,
//        the first consumer's named option: the header, modes 0/1/2/6/12, the stamp's byte order, mrcfile's `voxel_size` in
//        Å, the FEI extended-header and non-positive-cell notes; pinned in the kit to this app's source and to mrcfile
//        1.5.4); this file is the seam: the app's refusal wording (`Refusal.reason`), the Cocoa error for an unreadable
//        file, and `KitImages` (the one conversion of a kit image to a `CalibratedImage`). The parity against mrcfile
//        1.5.4 is FormatoKit's. DEVIATION from RosettaSciIO 049e7d70 (nm, mode 0 unsigned, stamp ignored): mrcfile and the
//        MRC2014 standard are followed, as before the switch.
//

import Foundation
import FormatoCore
import FormatoMRC

package nonisolated enum MRCImageReader {
    package enum Refusal: Error, Equatable {
        case notMRC(String)
        case byteOrder(stamp: [UInt8])
        case stack(frames: Int)
        case mode(Int)
        case axisOrder(mapc: Int, mapr: Int, maps: Int)
        case truncated

        /// The kit's refusal (`MRCError`, thrown by FormatoMRC's metadata reader) in the words the app shows.
        package init(_ error: MRCError) {
            switch error {
            case .notMRC(let what): self = .notMRC(what)
            case .byteOrder(let stamp): self = .byteOrder(stamp: stamp)
            case .stack(let frames): self = .stack(frames: frames)
            case .mode(let mode): self = .mode(mode)
            case .axisOrder(let c, let r, let s): self = .axisOrder(mapc: c, mapr: r, maps: s)
            case .truncated: self = .truncated
            }
        }

        package var reason: String {
            switch self {
            case .notMRC(let what): "it is not an MRC image (\(what))."
            case .byteOrder(let stamp):
                "its machine stamp (\(stamp.map { String(format: "%02X", $0) }.joined(separator: " "))) names no byte order."
            case .stack(let frames): "it is a stack of \(frames) images; image stacks are not read yet."
            case .mode(let mode): "its pixel mode \(mode) is not read (modes 0, 1, 2, 6 and 12 are)."
            case .axisOrder(let c, let r, let s): "its axes are stored in the order \(c), \(r), \(s); only 1, 2, 3 is read."
            case .truncated: "the file ends before its image does."
            }
        }
    }

    package enum Note {
        package static let nonPositiveCell = MRCAppImage.Note.nonPositiveCell
        package static let feiHeader = MRCAppImage.Note.feiHeader
    }

    package static func read(path: String) throws -> CalibratedImage {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        return try read(data: data, fileName: formatoDisplayFileName(path))
    }

    package static func read(data: Data, fileName: String) throws -> CalibratedImage {
        do {
            return CalibratedImage(try MRCAppImage.read(data: data, fileName: fileName))
        } catch let error as MRCError {
            throw Refusal(error)
        }
    }
}
