//
//  NORDIFOpening.swift
//  Role: a NORDIF acquisition at the Patterns room's door, as one `EBSDDataset`. `Pattern.dat` is the scan: the settings beside it
//        (`Setting.txt`, `NORDIFSettings`) give the grid, the step, the pattern size, the detector and the SEM header; the patterns are
//        read from the file by map position (`EBSDPatternSource.Layout.records`: no header, one uint8 record of sy x sx bytes per
//        position, in map order); `Background acquisition pattern.bmp` is the static background, and one that is there and cannot be
//        read leaves the scan without one, with a note that says why. The readers and their parity against kikuchipy 0.13.1 are
//        NORDIFSettings, NORDIFScan and NORDIFBitmap (NORDIFReaderTests); this file maps them onto the dataset.
//
//  A `.dat` is NORDIF's only when a NORDIF `Setting.txt` (first line `[NORDIF]`) sits beside it; any other `.dat` is not this door's
//  and keeps the general routing. Whole records only: a file shorter than its scan reads its complete patterns and the rest as 0,
//  with a note (kikuchipy pads an incomplete last pattern with zeros after its bytes; NORDIFScan keeps that for the parity).
//
//  A signed build is sandboxed: an Open grants the file the user picked, not the folder around it, so a `Setting.txt` beside the
//  picked `Pattern.dat` can be there and still not open. The app then asks for the folder once and keeps the grant (`FolderGrants`);
//  without it that `.dat` is refused with a sentence that names the settings file and the folder (`unreadableSettingsRefusal`,
//  FileRouting), not as a format macTEM does not know, and an open that finds the settings file so refused gives the same sentence.
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

    /// What opening the `Setting.txt` beside a `.dat` gives: 0 when it opens, else the error (the sandbox's EPERM, a file mode's
    /// EACCES, ENOENT when none is there); nil for a file that is not a `.dat`. The probe is the open a read would make, without
    /// blocking, so a denied read is told apart from a missing file without asking for the folder.
    package static func settingsOpenError(_ url: URL) -> Int32? {
        guard readableExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        let code: Int32 = settingsURL(besides: url).path.withCString { path in
            let probe = Darwin.open(path, O_RDONLY | O_NONBLOCK)
            guard probe >= 0 else { return errno }
            _ = Darwin.close(probe)
            return 0
        }
        return code
    }

    /// The refusal for a `.dat` whose `Setting.txt` is there and may not be read (the sandbox's EPERM, or a file mode's EACCES): nil
    /// for any other file, a `.dat` with no settings file beside it, or one whose settings file opens (`settingsOpenError`). An Open
    /// asks for the folder first when the sandbox refused it (the app's `FolderGrants`); this is the sentence when that is declined.
    package static func unreadableSettingsRefusal(_ url: URL) -> String? {
        guard let code = settingsOpenError(url), code == EPERM || code == EACCES else { return nil }
        let settings = settingsURL(besides: url)
        return "\(settings.lastPathComponent) beside \(url.lastPathComponent) cannot be read: macOS does not let macEM open it "
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
        let settings: NORDIFSettings
        do { settings = try NORDIFSettings.read(path: settingsFile.path) } catch {
            // The settings file beside the scan is there and may not be read (the sandbox without the folder's grant, a file mode): the
            // routing's sentence, which names the folder. Any other error goes on as it is (a refusal in `open`'s words, a Foundation
            // error with its domain and code).
            if settingsFile.path == settingsURL(besides: patternFile).path, let sentence = unreadableSettingsRefusal(patternFile) {
                throw EBSDReadError(text: sentence)
            }
            throw error
        }
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
        // One that is there and cannot be read (a bitmap NORDIFBitmap refuses, a file mode, the sandbox without the folder's grant) is
        // named in a note with why, so the scan does not read as an acquisition without one.
        let backgroundFile = patternFile.deletingLastPathComponent().appendingPathComponent("Background acquisition pattern.bmp")
        let background: NORDIFBitmap.Image?
        do {
            background = try NORDIFBitmap.read(path: backgroundFile.path)
        } catch let refusal as NORDIFBitmap.Refusal {
            background = nil
            notes.append("\(refusal.reason) The scan's mean pattern stands in for it.")
        } catch {
            background = nil
            let code = (error as NSError).code, domain = (error as NSError).domain
            let missing = (domain == NSCocoaErrorDomain && code == NSFileReadNoSuchFileError)
                || (domain == NSPOSIXErrorDomain && code == Int(ENOENT))
            if !missing {
                notes.append("\(backgroundFile.lastPathComponent) beside \(patternFile.lastPathComponent) could not be read, so the scan's mean "
                    + "pattern stands in for it: \((error as NSError).localizedDescription)")
            }
        }
        let detector = settings.detector
        return EBSDDataset(
            format: .nordif, manufacturer: "NORDIF", version: settings.softwareVersion ?? "", scanGroup: "", scanGroups: [],
            scanRows: rows, scanColumns: columns, patternRows: height, patternColumns: width, dataType: .uint8,
            stepY: settings.area.stepUM, stepX: settings.area.stepUM, scanUnit: "um",
            detector: EBSDDetectorGeometry(rows: detector.rows, columns: detector.columns, pixelSize: detector.pixelSizeUM,
                                           binning: detector.binning, tilt: detector.tiltDeg, azimuthal: detector.azimuthalDeg, twist: 0,
                                           sampleTilt: detector.sampleTiltDeg,
                                           projectionCenters: [SIMD3(detector.pcx, detector.pcy, detector.pcz)],
                                           assumed: [.projectionCenter, .pixelSize]),   // Setting.txt states neither; it states the tilt
            staticBackground: try background.map { try FormatoArray(dataType: .uint8, shape: [$0.height, $0.width], bytes: Data($0.pixels)) },
            sem: EBSDSEMHeader(beamEnergyKeV: settings.acceleratingVoltageKV, magnification: Double(settings.magnification),
                               workingDistanceMM: settings.workingDistanceMM, microscope: settings.microscope),
            crystalMap: nil,
            patterns: EBSDPatternSource(url: patternFile, layout: .records(offset: 0, recordBytes: recordBytes, patternOffset: 0),
                                        fileShape: [whole, height, width], dataType: .uint8),
            notes: notes)
    }
}
