//
//  ImageOpening.swift
//  Role: open a file as macTEM's `CalibratedImage`. The one entry point the app calls; it picks the reader by
//        extension and, in a file that holds several objects, the object to show by the rule below.
//
//  OBJECT RULE (pre-registered): the first object in the file's own order that
//  is not the thumbnail nor an EELS object (the EELS room's), has no axis in eV or keV, has exactly two dimensions larger than one, whose two axes do not carry two different
//  units, and whose `Meta Data.Format` is not "Spectrum image". A GMS file stores its RGBA thumbnail first; a
//  [170, 1] line scan or a [w, h, n] stack is not an image; a 2D object whose axes are in different units
//  (wavelength nm × position µm, energy × position) or that GMS itself tags "Spectrum image" is a spectrum
//  image, whose "scale bar" would measure a spectrum — all of these are skipped. Only that exact Format is
//  skipped ("Image", "Diffraction image" and an absent tag open). The object chosen is named in
//  `CalibratedImage.source`, so the Info tab says which one is on screen.
//

import ImagoCore
import Foundation
import FormatoCore
import FormatoDM

package nonisolated enum ImageOpening {
    /// File extensions macTEM reads today, lower case.
    package static let readableExtensions = ["dm4", "dm3", "tif", "tiff", "mrc", "emd"] + SEMEDSOpening.imageExtensions

    package enum Refusal: LocalizedError, Equatable {
        case unreadableFormat(file: String, ext: String)
        case noImage(file: String, objects: String)
        case tiff(file: String, TIFFImageReader.Refusal)
        case mrc(file: String, MRCImageReader.Refusal)
        case velox(file: String, VeloxImageReader.Refusal)
        case jeol(file: String, reason: String)

        /// "notes.txt is a .txt file.", "README is a file without an extension.": what names a file of an extension macTEM does not
        /// open, without the formats it does. A drop of several such files names each with it and the formats once after them
        /// (`FileRouting.dropped`).
        package static func fileClause(file: String, ext: String) -> String {
            let what = ext.isEmpty ? "a file without an extension" : "a .\(ext) file"
            return "\(file) is \(what)."
        }

        /// A file of another extension names what macTEM opens from the table every Open routes by
        /// (`FileRouting.openableSentence`), so the sentence keeps up with the rooms.
        package var errorDescription: String? {
            switch self {
            case .unreadableFormat(let file, let ext):
                return Self.fileClause(file: file, ext: ext) + " " + FileRouting.openableSentence
            case .noImage(let file, let objects):
                return "\(file) holds no 2D image: it holds \(objects). Image stacks and line scans in DM files, and spectrum images in .dm3 files, are not read yet."
            case .tiff(let file, let refusal):
                return "\(file) is not read: " + refusal.reason
            case .mrc(let file, let refusal):
                return "\(file) is not read: " + refusal.reason
            case .velox(let file, let refusal):
                return "\(file) is not read: " + refusal.reason
            case .jeol(let file, let reason):
                return "\(file) is not read: " + reason
            }
        }
    }

    /// Reads the image at `path`, synchronously. The app calls it inside `AppState.read`, off the main actor.
    package static func openNow(path: String) throws -> CalibratedImage {
        let ext = (path as NSString).pathExtension.lowercased()
        guard readableExtensions.contains(ext) else {
            throw Refusal.unreadableFormat(file: formatoDisplayFileName(path), ext: ext)
        }
        if ext == "tif" || ext == "tiff" {
            do { return try TIFFImageReader.read(path: path) } catch let refusal as TIFFImageReader.Refusal {
                throw Refusal.tiff(file: formatoDisplayFileName(path), refusal)
            }
        }
        if SEMEDSOpening.imageExtensions.contains(ext) {
            do { return try SEMEDSOpening.image(url: URL(fileURLWithPath: path)) } catch let refusal as SEMEDSReadError {
                throw Refusal.jeol(file: formatoDisplayFileName(path), reason: refusal.text)
            }
        }
        if ext == "mrc" {
            do { return try MRCImageReader.read(path: path) } catch let refusal as MRCImageReader.Refusal {
                throw Refusal.mrc(file: formatoDisplayFileName(path), refusal)
            }
        }
        if ext == "emd" {
            do { return try VeloxImageReader.read(path: path) } catch let refusal as VeloxImageReader.Refusal {
                throw Refusal.velox(file: formatoDisplayFileName(path), refusal)
            }
        }
        let objects = try DM4Experiment.list(path: path)
        guard let object = primaryImageObject(in: objects) else {
            throw Refusal.noImage(file: formatoDisplayFileName(path), objects: describe(objects))
        }
        return calibratedImage(try DM4Experiment.readImage(path: path, index: object.index),
                               fileName: formatoDisplayFileName(path))
    }

    /// The object rule above.
    package static func primaryImageObject(in objects: [DM4ImageObject]) -> DM4ImageObject? {
        objects.first { $0.role != .thumbnail && $0.role != .eels && imageAxes($0) != nil
            && !hasMixedUnits($0) && !isSpectrumImage($0) && !hasEnergyAxis($0) }
    }

    /// One of the two image axes is in eV or keV: a line scan (positions × channels), whose other axis may carry no unit, so `hasMixedUnits`
    /// does not see it. Drawn as an image it would be a picture of spectra, opened beside the EELS room's refusal (#559).
    private static func hasEnergyAxis(_ object: DM4ImageObject) -> Bool {
        guard let (x, y) = imageAxes(object) else { return false }
        return [x, y].contains { isEnergy($0?.units ?? "") }
    }

    /// The axes of an object's two dimensions larger than one, in file order (x first); nil unless exactly two.
    private static func imageAxes(_ object: DM4ImageObject) -> (DM4Axis?, DM4Axis?)? {
        let big = object.dimensions.indices.filter { object.dimensions[$0] > 1 }
        guard big.count == 2 else { return nil }
        func axis(_ i: Int) -> DM4Axis? { object.axes.indices.contains(i) ? object.axes[i] : nil }
        return (axis(big[0]), axis(big[1]))
    }

    /// GMS's own tag (`ImageTags.Meta Data.Format`, read by DM4Experiment) names the object a spectrum image.
    private static func isSpectrumImage(_ object: DM4ImageObject) -> Bool {
        object.metaDataFormat == "Spectrum image"
    }

    /// Both axes state a unit, and not the same one. An axis with no unit is uncalibrated, not different.
    private static func hasMixedUnits(_ object: DM4ImageObject) -> Bool {
        guard let (x, y) = imageAxes(object), let ux = x?.units, let uy = y?.units,
              !ux.isEmpty, !uy.isEmpty else { return false }
        return ux != uy
    }

    /// A `DM4Image` as macTEM's image; the axes are carried over unchanged.
    package static func calibratedImage(_ image: DM4Image, fileName: String) -> CalibratedImage {
        func axis(_ a: DM4Axis?) -> AxisCalibration? {
            a.map { AxisCalibration(scale: $0.scale, unit: $0.units, origin: $0.origin) }
        }
        let name = image.object.name.isEmpty ? "" : " · \(image.object.name)"
        return CalibratedImage(width: image.width, height: image.height, pixels: image.pixels,
                               x: axis(image.xAxis), y: axis(image.yAxis), fileName: fileName,
                               source: "ImageList.\(image.object.index)\(name)",
                               voltage: image.object.voltage)
    }

    /// What a refused file holds, in words for the message (#532): "an image stack of 3 frames of 2020 × 2020 and 3 profiles of
    /// 2020 points". Identical objects are counted once; a thumbnail is named only when it is all the file holds. Units decide
    /// between a spectrum (an energy axis) and a profile, and between a spectrum image and a stack.
    package static func describe(_ objects: [DM4ImageObject]) -> String {
        let content = objects.filter { $0.role != .thumbnail }
        guard !content.isEmpty else { return objects.isEmpty ? "no image objects" : "only a thumbnail" }
        var order: [String] = []
        var counts: [String: Int] = [:]
        for object in content {
            let words = phrase(object)
            if counts[words] == nil { order.append(words) }
            counts[words, default: 0] += 1
        }
        let listed = order.map { words -> String in
            let n = counts[words] ?? 1
            return n == 1 ? singular(words) : "\(n) \(plural(words))"
        }
        guard listed.count > 1 else { return listed[0] }
        return listed.dropLast().joined(separator: ", ") + " and " + listed[listed.count - 1]
    }

    /// One object's noun phrase without its article: "image stack of 3 frames of 16 × 2", "spectrum of 2048 channels".
    private static func phrase(_ object: DM4ImageObject) -> String {
        let big = object.dimensions.indices.filter { object.dimensions[$0] > 1 }
        let sizes = big.map { object.dimensions[$0] }
        let units = big.map { i in object.axes.indices.contains(i) ? object.axes[i]?.units ?? "" : "" }
        let energy = units.map(isEnergy)
        func by(_ values: [Int]) -> String { values.map(String.init).joined(separator: " × ") }
        switch sizes.count {
        case 0: return "single value"
        case 1: return energy[0] ? "spectrum of \(sizes[0]) channels" : "profile of \(sizes[0]) points"
        case 2:
            if isSpectrumImage(object) { return "spectrum image of \(by(sizes)) positions" }
            if let e = energy.firstIndex(of: true), energy.filter({ $0 }).count == 1 {
                return "line scan of \(sizes[1 - e]) positions with spectra of \(sizes[e]) channels"
            }
            if hasMixedUnits(object) { return "\(by(sizes)) object with its axes in \(units[0]) and \(units[1])" }
            return "\(by(sizes)) object"
        case 3:
            if let e = energy.firstIndex(of: true), energy.filter({ $0 }).count == 1 {
                let positions = sizes.indices.filter { $0 != e }.map { sizes[$0] }
                return "spectrum image of \(by(positions)) positions with spectra of \(sizes[e]) channels"
            }
            return "image stack of \(sizes[2]) frames of \(sizes[0]) × \(sizes[1])"
        default: return "\(by(sizes)) object"
        }
    }

    private static func isEnergy(_ unit: String) -> Bool { ["ev", "kev"].contains(unit.lowercased()) }

    private static func singular(_ phrase: String) -> String {
        let vowel = phrase.first.map { "aeiou".contains($0) } ?? false
        return (vowel ? "an " : "a ") + phrase
    }

    /// The phrase's head noun in the plural: "image stacks of …", "spectra of …", "170 × 1 objects".
    private static func plural(_ phrase: String) -> String {
        for (one, many) in [("image stack", "image stacks"), ("spectrum image", "spectrum images"), ("spectrum", "spectra"),
                            ("profile", "profiles"), ("line scan", "line scans"), ("single value", "single values")]
        where phrase.hasPrefix(one) { return many + phrase.dropFirst(one.count) }
        if let range = phrase.range(of: " object") { return phrase.replacingCharacters(in: range, with: " objects") }
        return phrase
    }

}
