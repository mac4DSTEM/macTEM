//
//  EBSDOpening.swift
//  Role: what the Patterns room opens: the file extensions the Open panel offers, a drop takes and the app declares, and one call that
//        reads a dataset with its pattern reader. The h5ebsd family is `EBSDH5Reader`'s; the vendors' binary pattern files go through
//        their doors (`EDAXOpening` for `.up1`/`.up2` with the `.ang` beside them, `OxfordOpening` for `.ebsp` with the `.ctf`, `NORDIFOpening` for `Pattern.dat` with its `Setting.txt`), which pair the
//        map next to the patterns by name. A map file opened on its own opens the patterns of the same name next to it, or is refused.
//

import Foundation

package nonisolated enum EBSDOpening {
    /// Every extension an h5ebsd file comes with: kikuchipy and Bruker write `.h5`, EDAX `.h5` or `.hdf5`, Oxford `.h5oina`; `.h5ebsd` is
    /// the name of the layout and is seen in the wild.
    package static let h5Extensions = ["h5", "hdf5", "h5oina", "h5ebsd"]
    /// The vendors' binary pattern files and the maps written next to them.
    package static let vendorExtensions = OxfordOpening.readableExtensions + EDAXOpening.readableExtensions + NORDIFOpening.readableExtensions
    package static let readableExtensions = h5Extensions + vendorExtensions

    /// Whether `url` is a vendor file rather than an HDF5 one: by extension, except a `.dat`, which is NORDIF's only with a NORDIF
    /// `Setting.txt` beside it (any other `.dat` keeps the general routing and its refusal).
    package static func isVendorFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if NORDIFOpening.readableExtensions.contains(ext) { return NORDIFOpening.isNORDIFFile(url) }
        return vendorExtensions.contains(ext)
    }

    /// What a vendor file at `url` is, from its header alone (the pattern file's first bytes; for a map file, whether its patterns are next
    /// to it): nil when the Patterns room opens it, else the sentence that says why not. The whole `.ang`/`.ctf` is read at the open, not here.
    package static func vendorRefusal(url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        do {
            if OxfordOpening.readableExtensions.contains(ext) {
                let patterns = try OxfordOpening.patternFile(for: url)
                do { _ = try OxfordBinaryReader.patternCountInHeader(data: try Data(contentsOf: patterns, options: .alwaysMapped)) }
                catch let refusal as OxfordBinaryReader.Refusal { return "\(patterns.lastPathComponent): \(refusal.reason)" }
            } else if EDAXOpening.readableExtensions.contains(ext) {
                let patterns = try EDAXOpening.patternFile(for: url)
                let header = try EDAXBinaryReader.read(url: patterns)
                if header.isHexagonal { return "\(patterns.lastPathComponent) was acquired on a hexagonal grid; only square-grid EBSD maps are read." }
            } else if NORDIFOpening.readableExtensions.contains(ext) {
                _ = try NORDIFSettings.read(path: NORDIFOpening.settingsURL(besides: url).path)
            } else {
                return "\(url.lastPathComponent) is not an EBSD pattern file."
            }
        } catch let refusal as NORDIFSettings.Refusal {
            return "\(NORDIFOpening.settingsURL(besides: url).lastPathComponent) cannot be read: \(refusal.reason)"
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "\(url.lastPathComponent): \((error as NSError).localizedDescription)"
        }
        return nil
    }

    /// The first scan of the file at `url` and the reader for its patterns. Opens the file twice (the header, then the dataset handle it keeps):
    /// run it off the main actor, inside the file's security scope.
    package static func open(url: URL) throws -> (dataset: EBSDDataset, reader: EBSDPatternReader) {
        let ext = url.pathExtension.lowercased()
        let dataset: EBSDDataset
        if OxfordOpening.readableExtensions.contains(ext) { dataset = try OxfordOpening.open(url: url) }
        else if EDAXOpening.readableExtensions.contains(ext) { dataset = try EDAXOpening.open(url: url) }
        else if NORDIFOpening.readableExtensions.contains(ext) { dataset = try NORDIFOpening.open(url: url) }
        else { dataset = try EBSDH5Reader.read(url: url) }
        return (dataset, try EBSDPatternReader(dataset))
    }
}
