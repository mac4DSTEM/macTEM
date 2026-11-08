//
//  NORDIFOpening.swift
//  Role: a NORDIF acquisition at the Patterns room's door, as one `EBSDDataset`. `Pattern.dat` is the scan: the settings beside it
//        (`Setting.txt`, `NORDIFSettings`) give the grid, the step, the pattern size, the detector and the SEM header; the patterns are
//        read from the file by map position (`EBSDPatternSource.Layout.records`: no header, one uint8 record of sy x sx bytes per
//        position, in map order); `Background acquisition pattern.bmp` is the static background. The readers and their parity against
//        kikuchipy 0.13.1 are NORDIFSettings, NORDIFScan and NORDIFBitmap (NORDIFReaderTests); this file maps them onto the dataset.
//
//  A `.dat` is NORDIF's only when a NORDIF `Setting.txt` (first line `[NORDIF]`) sits beside it; any other `.dat` is not this door's
//  and keeps the general routing. Whole records only: a file shorter than its scan reads its complete patterns and the rest as 0,
//  with a note (kikuchipy pads an incomplete last pattern with zeros after its bytes; NORDIFScan keeps that for the parity).
//
//  A signed build is sandboxed: an Open grants the file the user picked, not the folder around it, so a `Setting.txt` beside the
//  picked `Pattern.dat` can be there and still not open. That `.dat` is refused with a sentence that names the settings file and the
//  folder (`unreadableSettingsRefusal`, FileRouting), not as a format macTEM does not know.
//

import Darwin
import Foundation
import FormatoCore

package nonisolated enum NORDIFOpening {
    package static let readableExtensions = ["dat"]

    /// The settings file kikuchipy reads beside a pattern file.
    package static func settingsURL(besides patternFile: URL) -> URL {
        patternFile.deletingLastPathComponent().appendingPathComponent("Setting.txt")
    }

    /// True when the first line of `url` is `[NORDIF]`; reads only the first bytes.
    package static func isSettingsFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8)) ?? Data()
        return head == Data("[NORDIF]".utf8)
    }

    /// True when `url` is a NORDIF pattern file: a `.dat` with a NORDIF settings file beside it.
    package static func isNORDIFFile(_ url: URL) -> Bool {
        readableExtensions.contains(url.pathExtension.lowercased()) && isSettingsFile(settingsURL(besides: url))
    }

    /// The refusal for a `.dat` whose `Setting.txt` is there and may not be read (the sandbox's EPERM, or a file mode's EACCES): nil
    /// for any other file, a `.dat` with no settings file beside it, or one whose settings file opens. The probe is the open a read
    /// would make, without blocking, so a denied read is told apart from a missing file without asking for the folder.
    package static func unreadableSettingsRefusal(_ url: URL) -> String? {
        guard readableExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        let settings = settingsURL(besides: url)
        let code: Int32 = settings.path.withCString { path in
            let probe = Darwin.open(path, O_RDONLY | O_NONBLOCK)
            guard probe >= 0 else { return errno }
            _ = Darwin.close(probe)
            return 0
        }
        guard code == EPERM || code == EACCES else { return nil }
        return "\(settings.lastPathComponent) beside \(url.lastPathComponent) cannot be read: macOS does not let macTEM open it "
            + "(\(String(cString: strerror(code)))); a NORDIF scan needs the acquisition's folder, not \(url.lastPathComponent) alone."
    }

    /// The scan of `patternFile` as a dataset whose patterns stay in the file. Reads the settings and the background bitmap; run it off
    /// the main actor, inside the file's security scope.
    package static func open(url patternFile: URL, settingsFile: URL? = nil) throws -> EBSDDataset {
        do {
            return try dataset(patternFile: patternFile, settingsFile: settingsFile ?? settingsURL(besides: patternFile))
        } catch let refusal as NORDIFSettings.Refusal {
            throw EBSDReadError(text: "\((settingsFile ?? settingsURL(besides: patternFile)).lastPathComponent) cannot be read: \(refusal.reason)")
        } catch let refusal as NORDIFScan.Refusal {
            throw EBSDReadError(text: refusal.reason)
        }
    }

    private static func dataset(patternFile: URL, settingsFile: URL) throws -> EBSDDataset {
        let settings = try NORDIFSettings.read(path: settingsFile.path)
        let size = (try FileManager.default.attributesOfItem(atPath: patternFile.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { throw NORDIFScan.Refusal.empty(patternFile.lastPathComponent) }
        let rows = settings.area.rows, columns = settings.area.columns
        let height = settings.acquisition.resolution.height, width = settings.acquisition.resolution.width
        let recordBytes = height * width
        let expected = rows * columns * recordBytes
        let whole = min(size / recordBytes, rows * columns)
        var notes: [String] = []
        if size < expected {
            notes.append("\(patternFile.lastPathComponent) holds \(whole) of the \(rows) x \(columns) patterns of \(width) x \(height) px "
                + "the settings give; the missing ones read 0.")
        } else if size > expected {
            notes.append("\(patternFile.lastPathComponent) is \(size - expected) bytes longer than its \(rows) x \(columns) patterns of "
                + "\(width) x \(height) px from the settings; the rest is not read.")
        }
        // A missing or unreadable background is no refusal: kikuchipy warns and reads on, and the room offers the mean pattern instead.
        let background = try? NORDIFBitmap.read(path: patternFile.deletingLastPathComponent()
            .appendingPathComponent("Background acquisition pattern.bmp").path)
        let detector = settings.detector
        return EBSDDataset(
            format: .nordif, manufacturer: "NORDIF", version: settings.softwareVersion ?? "", scanGroup: "", scanGroups: [],
            scanRows: rows, scanColumns: columns, patternRows: height, patternColumns: width, dataType: .uint8,
            stepY: settings.area.stepUM, stepX: settings.area.stepUM, scanUnit: "um",
            detector: EBSDDetectorGeometry(rows: detector.rows, columns: detector.columns, pixelSize: detector.pixelSizeUM,
                                           binning: detector.binning, tilt: detector.tiltDeg, azimuthal: detector.azimuthalDeg, twist: 0,
                                           sampleTilt: detector.sampleTiltDeg,
                                           projectionCenters: [SIMD3(detector.pcx, detector.pcy, detector.pcz)]),
            staticBackground: try background.map { try FormatoArray(dataType: .uint8, shape: [$0.height, $0.width], bytes: Data($0.pixels)) },
            sem: EBSDSEMHeader(beamEnergyKeV: settings.acceleratingVoltageKV, magnification: Double(settings.magnification),
                               workingDistanceMM: settings.workingDistanceMM, microscope: settings.microscope),
            crystalMap: nil,
            patterns: EBSDPatternSource(url: patternFile, layout: .records(offset: 0, recordBytes: recordBytes, patternOffset: 0),
                                        fileShape: [whole, height, width], dataType: .uint8),
            notes: notes)
    }
}
