//
//  VeloxImageReader.swift
//  Role: open a Thermo Fisher Velox `.emd` as macTEM's `CalibratedImage` — one frame of one image stack — through
//        SpectroKit's Velox reader (`VeloxEMDReader`, SpectroCore 0.1.0, its public API only: one Velox parser for both
//        apps). The parity against RosettaSciIO 049e7d70 and h5py is the kits'.
//
//  OBJECT RULE AND AXES are FormatoKit's `VeloxImageSelection` (FormatoEMD, the first consumer's named option beside
//  `VeloxImageSignals`, pinned in the kit to this app's source) and `VeloxImageInfo.resolvedDetector` / `.detectorType`;
//  this file keeps the frame read, the refusal wording, the "frame 1 of N" note, `describe`, and the build of the
//  `CalibratedImage` (the kit has no image type for Velox). The rule, as registered (inert on every gated file): a candidate is an entry of
//  `images()` whose `BinaryResult.DetectorIndex` resolves in the file's detector table — to the entry the image's own
//  `BinaryResult.Detector` names when the indexed one is another (`resolvedDetector`) — to a detector whose type is
//  not "AnalyticalDetector" (an EDX map), and whose stored type a
//  float read can take (not Velox's compound FFT and DPC images). The first candidate whose detector is named "HAADF"
//  opens, else the first in the file's key order; with none the file is refused, naming what it holds. Measured before
//  code: this separates all 27 public image stacks and the owner's three Ceta files (a name test would open the
//  `UltraX` and `Zebra` EDX maps of `example_velox_EELS_EDS`, which carry no DetectorIndex).
//
//  THE FRAME: frame 0 of the stack (`read(path:frame:)` is V1-3c-ii's seam), never a sum: an unaligned sum smears (the
//  measured residual shift reaches (2, −5) px over 212 frames). A stack says "frame 1 of N" in `notes`.
//
//  CALIBRATION, as stored: x from `PixelSize.width` in `PixelUnitX`, y from `PixelSize.height` in `PixelUnitY`, the
//  unit strings unnormalised ("m"; the display shows metres as nm); origin = −Offset/PixelSize per axis (no Offset: 0);
//  an absent, non-finite or non-positive size leaves that axis uncalibrated (nil); the voltage is the stored
//  acceleration voltage. DEVIATION: the y unit comes from `PixelUnitY` only; RosettaSciIO 049e7d70 uses `PixelUnitX` for
//  both (inert on the 40 files compared, where the two agree). A y axis whose file names no y unit is uncalibrated.
//  SpectroKit reads every stored integer and float type as Float32: int32, uint32, the 64-bit types and float64 are
//  rounded, and `notes` says so.
//

import ImagoCore
import Foundation
import FormatoCore
import FormatoEMD

