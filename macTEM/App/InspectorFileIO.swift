//
//  InspectorFileIO.swift
//  Role: the file reads and writes the inspectors and the EELS room ask for, kept out of `UI/`, which draws and touches no file
//        (#282): a file written into the launch's `--export-dir` without a save panel (the Particles section's objects, the
//        Diffraction room's readout and the EELS room's exports; a UI journey cannot drive the panel), through `ExportFile.write`
//        as the File menu's exports (`ExportPanels`) are, and a CIF read off the main actor inside its security scope (the
//        Diffraction and Indexing rooms' crystal). The panels themselves are SwiftUI's `fileExporter` and `fileImporter` in the
//        sections that present them, which write and grant on their own.
//

import Foundation
import DiffractoCore
import TEMCore

/// A file written into the launch's `--export-dir`, its bytes as given, through `ExportFile.write`, the writer the File menu's exports
/// (`ExportPanels`) use: the folder is made when it is not there yet, and a folder where the file goes is refused in
/// `ExportFile`'s words and left as it was.
nonisolated enum ExportDirectoryFile {
    static func write(_ data: Data, named name: String, into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try ExportFile.write(data, to: url)
        return url
    }

    /// A text file, UTF-8 as given.
    static func write(_ text: String, named name: String, into directory: URL) throws -> URL {
        try write(Data(text.utf8), named: name, into: directory)
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
