//
//  AcquisitionMetadata+Read.swift
//  Role: the one entry point that describes a FILE: `AcquisitionMetadata.read(path:)` picks the format reader by the
//        extension, as `ImageOpening.openNow` picks the image reader, and returns what the file records. The three
//        format readers are FormatoKit's (`tiff(data:)`, `mrc(data:)`, `dm(numbers:strings:)`, `velox(_:)`); this file only
//        reaches them from a path. Checked by tools/parity/metadata-parity (C1–C5) and
//        AcquisitionMetadataReadTests.
//
//  The readers are FormatoKit's (`AcquisitionMetadata` and the DM/MRC/TIFF/Velox extensions of FormatoCore, FormatoDM,
//  FormatoMRC, FormatoTIFF, FormatoEMD), always with `convention: .app`: this app's rule set (a to g), pinned in the kit.
//  The `MetadataReading`/`AcquisitionMetadata` types and the rules are the kit's; this file is the dispatch only.
//
//  NEVER THROWS. The open has already succeeded when the app asks (`AppState.read` calls both inside one security
//  scope), so a container that cannot be read for its metadata — a corrupt tag tree, a header the metadata reader
//  refuses, a vanished file — reads as EMPTY ("not recorded"), never as an error shown over an image that opened. An
//  unknown extension reads empty too.
//
//  DM (.dm3, .dm4): `DM4Experiment.list(path:)`, then `ImageOpening.primaryImageObject(in:)` — the open's own object
//  rule, the same function `openNow` calls, so the object described is the object shown and the two cannot drift —
//  then the DM rules over that object's `imageTagNumbers` and `imageTagStrings` (keys relative to
//  `ImageList.N.ImageTags.`). A file with no such object (one the open refuses) reads empty.
//  Velox (.emd): `velox(_:)` on the entry `VeloxImageReader.openedEntry(path:)` names — the open's own rule.
//  TIFF (.tif, .tiff): the kit's `tiff(data:)` on the file mapped, as the image reader maps it (the Velox XML, the FEI SEM INI,
//  or a DM-saved TIFF's tag 65027). MRC (.mrc): the kit's `mrc(data:)`, the FEI1/FEI2 extended header.
//
//  Not a field of `CalibratedImage`: that type has about twenty construction sites, and the pixel readers must not
//  depend on the metadata readers. The result travels beside the image (`ImageSession.finishOpen`).
//

import Foundation
import FormatoCore
import FormatoDM
import FormatoEMD
import FormatoMRC
import FormatoTIFF

nonisolated extension AcquisitionMetadata {
    /// What the file at `path` records about how its image was acquired; every field nil ("not recorded") when it
    /// records nothing or cannot be read. Synchronous, reads only headers and tag trees (a TIFF and an MRC file are
    /// mapped, not read whole), so the app calls it beside the open, off the main actor.
    package static func read(path: String) -> AcquisitionMetadata {
        switch (path as NSString).pathExtension.lowercased() {
        case "dm3", "dm4":
            guard let objects = try? DM4Experiment.list(path: path),
                  let shown = ImageOpening.primaryImageObject(in: objects) else { return AcquisitionMetadata() }
            return dm(numbers: shown.imageTagNumbers, strings: shown.imageTagStrings, convention: .app)
        case "tif", "tiff":
            return (try? tiff(data: mapped(path), convention: .app)) ?? AcquisitionMetadata()
        case "mrc":
            return (try? mrc(data: mapped(path), convention: .app)) ?? AcquisitionMetadata()
        case "emd":
            // The open's own object rule, so the acquisition described is the image shown.
            guard let entry = VeloxImageReader.openedEntry(path: path) else { return AcquisitionMetadata() }
            return velox(entry)   // `.rosettaSciIO`: magnification, camera length, exposure and mode are read, not "not read from .emd files yet"
        default:
            return AcquisitionMetadata()
        }
    }

    /// The file's bytes, mapped as `TIFFImageReader.read(path:)` and `MRCImageReader.read(path:)` map them.
    private static func mapped(_ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
    }
}
