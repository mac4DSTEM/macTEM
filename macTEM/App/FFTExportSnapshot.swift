//
//  FFTExportSnapshot.swift
//  Role: what the FFT room's three exports take from the selected file when their panel opens: Export Transform… (a PNG), Export Radial Profile… and Export Spots… (CSVs).
//        As `ExportSnapshot` does for the Image room: pure functions from the file's own owners (its image and `FFTAnalysis`)
//        to TEMCore's inputs, the words a panel shows, and when each command is enabled. Sendable values taken once; the
//        render and the write that follow run off the main actor on them. The one hand-over to the writers is each
//        snapshot's `write(to:)`, which the panels only call.
//
//        NOTHING STALE IS EXPORTED: all three need the spectrum on screen to be the one asked for (`isSpectrumCurrent`), and the
//        spots are those measured on THAT spectrum.
//

import ShellMetal
import Foundation
#if canImport(TEMCore)
import TEMCore
import TEMSession
import ImagoCore
import ImagoFFT

#endif

// MARK: - Values

/// Which of the three FFT commands is enabled.
nonisolated struct FFTExportAvailability: Sendable, Equatable {
    let transform: Bool
    let profile: Bool
    let spots: Bool
}

/// Everything Export Transform… needs.
nonisolated struct ExportTransformSnapshot: Sendable {
    let header: FFTExportHeader
    let display: ImageExport.Display
    /// One `.spot` mark per measured spot on this spectrum, in list order.
    let marks: [ImageExport.Mark]
    let defaultName: String
    let directory: URL?
    let message: String
    /// Scale bar on, Spots on and offered only when there are some.
    let defaults: ExportImageDefaults

    /// What the panel's OK does: this snapshot's own source, display and spots, to the chosen file.
    nonisolated func write(to url: URL, options: ImageExport.Options) async throws -> ImageExport.Rendered {
        try await ImageExport.export(source: FFTExport.transformSource(header), display: display, marks: marks, options: options,
                                     provenance: FFTExport.transformProvenance(header, spotsDrawn: options.marks ? marks.count : 0),
                                     to: url)
    }
}

/// Everything Export Radial Profile… needs.
nonisolated struct ExportRadialProfileSnapshot: Sendable {
    let header: FFTExportHeader
    let profile: RadialProfile
    let defaultName: String
    let directory: URL?
    let message: String
    /// The rows the file will hold (bins with a pixel).
    let bins: Int

    nonisolated func write(to url: URL) async throws {
        try await RadialProfileCSV.export(profile, header: header, to: url)
    }
}

/// Everything Export Spots… needs.
nonisolated struct ExportSpotsSnapshot: Sendable {
    let header: FFTExportHeader
    let rows: [SpotsCSV.Row]
    let omitted: Int
    let maskRadius: Double
    let maskEdge: Double
    let notes: [String]
    let defaultName: String
    let directory: URL?
    let message: String

    nonisolated func write(to url: URL) async throws {
        try await SpotsCSV.export(rows: rows, omitted: omitted, maskRadius: maskRadius, maskEdge: maskEdge, notes: notes,
                                  header: header, to: url)
    }
}

// MARK: - The rules

extension ExportSnapshot {

    // MARK: Enabled

    /// The transform, the profile and the spots need an image in the FFT room, no read running and the spectrum on screen
    /// current; the profile also a bin outside the DC, the spots a measured spot on that spectrum. Exhaustive over the rooms on
    /// purpose, as `availability` is.
    static func fftAvailability(hasImage: Bool, area: WorkspaceArea, isLoading: Bool, spectrumIsCurrent: Bool,
                                profileHasBins: Bool, measuredSpots: Int) -> FFTExportAvailability {
        let inExportingRoom: Bool
        switch area {
        case .fft: inExportingRoom = true
        case .image, .diffraction, .results, .edx, .eels: inExportingRoom = false
        }
        let ready = hasImage && inExportingRoom && !isLoading && spectrumIsCurrent
        return FFTExportAvailability(transform: ready, profile: ready && profileHasBins, spots: ready && measuredSpots > 0)
    }

    static func fftAvailability(of appState: AppState) -> FFTExportAvailability {
        let analysis = appState.openItems.selected?.fft
        let spectrum = analysis?.isSpectrumCurrent == true ? analysis?.spectrum : nil
        let spots = (analysis != nil && spectrum != nil) ? measuredSpots(on: spectrum!.key, in: analysis!.spots) : []
        return fftAvailability(hasImage: appState.hasImage, area: appState.navigation.workspaceArea,
                               isLoading: appState.imageSession.isLoading, spectrumIsCurrent: spectrum != nil,
                               profileHasBins: spectrum?.profile.map { !$0.points.isEmpty } ?? false,
                               measuredSpots: spots.count)
    }