package nonisolated enum VeloxImageReader {
    package enum Refusal: Error, Equatable {
        /// The file is HDF5 but not Velox (`.emd` is also Berkeley EMD), or not HDF5 at all.
        case notVelox(String)
        /// The bundled HDF5 library could not be loaded.
        case library(String)
        /// No entry the object rule opens; what the file holds instead.
        case noImage(String)
        /// SpectroKit refused the read (a damaged file, more pixels than it accepts).
        case unreadable(String)

        package var reason: String {
            switch self {
            case .notVelox(let what): what.isEmpty ? "it is not a Velox EMD file." : "it is not a Velox EMD file (\(what))."
            case .library(let detail): "the bundled HDF5 library could not be loaded (\(detail))."
            case .noImage(let holds): "it holds no image macTEM opens (\(holds))."
            case .unreadable(let detail): "it could not be read (\(detail))."
            }
        }
    }

    /// Reads frame `frame` of the entry the object rule picks, synchronously (one HDF5 hyperslab: a frame, never the
    /// stack). The app calls it through `ImageOpening.openNow`, off the main actor.
    package static func read(path: String, frame: Int = 0) throws -> CalibratedImage {
        let reader = VeloxEMDReader(path: path)
        let entries = try listing(reader)
        guard let entry = VeloxImageSelection.choose(entries) else { throw Refusal.noImage(describe(entries)) }
        let pixels: [Float]
        do {
            pixels = try reader.readImageFrame(id: entry.id, frame: frame)
        } catch let error as VeloxEMDError {
            throw refusal(error)
        } catch let cancelled as FormatoCancelled {
            throw cancelled
        } catch {
            throw Refusal.unreadable(error.localizedDescription)
        }
        return image(entry, pixels: pixels, frame: frame, fileName: formatoDisplayFileName(path))
    }

    /// The entry `read` opens, or nil (the open refuses the file). The metadata read calls it too, so the
    /// acquisition described is the image shown (`AcquisitionMetadata.read(path:)`).
    package static func openedEntry(path: String) -> VeloxImageInfo? {
        (try? listing(VeloxEMDReader(path: path))).flatMap(VeloxImageSelection.choose)
    }

    /// The image of frame `frame` of `entry`, with its calibration, as stored.
    static func image(_ entry: VeloxImageInfo, pixels: [Float], frame: Int, fileName: String) -> CalibratedImage {
        let m = entry.metadata
        let axes = VeloxImageSelection.axes(of: entry)
        let x = axes.x.map(AxisCalibration.init), y = axes.y.map(AxisCalibration.init)
        var notes: [String] = []
        if entry.frameCount > 1 { notes.append("frame \(frame + 1) of \(entry.frameCount)") }
        if let type = entry.elementType, roundedToFloat32.contains(type) {
            notes.append("stored as \(type.rawValue), rounded to Float32")
        }
        let name = entry.detectorName.isEmpty ? "" : " · \(entry.detectorName)"
        return CalibratedImage(width: entry.width, height: entry.height, pixels: pixels, x: x, y: y,
                               fileName: fileName, source: "Data/Image/\(entry.id)\(name)",
                               voltage: m.accelerationVoltageVolts, notes: notes)
    }

    /// The stored types SpectroKit cannot hold exactly in a Float32.
    static let roundedToFloat32: Set<VeloxImageElementType> = [.int32, .uint32, .int64, .uint64, .float64]

    /// "2 × EDX map (SuperXG21, SuperXG22); compound FFT 128 × 128" — what a refused file holds, for the message.
    static func describe(_ entries: [VeloxImageInfo]) -> String {
        guard !entries.isEmpty else { return "no image stacks" }
        return entries.map { e in
            let name = e.detectorName.isEmpty ? "unnamed" : e.detectorName
            let dims = "\(e.width) × \(e.height)" + (e.frameCount > 1 ? " × \(e.frameCount)" : "")
            if e.elementType == nil { return "\(name) \(dims), a compound type" }
            if let index = e.metadata.binaryResultDetectorIndex,
               e.metadata.detectors.first(where: { $0.index == index })?.type == VeloxImageSelection.analyticalDetectorType {
                return "\(name) \(dims), an EDS map"
            }
            if e.metadata.binaryResultDetectorIndex == nil { return "\(name) \(dims), no detector index" }
            return "\(name) \(dims), detector not in the file's table"
        }.joined(separator: "; ")
    }

    private static func listing(_ reader: VeloxEMDReader) throws -> [VeloxImageInfo] {
        do {
            return try reader.images()
        } catch let error as VeloxEMDError {
            throw refusal(error)
        } catch let cancelled as FormatoCancelled {
            throw cancelled
        } catch {
            // A damaged `Metadata` column: FormatoKit's JSON parse throws a Foundation error (the test fixture
            // velox-bad-metadata.emd), which must reach the user as a named refusal, not a raw Cocoa error.
            throw Refusal.unreadable(error.localizedDescription)
        }
    }

    private static func refusal(_ error: VeloxEMDError) -> Refusal {
        let detail = error.errorDescription ?? "\(error)"
        switch error {
        case .libraryUnavailable: return .library(detail)
        // SpectroKit's own sentence already says "… is not a Velox EMD file": no detail to repeat.
        case .notVeloxFile, .notVelox: return .notVelox("")
        case .cannotOpen: return .notVelox(detail)
        default: return .unreadable(detail)
        }
    }
}
