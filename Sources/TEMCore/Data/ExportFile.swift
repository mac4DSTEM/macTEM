//
//  ExportFile.swift
//  Role: what every export names about its source (`ExportSource`), the failures an export can end in
//        (`ExportFile.Failure`, each with the sentence the alert shows) and the one way an export's bytes reach the file
//        the save panel chose (`ExportFile.write`). V1-10 slice 1 (archive: roadmap-registrations-2026-10-15.md "Completed at pickup — slice 1";
//        archive: export-design-2026-10-13.md). The PNG is `ImageExport`, the CSV is `ProfileCSV`; neither touches
//        the disk itself.
//
//  THE WRITE is sandbox-safe on purpose: a save panel in a sandboxed app grants the CHOSEN FILE, not its folder, so an
//  atomic write (Data.write(options: .atomic), which stages a sibling temporary file) can be refused — mac4DSTEM's HDF5
//  export failed this way in its release (2026-08-05). The bytes go to a scratch file in the destination's
//  item-replacement directory (the system's staging place for exactly this, the way a document save works), then over
//  the chosen URL: `replaceItemAt` when a file is there, `moveItem` when not. The scratch directory is removed on every
//  path. Where the scratch is: on the boot volume the user's TemporaryItems, so nothing is left beside the destination; on
//  another volume the system's `.TemporaryItems` at that volume's root, which stays there (FAT also gets `._name` sidecars
//  for the extended attributes). What an overwrite does (measured by Gate B round 2, 2026-10-13): the file is swapped, so
//  it is a new inode (a hard link to the old file is broken) and its mode may change (640 became 600); it keeps its birth
//  date and its extended attributes. A destination that is a folder is refused (`replaceItemAt` would swap the folder
//  for the file and delete everything in it).
//

import Foundation
import ImagoCore

/// What every export names about its source: the file, the object, the size and the calibration EXACTLY as the file
/// states it (never the display-converted axes: a Velox pixel in metres is recorded in metres, and the line that says what
/// the app shows it in is separate), the reader's notes verbatim, and the software that wrote the export. ImagoKit's
/// `TidyResultsCSV.Source`, which every kit CSV writer takes.
package typealias ExportSource = TidyResultsCSV.Source

extension TidyResultsCSV.Source {
    /// `software`: "macTEM 0.1.0 (1)", passed in by the app (TEMCore does not know the bundle).
    package nonisolated init(image: CalibratedImage, software: String) {
        self.init(software: software, fileName: image.fileName, object: image.source, width: image.width, height: image.height,
                  x: image.x, y: image.y, notes: image.notes)
    }
}

package nonisolated enum ExportFile {
    package enum Failure: Error, Equatable, LocalizedError {
        /// A side above `ImageExport.maximumSide`.
        case tooLarge(width: Int, height: Int)
        /// A profile with no samples.
        case noSamples
        /// An FFT export of the spot list with no measured spot.
        case noSpots
        /// A Results export of a file with no finished measurement.
        case noResults
        /// ImageIO refused to encode the image.
        case encodeFailed
        /// The system's reason the file could not be written.
        case writeFailed(String)

        package var errorDescription: String? {
            switch self {
            case .tooLarge(let width, let height):
                return "The image is \(width) × \(height) px; export takes at most \(ImageExport.maximumSide) px a side."
            case .noSamples:
                return "The profile has no samples, so there is nothing to export."
            case .noSpots:
                return "No spot has been measured on this transform, so there is nothing to export."
            case .noResults:
                return "This file has no results yet, so there is nothing to export."
            case .encodeFailed:
                return "The image could not be encoded as a PNG."
            case .writeFailed(let reason):
                return reason.isEmpty ? "The file could not be written." : "The file could not be written. \(reason)"
            }
        }
    }

    /// Writes `data` to `url`: into a scratch file in `url`'s item-replacement directory first, then over `url`
    /// (`replaceItemAt` when a file is there, `moveItem` otherwise); the scratch directory is removed after, on every
    /// path. Never an atomic write next to `url`. A folder at `url` is refused and left as it was. Throws
    /// `Failure.writeFailed` with the system's reason.
    package static func write(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        var isFolder: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
            throw Failure.writeFailed("\u{201C}\(url.lastPathComponent)\u{201D} is a folder.")
        }
        do {
            let directory = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                appropriateFor: url, create: true)
            defer { try? fileManager.removeItem(at: directory) }
            let name = url.lastPathComponent.isEmpty ? "export" : url.lastPathComponent
            let scratch = directory.appendingPathComponent(name)
            try data.write(to: scratch)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: scratch)
            } else {
                try fileManager.moveItem(at: scratch, to: url)
            }
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }
}