    /// The measured spots of `key`'s spectrum, in list order: a spot of another region belongs to a transform no longer shown.
    static func measuredSpots(on key: FFTSpectrumKey, in spots: [FFTSpot]) -> [FFTSpot] {
        spots.filter { $0.spectrumKey == key && $0.measured != nil }
    }

    // MARK: Names and words

    /// "scan-fft", "scan-radial-profile", "scan-spots"; a region adds "-r256x256-x812-y404" (size, then the corner's column and row).
    nonisolated static func fftName(fileName: String, product: String, crop: PixelCrop?) -> String {
        let region = crop.map { "-r\($0.width)x\($0.height)-x\($0.col)-y\($0.row)" } ?? ""
        return "\(stem(of: fileName))-\(product)\(region)"
    }

    nonisolated static func transformMessage(crop: PixelCrop?, imageWidth: Int, imageHeight: Int, width: Int, height: Int,
                                             spacingX: Double, spacingY: Double) -> String {
        let of = crop == nil ? "the whole image" : FFTRoomFormat.transformed(crop, imageWidth: imageWidth, imageHeight: imageHeight)
        return "Transform of \(of), \(width) × \(height) bins, log₁₀|F|² in the window shown."
            + aspectSentence(width: width, height: height, spacingX: spacingX, spacingY: spacingY)
    }

    /// The PNG is one square pixel per bin (width : height); the room draws the box at width·Δq_x : height·Δq_y. When the two
    /// differ the panel says so, in words (the file is not resampled). Empty when they agree.
    nonisolated static func aspectSentence(width: Int, height: Int, spacingX: Double, spacingY: Double) -> String {
        guard width > 0, height > 0, spacingX > 0, spacingY > 0 else { return "" }
        let file = Double(width) / Double(height)
        let room = (Double(width) * spacingX) / (Double(height) * spacingY)
        guard abs(file - room) > 1e-6 * room else { return "" }
        func ratio(_ r: Double) -> String {
            func g(_ v: Double) -> String { String(format: "%.3g", v) }
            return r >= 1 ? "\(g(r)) : 1" : "1 : \(g(1 / r))"
        }
        return " This region is \(width) × \(height) bins: the PNG has one pixel per bin, so it is \(ratio(file)) where the room shows it \(ratio(room))."
    }

    nonisolated static func radialProfileMessage(bins: Int, reciprocalLabel: String, nativeUnit: String) -> String {
        "\(bins == 1 ? "1 bin" : "\(bins) bins") · |q| in \(reciprocalLabel) and \(nativeUnit) · mean |F|² of the transform, unwindowed"
    }

    nonisolated static func spotsMessage(listed: Int, omitted: Int) -> String {
        let base = listed == 1 ? "1 spot measured" : "\(listed) spots measured"
        return omitted > 0 ? "\(base) · \(omitted) not listed (refused, still measuring or no peak)" : base
    }

    nonisolated static func transformDoneLine(name: String, width: Int, height: Int, spots: Int, barLeftOut: Bool) -> String {
        let size = "\(width) × \(height) bins"
        let drawn = spots == 0 ? "" : (spots == 1 ? " (1 spot drawn)" : " (\(spots) spots drawn)")
        return barLeftOut ? "Exported \(name) without the scale bar (the transform is too small) — \(size)\(drawn)"
                          : "Exported \(name) — \(size)\(drawn)"
    }

    nonisolated static func radialProfileDoneLine(name: String, bins: Int) -> String {
        "Exported \(name) — \(bins == 1 ? "1 bin" : "\(bins) bins")"
    }

    nonisolated static func spotsDoneLine(name: String, spots: Int) -> String {
        "Exported \(name) — \(spots == 1 ? "1 spot" : "\(spots) spots")"
    }

    // MARK: From the owners

    /// The header every FFT export names, from the file's image and the spectrum on screen.
    nonisolated static func fftHeader(image: CalibratedImage, spectrum: FFTSpectrumProduct, software: String) -> FFTExportHeader {
        FFTExportHeader(software: software, fileName: image.fileName, object: image.source, imageWidth: image.width,
                        imageHeight: image.height, x: image.x, y: image.y, notes: image.notes, crop: spectrum.key.crop,
                        spectrumWidth: spectrum.width, spectrumHeight: spectrum.height, spacingX: spectrum.spacingX,
                        spacingY: spectrum.spacingY, unitsX: spectrum.unitsX, unitsY: spectrum.unitsY)
    }

