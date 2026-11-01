//
//  ImageOpening.swift
//  Role: open a file as macTEM's `CalibratedImage`. The one entry point the app calls; it picks the reader by
//        extension and, in a file that holds several objects, the object to show by the rule below.
//
//  OBJECT RULE (pre-registered): the first object in the file's own order that
//  is not the thumbnail, has exactly two dimensions larger than one, whose two axes do not carry two different
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
    package static let readableExtensions = ["dm4", "dm3", "tif", "tiff", "mrc", "emd"]

    package enum Refusal: LocalizedError, Equatable {
        case unreadableFormat(file: String, ext: String)
        case noImage(file: String, objects: String)
        case tiff(file: String, TIFFImageReader.Refusal)
        case mrc(file: String, MRCImageReader.Refusal)
        case velox(file: String, VeloxImageReader.Refusal)

        package var errorDescription: String? {
            switch self {
            case .unreadableFormat(let file, let ext):
                let what = ext.isEmpty ? "a file without an extension" : "a .\(ext) file"
                return "\(file) is \(what). macTEM opens .dm4, .dm3, .tif, .mrc and Velox .emd images; other formats are not read yet."
            case .noImage(let file, let objects):
                return "\(file) holds no 2D image (\(objects)). Image stacks and spectrum images are not read yet."
            case .tiff(let file, let refusal):
                return "\(file) is not read: " + refusal.reason
            case .mrc(let file, let refusal):
                return "\(file) is not read: " + refusal.reason
            case .velox(let file, let refusal):
                return "\(file) is not read: " + refusal.reason
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
        objects.first { $0.role != .thumbnail && imageAxes($0) != nil
            && !hasMixedUnits($0) && !isSpectrumImage($0) }
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

    /// "thumbnail 8 × 6; 170 × 1; 1336 × 67 in nm and µm; 6 × 3 spectrum image" — what a refused file holds, for the message.
    private static func describe(_ objects: [DM4ImageObject]) -> String {
        guard !objects.isEmpty else { return "no image objects" }
        return objects.map { o in
            let dims = o.dimensions.map(String.init).joined(separator: " × ")
            if o.role == .thumbnail { return "thumbnail \(dims)" }
            if isSpectrumImage(o) { return "\(dims) spectrum image" }
            if hasMixedUnits(o), let (x, y) = imageAxes(o), let ux = x?.units, let uy = y?.units {
                return "\(dims) in \(ux) and \(uy)"
            }
            return dims
        }.joined(separator: "; ")
    }
}
