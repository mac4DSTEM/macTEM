//
//  InspectorFileIO.swift
//  Role: the file reads and writes two inspectors ask for, kept out of `UI/`, which draws and touches no file (#282): a CSV
//        written into the launch's `--export-dir` without a save panel (the Particles section's objects and the Diffraction room's
//        readout; a UI journey cannot drive the panel), and a CIF read off the main actor inside its security scope (the
//        Diffraction and Indexing rooms' crystal). The panels themselves are SwiftUI's `fileExporter` and `fileImporter` in the
//        sections that present them, which write and grant on their own.
//

import Foundation
import DiffractoCore

/// A text file written into the launch's `--export-dir`, UTF-8 as given; the folder is made when it is not there yet.
nonisolated enum ExportDirectoryFile {
    static func write(_ text: String, named name: String, into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
}

/// Where Export CSV writes when the launch gave `--export-dir`: "<image name> particles.csv" in that folder.
nonisolated enum ParticleExport {
    static func baseName(of imageFileName: String) -> String { (imageFileName as NSString).deletingPathExtension + " particles" }

    static func write(_ text: String, imageFileName: String, into directory: URL) throws -> URL {
        try ExportDirectoryFile.write(text, named: baseName(of: imageFileName) + ".csv", into: directory)
    }
}

/// The Diffraction readout's CSV: "<image name> diffraction", the name the save panel offers, and with `--export-dir`
/// "<image name> diffraction.csv" in that folder.
nonisolated enum DiffractionReadoutExport {
    static func baseName(of imageFileName: String) -> String { (imageFileName as NSString).deletingPathExtension + " diffraction" }

    static func write(_ text: String, imageFileName: String, into directory: URL) throws -> URL {
        try ExportDirectoryFile.write(text, named: baseName(of: imageFileName) + ".csv", into: directory)
    }
}

/// Opens a CIF off the main actor inside the file's security scope (the kit's refusals in its words, its 5 MB cap).
enum DiffractionCIF {
    @concurrent
    nonisolated static func load(_ url: URL) async throws -> LoadedCrystal {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return try CrystalLoading.load(bytes: data, fileName: url.lastPathComponent)
    }
}
