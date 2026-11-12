//
//  HyperSpySpectrumFile.swift
//  Role: open one spectrum saved in HyperSpy's own HDF5 layout (`.hspy`: `Experiments/<title>/data`, the axes as `axis-<i>` groups whose
//        attributes are offset, scale, size and units, the metadata tree as groups whose attributes are the values) through FormatoKit's
//        HDF5 layer, for the EDS room's one-pixel spectrum image. Counts, axis, beam energy, the elements and the EDS conditions (detector
//        resolution, elevation, azimuth, stage tilt, live time) are read exact: no numerics.
//        A file of several experiments, a signal with a navigation axis or a non-1D dataset is refused in words (spectrum images in this
//        layout are a later port). FormatoKit's sniff knows no `.hspy`, so this file checks the extension and the HDF5 signature itself.
//        Reference layout: RosettaSciIO 0.15.0, `rsciio/hspy/_api.py` (GPL-3.0-or-later); the first file read is exspy's `EDS_SEM_TM002`,
//        shipped as demo data (NOTICE).
//

import Foundation
import FormatoCore
import FormatoHDF5

package nonisolated enum HyperSpySpectrumFile {
    /// One spectrum as the file states it: counts per channel, the energy axis E(i) = offset + i · scale in `units`, and what the
    /// metadata tree says about how it was taken.
    package struct Spectrum: Equatable, Sendable {
        package var title: String
        package var signalType: String
        package var counts: [Double]
        package var offset: Double
        package var scale: Double
        package var units: String
        package var beamEnergyKeV: Double?
        package var microscope: String?
        /// `metadata/Sample/_list_elements`, as written (symbols); empty when the file names none.
        package var elements: [String]
        /// The detector and stage as `Acquisition_instrument.SEM` (else `.TEM`) states them: energy resolution at Mn Kα, elevation and
        /// azimuth, stage tilts, live and real time; what the file leaves out takes exspy's defaults (`SEMEDSLines.Conditions`).
        package var conditions: SEMEDSLines.Conditions
        /// Whether the acquisition is an SEM's (`Acquisition_instrument/SEM`, or the signal type `EDS_SEM`).
        package var isSEM: Bool
    }

    /// The experiment group and its axis, found without reading the counts: what the Open route needs to say where the file goes.
    package struct Header: Equatable, Sendable {
        package var experiment: String
        package var title: String
        package var channels: Int
        package var offset: Double
        package var scale: Double
        package var units: String
    }

    package struct Refusal: Error, LocalizedError, Equatable {
        package var text: String
        package var errorDescription: String? { text }
    }

    private static let hdf5Signature: [UInt8] = [0x89, 0x48, 0x44, 0x46, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Whether `path` is an `.hspy` file by extension and by HDF5 signature (eight bytes read; no HDF5 open).
    package static func isHyperSpyFile(path: String) -> Bool {
        guard URL(fileURLWithPath: path).pathExtension.lowercased() == "hspy", let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: hdf5Signature.count)) ?? Data()
        return [UInt8](head).starts(with: hdf5Signature)
    }

    /// The one experiment of the file and its energy axis, or the refusal that says why the file is not one spectrum. One HDF5 open:
    /// run it off the main actor.
    package static func header(path: String) throws -> Header {
        let name = (path as NSString).lastPathComponent
        let reader: HDF5Reader
        do { reader = try HDF5Reader(url: URL(fileURLWithPath: path)) } catch {
            throw Refusal(text: "\(name) could not be opened as an HDF5 file (\(error)).")
        }
        guard (try? reader.exists("/Experiments")) == true, let experiments = try? reader.children(of: "/Experiments"), !experiments.isEmpty else {
            throw Refusal(text: "\(name) holds no Experiments group: it is not a HyperSpy file.")
        }
        guard experiments.count == 1, let first = experiments.first else {
            throw Refusal(text: "\(name) holds \(experiments.count) experiments: macEM opens a HyperSpy file of one spectrum.")
        }
        let experiment = "/Experiments/\(first)"
        let axes = ((try? reader.children(of: experiment)) ?? []).filter { $0.hasPrefix("axis-") }.sorted()
        guard let info = try? reader.datasetInfo(experiment + "/data"), case .numeric = info.type else {
            throw Refusal(text: "\(name) has no numeric data: macEM opens single spectra from HyperSpy files.")
        }
        guard axes.count == 1, info.shape.count == 1, let channels = info.shape.first, channels > 0 else {
            throw Refusal(text: "\(name) holds \(dimensionWords(info.shape.count)), not one spectrum: macEM opens single spectra from HyperSpy files.")
        }
        let axis = experiment + "/" + axes[0]
        guard let offset = number(reader, "offset", of: axis), let scale = number(reader, "scale", of: axis), scale > 0 else {
            throw Refusal(text: "\(name) has no calibrated energy axis.")
        }
        // An untitled signal's group is HyperSpy's "__unnamed__", which is no name to show: the file's stem stands in.
        let stored = text(reader, "title", of: experiment + "/metadata/General").flatMap { $0.isEmpty ? nil : $0 }
        let title = stored ?? (first == "__unnamed__" ? (name as NSString).deletingPathExtension : first)
        return Header(experiment: experiment, title: title, channels: channels, offset: offset, scale: scale, units: text(reader, "units", of: axis) ?? "")
    }

    /// "a 4-dimensional signal": what a HyperSpy file holds, in words. The experiment's group name is HyperSpy's own (a signal
    /// without a title is "__unnamed__"), so the refusals name the file instead.
    static func dimensionWords(_ count: Int) -> String {
        switch count {
        case 0: "a single value"
        case 1: "a 1-dimensional signal whose axes do not match its data"
        case 2: "a 2-dimensional signal (an image or a line scan)"
        case 3: "a 3-dimensional signal (a spectrum image or an image stack)"
        case 4: "a 4-dimensional signal (a 4D-STEM or EBSD dataset)"
        default: "a \(count)-dimensional signal"
        }
    }

    /// The spectrum: `header` and the counts, with the beam energy (the SEM's, else the TEM's), the microscope and the elements the
    /// file names. Off the main actor.
    package static func read(path: String) throws -> Spectrum {
        let header = try header(path: path)
        let reader = try HDF5Reader(url: URL(fileURLWithPath: path))
        let counts = try reader.readDataset(header.experiment + "/data").doubles()
        let metadata = header.experiment + "/metadata"
        let sem = metadata + "/Acquisition_instrument/SEM", tem = metadata + "/Acquisition_instrument/TEM"
        let beam = number(reader, "beam_energy", of: sem) ?? number(reader, "beam_energy", of: tem)
        let microscope = text(reader, "microscope", of: sem) ?? text(reader, "microscope", of: tem)
        let elementsPath = metadata + "/Sample/_list_elements"
        let elements = (try? reader.exists(elementsPath)) == true ? ((try? reader.readStrings(elementsPath)) ?? []) : []
        let signalType = text(reader, "signal_type", of: metadata + "/Signal") ?? ""
        let isSEM = signalType == "EDS_SEM" || (try? reader.exists(sem)) == true
        let instrument = isSEM ? sem : tem
        let detector = instrument + "/Detector/EDS", stage = instrument + "/Stage"
        let positiveBeam = beam.flatMap { $0 > 0 ? $0 : nil }
        let conditions = SEMEDSLines.Conditions(
            beamEnergyKeV: positiveBeam, energyResolutionMnKaEV: number(reader, "energy_resolution_MnKa", of: detector),
            elevationAngleDeg: number(reader, "elevation_angle", of: detector), azimuthAngleDeg: number(reader, "azimuth_angle", of: detector),
            tiltAlphaDeg: number(reader, "tilt_alpha", of: stage), tiltBetaDeg: number(reader, "tilt_beta", of: stage),
            liveTimeS: number(reader, "live_time", of: detector), realTimeS: number(reader, "real_time", of: detector))
        return Spectrum(title: header.title, signalType: signalType, counts: counts,
                        offset: header.offset, scale: header.scale, units: header.units,
                        beamEnergyKeV: positiveBeam, microscope: microscope, elements: elements,
                        conditions: conditions, isSEM: isSEM)
    }

    /// A numeric attribute of a group that may not exist (HyperSpy writes a scalar as one value; a one-element array counts too).
    private static func number(_ reader: HDF5Reader, _ name: String, of path: String) -> Double? {
        guard (try? reader.exists(path)) == true, let value = try? reader.attribute(name, of: path) else { return nil }
        switch value {
        case .real(let v): return v
        case .integer(let v): return Double(v)
        case .reals(let v): return v.first
        case .integers(let v): return v.first.map(Double.init)
        case .text, .texts: return nil
        }
    }

    /// A text attribute of a group that may not exist.
    private static func text(_ reader: HDF5Reader, _ name: String, of path: String) -> String? {
        guard (try? reader.exists(path)) == true, let value = try? reader.attribute(name, of: path) else { return nil }
        switch value {
        case .text(let s): return s
        case .texts(let s): return s.first
        case .real, .reals, .integer, .integers: return nil
        }
    }
}