    /// The transform through the owner's window as the shader gets it (grey, gamma 1), and one ring per measured spot.
    static func transformSnapshot(image: CalibratedImage, url: URL?, analysis: FFTAnalysis, software: String)
        -> ExportTransformSnapshot? {
        guard analysis.isSpectrumCurrent, let spectrum = analysis.spectrum,
              spectrum.canvas.width == spectrum.width, spectrum.canvas.height == spectrum.height else { return nil }
        let window = FFTSpectrumLayout.window(low: analysis.spectrumWindowLow, high: analysis.spectrumWindowHigh, spectrum: spectrum)
        let canvas = spectrum.canvas
        let display = ImageExport.Display(
            normalized: canvas.normalized, width: canvas.width, height: canvas.height, low: window.low, high: window.high,
            gamma: 1, lut: Colormaps.lutRGBA(.gray), colormap: ColormapKind.gray.rawValue,
            windowLow: analysis.spectrumWindowLow ?? spectrum.defaultWindow?.low,
            windowHigh: analysis.spectrumWindowHigh ?? spectrum.defaultWindow?.high, rawRange: canvas.rawRange)
        let marks: [ImageExport.Mark] = measuredSpots(on: spectrum.key, in: analysis.spots).compactMap { spot in
            guard let m = spot.measured else { return nil }
            return ImageExport.Mark(kind: .spot, points: [ImagePoint(x: m.centroidCol, y: m.centroidRow)], width: 1,
                                    label: "\(spot.number)")
        }
        let crop = spectrum.key.crop
        return ExportTransformSnapshot(
            header: fftHeader(image: image, spectrum: spectrum, software: software), display: display, marks: marks,
            defaultName: fftName(fileName: image.fileName, product: "fft", crop: crop),
            directory: url?.deletingLastPathComponent(),
            message: transformMessage(crop: crop, imageWidth: image.width, imageHeight: image.height, width: spectrum.width,
                                      height: spectrum.height, spacingX: spectrum.spacingX, spacingY: spectrum.spacingY),
            defaults: ExportImageDefaults(scaleBar: true, marks: true, offersMarks: !marks.isEmpty))
    }

    static func radialProfileSnapshot(image: CalibratedImage, url: URL?, analysis: FFTAnalysis, software: String)
        -> ExportRadialProfileSnapshot? {
        guard analysis.isSpectrumCurrent, let spectrum = analysis.spectrum, let profile = spectrum.profile else { return nil }
        let bins = profile.points.count   // the rows of the file and the points of the chart: one rule
        guard bins > 0 else { return nil }
        let shown = FFTUnits.spectrumUnit(profile.units)
        return ExportRadialProfileSnapshot(
            header: fftHeader(image: image, spectrum: spectrum, software: software), profile: profile,
            defaultName: fftName(fileName: image.fileName, product: "radial-profile", crop: spectrum.key.crop),
            directory: url?.deletingLastPathComponent(),
            message: radialProfileMessage(bins: bins, reciprocalLabel: shown.label, nativeUnit: profile.units), bins: bins)
    }

    static func spotsSnapshot(image: CalibratedImage, url: URL?, analysis: FFTAnalysis, software: String) -> ExportSpotsSnapshot? {
        guard analysis.isSpectrumCurrent, let spectrum = analysis.spectrum else { return nil }
        let listed = measuredSpots(on: spectrum.key, in: analysis.spots)
        guard !listed.isEmpty else { return nil }
        let rows = listed.compactMap { spot in spot.measured.map { SpotsCSV.Row(number: spot.number, measured: $0, inMask: spot.inMask) } }
        let omitted = analysis.spots.count - rows.count
        let notes = FFTRoomFormat.accuracyNote(width: spectrum.key.crop?.width ?? image.width,
                                               height: spectrum.key.crop?.height ?? image.height).map { [$0] } ?? []
        return ExportSpotsSnapshot(
            header: fftHeader(image: image, spectrum: spectrum, software: software), rows: rows, omitted: omitted,
            maskRadius: analysis.maskRadius, maskEdge: analysis.maskEdge, notes: notes,
            defaultName: fftName(fileName: image.fileName, product: "spots", crop: spectrum.key.crop),
            directory: url?.deletingLastPathComponent(), message: spotsMessage(listed: rows.count, omitted: omitted))
    }

    /// The window's selected item's: an export is of the file on screen, never of another open one.
    static func transformSnapshot(in openItems: OpenItems, software: String = softwareName()) -> ExportTransformSnapshot? {
        guard let item = openItems.selected, let image = item.session.image else { return nil }
        return transformSnapshot(image: image, url: item.url, analysis: item.fft, software: software)
    }

    static func radialProfileSnapshot(in openItems: OpenItems, software: String = softwareName()) -> ExportRadialProfileSnapshot? {
        guard let item = openItems.selected, let image = item.session.image else { return nil }
        return radialProfileSnapshot(image: image, url: item.url, analysis: item.fft, software: software)
    }

    static func spotsSnapshot(in openItems: OpenItems, software: String = softwareName()) -> ExportSpotsSnapshot? {
        guard let item = openItems.selected, let image = item.session.image else { return nil }
        return spotsSnapshot(image: image, url: item.url, analysis: item.fft, software: software)
    }
}
