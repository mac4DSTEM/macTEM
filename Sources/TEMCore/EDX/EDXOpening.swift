// Opening an EDX spectrum image: a Velox .emd with a spectrum stream or the EDS object of a GMS .dm4, through SpectroKit
// (which reads them with FormatoKit). A file that is neither is refused in words; the Image room opens the rest.
import Foundation
import SpectroCore
import ShellEDXModel

package enum EDXOpening {
    /// File extensions the Open panel offers (a Velox EMD or a GMS DM4; a single spectrum as `.msa` or HyperSpy's `.hspy`; the SEM-EDS
    /// maps and spectra of Bruker, EDAX and JEOL, `SEMEDSOpening`).
    package static let readableExtensions = ["emd", "dm4", "msa", "hspy"] + SEMEDSOpening.readableExtensions

    /// Header-only for a DM4, one HDF5 open for an EMD. Run off the main actor.
    package static func isSpectrumImage(at url: URL) -> Bool {
        SEMEDSOpening.opensInEDS(path: url.path) || SpectrumImageOpener.kind(ofFileAt: url.path) != .other
            || FileRouting.isSingleSpectrum(path: url.path)
    }

    /// Reads the whole spectrum image (a 1.7 GB Velox file is three passes over its event stream): off the main actor, cancellable
    /// through the calling task, `progress` 0...1.
    package static func open(url: URL, progress: (@Sendable (Double) -> Void)? = nil) throws -> LoadedSpectrumImage {
        if SEMEDSOpening.opensInEDS(path: url.path) {
            let loaded = try SEMEDSOpening.open(url: url)
            progress?(1)
            return loaded
        }
        let kind = SpectrumImageOpener.kind(ofFileAt: url.path)
        // A single spectrum (an `.msa`, a Velox spectrum) is a one-pixel spectrum image.
        if kind == .other, FileRouting.isSingleSpectrum(path: url.path) { return try FileRouting.spectrumFile(path: url.path) }
        return try SpectrumImageOpener.open(path: url.path, kind: kind, progress: progress)
    }
}

extension EDXRoomHost {
    /// macTEM in the shared EDS room: its names in the export files, its file routing for the room's Open button.
    package static let macTEM = EDXRoomHost(appName: "macTEM", roomSource: "macTEM EDX room", regionsTitle: "macTEM EDX pins",
                                            readableExtensions: EDXOpening.readableExtensions) { url, progress in
        try EDXOpening.open(url: url, progress: progress)
    }
}
