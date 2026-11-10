//
//  SEMEDSOpening.swift
//  Role: the SEM-EDS map files at the app's door. A Bruker `.bcf`, an EDAX `.spd`/`.lsd`, a JEOL `.pts` (or the `.asw` project that
//        names one) opens in the EDS room as its spectrum image, with the SE/BSE/HAADF image recorded on the same grid as the room's
//        scan image; a Bruker `.spx`, an EDAX `.spc` or a JEOL `.eds` opens there as a one-pixel spectrum image; a JEOL `.img`/`.map`
//        opens in the Image room. The readers are `BrukerEDSReader`, `EDAXEDSReader` and `JEOLEDSReader` (RosettaSciIO 0.15.0 ports);
//        this file only hands their values over: energies to the room in keV and eV, the pixel size, beam energy, detector angles
//        and times as the file states them. A file whose energy axis is not calibrated (an EDAX map without its `.spc`) is refused
//        in a sentence: the room's lines and quantification need keV.
//

import Foundation
import ImagoCore
import SpectroCore

package nonisolated enum SEMEDSOpening {
    /// Files that open in the EDS room as a spectrum image.
    package static let spectrumImageExtensions = ["bcf", "spd", "lsd", "pts", "asw"]
    /// Files that open in the EDS room as one spectrum.
    package static let spectrumExtensions = ["spx", "spc", "eds"]
    /// Files that open in the Image room.
    package static let imageExtensions = ["img", "map"]
    /// Everything the EDS room's Open offers from here.
    package static let readableExtensions = spectrumImageExtensions + spectrumExtensions

    static func ext(_ path: String) -> String { (path as NSString).pathExtension.lowercased() }

    package static func opensInEDS(path: String) -> Bool { readableExtensions.contains(ext(path)) }
    package static func isSingleSpectrumFile(path: String) -> Bool { spectrumExtensions.contains(ext(path)) }
    package static func isImageFile(path: String) -> Bool { imageExtensions.contains(ext(path)) }

    /// The file read by its vendor's reader. Whole-file work: run it off the main actor. A JEOL `.pts` (or the `.asw` naming it)
    /// reports `progress` 0...1 after each sweep of its event stream and stops with `CancellationError` when the calling task is
    /// cancelled; the Bruker and EDAX readers report nothing.
    package static func read(url: URL, progress: (@Sendable (Double) -> Void)? = nil) throws -> SEMEDSFile {
        switch url.pathExtension.lowercased() {
        case let e where BrukerEDSReader.readableExtensions.contains(e): return try BrukerEDSReader.read(url: url)
        case let e where EDAXEDSReader.readableExtensions.contains(e): return try EDAXEDSReader.read(url: url)
        case let e where JEOLEDSReader.readableExtensions.contains(e): return try JEOLEDSReader.read(url: url, progress: progress)
        default: throw SEMEDSReadError("\(url.lastPathComponent) is not a Bruker, EDAX or JEOL EDS file.")
        }
    }

    /// The file as the EDS room's spectrum image: its first spectrum image, else its first spectrum as one pixel. `progress` and
    /// cancellation as `read(url:progress:)`.
    package static func open(url: URL, progress: (@Sendable (Double) -> Void)? = nil) throws -> LoadedSpectrumImage {
        let file = try read(url: url, progress: progress)
        let name = url.lastPathComponent
        if let si = file.spectrumImages.first {
            let e = si.energyAxis
            guard e.units == "keV", e.scale > 0 else {
                throw SEMEDSReadError("\(name) has no energy calibration (an EDAX map reads it from the .spc of the same name beside it).")
            }
            var meta = SpectrumImageMetadata(fileName: name, filePath: url.path, scanWidth: si.cube.nx, scanHeight: si.cube.ny,
                                             channelCount: si.cube.channels, energyOffsetEV: e.offset * 1000, energyDispersionEV: e.scale * 1000)
            let x = si.axes.count >= 3 ? si.axes[1] : si.axes[0]
            if let unit = x.units, x.scale > 0 { meta.scanPixelSize = x.scale; meta.scanPixelUnit = unit }
            fill(&meta, si.metadata, vendor: vendor(url))
            // The image recorded on the scan grid (an SE, BSE or HAADF image; a JEOL S(T)EM image).
            let scan = file.images.first { $0.width == si.cube.nx && $0.height == si.cube.ny }?.pixels.map(Float.init)
            return LoadedSpectrumImage(image: si.cube, metadata: meta, energyAxis: EnergyAxis(offset: e.offset, scale: e.scale, size: e.size),
                                       scanImage: scan)
        }
        guard let spectrum = file.spectra.first else {
            throw SEMEDSReadError("\(name) holds no spectrum or spectrum image.")
        }
        let a = spectrum.axis
        guard a.units == "keV", a.scale > 0 else { throw SEMEDSReadError("\(name) has no energy calibration.") }
        guard spectrum.counts.allSatisfy({ $0 >= 0 && $0 <= Int64(UInt32.max) }) else {
            throw SEMEDSReadError("\(name) holds negative counts: it is not a count spectrum.")
        }
        var meta = SpectrumImageMetadata(fileName: name, filePath: url.path, scanWidth: 1, scanHeight: 1, channelCount: spectrum.counts.count,
                                         energyOffsetEV: a.offset * 1000, energyDispersionEV: a.scale * 1000)
        fill(&meta, spectrum.metadata, vendor: vendor(url))
        return LoadedSpectrumImage(image: DenseSpectrumImage(ny: 1, nx: 1, channels: spectrum.counts.count,
                                                             counts: spectrum.counts.map { UInt32($0) }),
                                   metadata: meta, energyAxis: EnergyAxis(offset: a.offset, scale: a.scale, size: a.size))
    }

    static func vendor(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "bcf", "spx": "Bruker Esprit"
        case "spd", "lsd", "spc": "EDAX"
        default: "JEOL Analysis Station"
        }
    }

    static func fill(_ meta: inout SpectrumImageMetadata, _ md: SEMEDSMetadata, vendor: String) {
        meta.beamEnergyKeV = md.beamEnergy.flatMap { $0 > 0 ? $0 : nil }
        meta.instrument = vendor + (md.mode.map { " (\($0))" } ?? "")
        meta.alphaTiltDegrees = md.tiltAlpha
        if md.detectorType != nil || md.elevationAngle != nil || md.liveTime != nil || md.realTime != nil {
            meta.detectors = [SpectrumDetectorSegment(name: md.detectorType ?? "EDS", azimuthDegrees: md.azimuthAngle,
                                                      elevationDegrees: md.elevationAngle, liveTime: md.liveTime, realTime: md.realTime)]
        }
    }

    /// A JEOL image or element map as the Image room's image (µm per pixel as the file states it).
    package static func image(url: URL) throws -> CalibratedImage {
        guard case .image(let img)? = try JEOLEDSReader.signals(url: url).first else {
            throw SEMEDSReadError("\(url.lastPathComponent) holds no image.")
        }
        let x = img.axes[1], y = img.axes[0]
        return CalibratedImage(width: img.width, height: img.height, pixels: img.pixels.map(Float.init),
                               x: x.units.map { AxisCalibration(scale: x.scale, unit: $0) },
                               y: y.units.map { AxisCalibration(scale: y.scale, unit: $0) },
                               fileName: url.lastPathComponent, source: "JEOL · " + (img.metadata.title ?? "image"),
                               voltage: img.metadata.beamEnergy.map { $0 * 1000 })
    }
}
