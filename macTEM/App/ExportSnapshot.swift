//
//  ExportSnapshot.swift
//  Role: what an export takes from the selected file when its panel opens (V1-10 slice 1, archive: roadmap-registrations-2026-10-15.md "Completed at
//        pickup — slice 1"; archive: export-design-2026-10-13.md). Pure functions from the file's own owners (its
//        image, `ImagePresentation`, `ImageMeasurements`) to TEMCore's inputs (`ExportSource`, `ImageExport.Display`,
//        `ImageExport.Mark`, a profile and its ends) and to the words a panel shows: the default names, the message
//        lines, the status lines, the defaults of the options, and when the two commands are enabled. Nothing is stored
//        here and nothing is written: `ExportPanels` presents, TEMCore renders and writes, and a test pins every rule
//        in this file without a window.
//
//        A snapshot is Sendable values (arrays are copy-on-write, so the canvas is shared, not copied): it is taken
//        when the panel opens, and the render that follows runs off the main actor on it, whatever the window does
//        meanwhile. The FILE's calibration goes into the source (`ExportSource` states it as the file does); the
//        display-converted one (`MarkFormat.shown`) only names the unit a profile's positions are shown in.
//
//        THE HAND-OVER to TEMCore's writers is one function on each snapshot (`write(to:)`), and the panels only call it:
//        the one place the snapshot's values meet the writer is then a place a unit test can reach (Gate B R2 F1: two
//        mutations there — the ends swapped, the shown unit dropped — had passed every gate while it lived in the panel).
//

import ShellMetal
import ImagoCore
import Foundation
import TEMCore
import TEMSession

// MARK: - Values

/// What the Export Image panel's options start as, and whether it offers them all.
nonisolated struct ExportImageDefaults: Sendable, Equatable {
    /// The Display section's Show Scale Bar of this file.
    var scaleBar: Bool
    /// On; whether the panel offers it at all is `offersMarks`.
    var marks: Bool
    /// Marks are offered only when the file has some: an option with nothing behind it is omitted, never dimmed.
    var offersMarks: Bool
}

/// Everything Export Image… needs, taken when the panel opens.
nonisolated struct ExportImageSnapshot: Sendable {
    let source: ExportSource
    let display: ImageExport.Display
    let marks: [ImageExport.Mark]
    /// The bare stem the name field starts as (never an extension: the panel's content type supplies it).
    let defaultName: String
    /// The image's folder, where the panel opens.
    let directory: URL?
    let message: String
    let defaults: ExportImageDefaults
}

extension ExportImageSnapshot {
    /// What the panel's OK does: this snapshot's own source, display and marks, drawn as `options` say, to the chosen file
    /// and nothing else. The panel only calls it, so a test that calls it pins the one hand-over from the snapshot to the
    /// renderer.
    nonisolated func write(to url: URL, options: ImageExport.Options) async throws -> ImageExport.Rendered {
        try await ImageExport.export(source: source, display: display, marks: marks, options: options, to: url)
    }
}

/// Everything Export Profile… needs, taken when the panel opens.
nonisolated struct ExportProfileSnapshot: Sendable {
    let source: ExportSource
    let profile: LineProfile
    let start: ImagePoint
    let end: ImagePoint
    /// The unit and factor the app shows the positions in when that is not the file's own (`ProfileCSV.text`).
    let shown: (unit: String, factor: Double)?
    let defaultName: String
    let directory: URL?
    let message: String
}

extension ExportProfileSnapshot {
    /// What the panel's OK does: this snapshot's own profile, ends, source and shown unit to the chosen file and nothing
    /// else. The panel only calls it, so a test that calls it pins the one hand-over from the snapshot to the writer.
    nonisolated func write(to url: URL) async throws {
        try await ProfileCSV.export(profile, start: start, end: end, source: source, shown: shown, to: url)
    }
}

/// The selected mark when it is a profile with samples: the one the CSV exports.
nonisolated struct SelectedProfile: Sendable {
    let mark: ImageMark
    let profile: LineProfile
    /// Its place among the file's profile marks (from 1, in the list's order), and how many there are: the default
    /// name tells two profiles of one file apart.
    let number: Int
    let count: Int
}

/// Which of the commands is enabled: Export Image… and Export Profile… (the Image room), Export Results… (the Results room).
nonisolated struct ExportAvailability: Sendable, Equatable {
    let image: Bool
    let profile: Bool
    /// The Results room's Export Results…: a file with at least one finished measurement, no read running.
    var results: Bool = false
}

// MARK: - The rules

enum ExportSnapshot {

    /// The labels in the PNG are not the reader's: a de_DE user still gets "12.43 nm" in a figure (archive: roadmap-registrations-2026-10-15.md V1-10).
    nonisolated static let labelLocale = Locale(identifier: "en_US_POSIX")

    // MARK: Software

    /// "macTEM 0.1.0 (1)": the version and build the bundle states. What the export files name as their writer.
    nonisolated static func softwareName(info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        guard let version = info?["CFBundleShortVersionString"] as? String, !version.isEmpty else { return "macTEM" }
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else { return "macTEM \(version)" }
        return "macTEM \(version) (\(build))"
    }

    // MARK: Names

    /// The file's name without its extension ("scan" for "scan.dm4", "scan.v2" for "scan.v2.dm4"); "image" for a name
    /// with no stem. Never an extension: the save panel's content type supplies it (mac4DSTEM shipped "scan.png.png" twice).
    nonisolated static func stem(of fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        return stem.isEmpty ? "image" : stem
    }

    nonisolated static func imageName(fileName: String) -> String { stem(of: fileName) }

    /// "scan-profile" for a file with one profile mark, "scan-profile-2" for the second of several.
    nonisolated static func profileName(fileName: String, number: Int, count: Int) -> String {
        count > 1 ? "\(stem(of: fileName))-profile-\(number)" : "\(stem(of: fileName))-profile"
    }

    // MARK: Words

    /// The PNG panel's message: the export ignores zoom and pan, so it says what it is (not "as shown", which read as
    /// the zoomed view).
    nonisolated static func imageMessage(width: Int, height: Int) -> String {
        "Whole image, \(width) × \(height) px, with the contrast and colormap shown."
    }

    /// The CSV panel's message: "51 samples · positions in m, as the file states it · width 3 px". A profile in
    /// pixels states no file unit.
    nonisolated static func profileMessage(samples: Int, unit: String, isPhysical: Bool, width: Int) -> String {
        let count = samples == 1 ? "1 sample" : "\(samples) samples"
        let positions = isPhysical ? "positions in \(unit), as the file states it" : "positions in \(unit)"
        return "\(count) · \(positions) · width \(width) px"
    }

    /// The infobar while the render and the write run.
    nonisolated static func exportingLine(name: String) -> String { "Exporting \(name)…" }

    /// The infobar, and the VoiceOver announcement, when the PNG is written. What was left out comes right after the name:
    /// the infobar is one line cut at its tail (Gate B U5), and the notice is the part the user needs.
    nonisolated static func imageDoneLine(name: String, width: Int, height: Int, barLeftOut: Bool) -> String {
        let size = "\(width) × \(height) px"
        return barLeftOut ? "Exported \(name) without the scale bar (the image is too small) — \(size)"
                          : "Exported \(name) — \(size)"
    }

    /// The infobar, and the VoiceOver announcement, when the CSV is written.
    nonisolated static func profileDoneLine(name: String, samples: Int) -> String {
        "Exported \(name) — \(samples == 1 ? "1 sample" : "\(samples) samples")"
    }

    // MARK: Options

    /// The options TEMCore draws: marks only when the panel offered them and they were left on.
    nonisolated static func options(scaleBar: Bool, marks: Bool, offersMarks: Bool) -> ImageExport.Options {
        ImageExport.Options(scaleBar: scaleBar, marks: offersMarks && marks)
    }

    /// A side the PNG cannot have, refused by name before the panel asks for a place (TEMCore refuses it again).
    nonisolated static func refusal(width: Int, height: Int) -> ExportFile.Failure? {
        width > ImageExport.maximumSide || height > ImageExport.maximumSide
            ? .tooLarge(width: width, height: height) : nil
    }

    // MARK: Enabled

    /// The first two commands need an image with its pixels in the Image room, no read running; the second also a profile with
    /// samples selected. Export Results… needs the Results room, an image, no read running and `resultRows` of them (V1-10
    /// slice 3). Exhaustive over the rooms on purpose: a room that is built later decides here whether it exports.
    static func availability(hasImage: Bool, area: WorkspaceArea, isLoading: Bool, profileHasSamples: Bool,
                             resultRows: Int = 0) -> ExportAvailability {
        let inExportingRoom: Bool
        switch area {
        case .image: inExportingRoom = true
        case .fft, .diffraction, .results, .edx, .eels: inExportingRoom = false
        }
        let inResultsRoom: Bool
        switch area {
        case .results: inResultsRoom = true
        case .image, .fft, .diffraction, .edx, .eels: inResultsRoom = false
        }
        let ready = hasImage && inExportingRoom && !isLoading
        return ExportAvailability(image: ready, profile: ready && profileHasSamples,
                                  results: hasImage && inResultsRoom && !isLoading && resultRows > 0)
    }

    static func availability(of appState: AppState) -> ExportAvailability {
        // The ledger is read only where its count decides something: the Results room.
        let rows = appState.navigation.workspaceArea == .results
            ? appState.openItems.selected.map { ResultsLedger.rows(of: $0).count } ?? 0 : 0
        return availability(hasImage: appState.hasImage, area: appState.navigation.workspaceArea,
                            isLoading: appState.imageSession.isLoading,
                            profileHasSamples: selectedProfile(in: appState.measurements) != nil, resultRows: rows)
    }

    // MARK: From the owners

    /// The selected mark when it is a profile whose line has samples (a profile with none is not exported).
    static func selectedProfile(in measurements: ImageMeasurements) -> SelectedProfile? {
        guard let mark = measurements.mark(measurements.selection), mark.kind == .profile,
              let profile = measurements.profiles[mark.id], !profile.samples.isEmpty else { return nil }
        let profiles = measurements.marks.filter { $0.kind == .profile }
        guard let index = profiles.firstIndex(where: { $0.id == mark.id }) else { return nil }
        return SelectedProfile(mark: mark, profile: profile, number: index + 1, count: profiles.count)
    }

    /// The file's marks as TEMCore draws them, each labelled in `labelLocale` from the FILE's axes (`MarkFormat` does
    /// the display conversion itself). Only a profile has a width.
    nonisolated static func exportMarks(_ marks: [ImageMark], x: AxisCalibration?, y: AxisCalibration?) -> [ImageExport.Mark] {
        marks.map { mark in
            let kind: ImageExport.MarkKind
            switch mark.kind {
            case .distance: kind = .distance
            case .angle: kind = .angle
            case .profile: kind = .profile
            }
            return ImageExport.Mark(kind: kind, points: mark.points, width: mark.kind == .profile ? mark.width : 1,
                                    label: MarkFormat.value(mark, x: x, y: y, locale: labelLocale))
        }
    }

    /// The canvas through the settings as the shader gets them: the window as fractions, the gamma, the colormap's
    /// LUT; and the raw values (window and range) the metadata records.
    static func display(canvas: CanvasPixels, presentation: ImagePresentation) -> ImageExport.Display {
        let window = presentation.displayFractions
        return ImageExport.Display(
            normalized: canvas.normalized, width: canvas.width, height: canvas.height,
            low: window.low, high: window.high, gamma: presentation.gamma,
            lut: Colormaps.lutRGBA(presentation.colormap), colormap: presentation.colormap.rawValue,
            windowLow: presentation.windowLow, windowHigh: presentation.windowHigh, rawRange: canvas.rawRange)
    }

    /// Export Image… for a file's owners; nil when the file holds no pixels (cold, or still being read) or its canvas
    /// is not its image's size (never both in a real item: one read publishes both).
    static func imageSnapshot(image: CalibratedImage, url: URL?, presentation: ImagePresentation,
                              measurements: ImageMeasurements, software: String) -> ExportImageSnapshot? {
        guard let canvas = presentation.canvas, canvas.width == image.width, canvas.height == image.height else {
            return nil
        }
        let marks = measurements.marks
        return ExportImageSnapshot(
            source: ExportSource(image: image, software: software),
            display: display(canvas: canvas, presentation: presentation),
            marks: exportMarks(marks, x: image.x, y: image.y),
            defaultName: imageName(fileName: image.fileName),
            directory: url?.deletingLastPathComponent(),
            message: imageMessage(width: image.width, height: image.height),
            defaults: ExportImageDefaults(scaleBar: presentation.showsScaleBar, marks: true, offersMarks: !marks.isEmpty))
    }

    /// The unit and factor a profile's positions are shown in when that differs from the file's (`MarkFormat.shown`, the
    /// chart's rule): a metre axis in nm, µm or mm; nil when it is the same, or the profile is in pixels.
    nonisolated static func shownPositions(of profile: LineProfile, x: AxisCalibration?, y: AxisCalibration?)
        -> (unit: String, factor: Double)? {
        let axes = MarkFormat.shown(x: x, y: y)
        guard profile.isPhysical, let unit = axes.unit, unit != profile.unit || axes.factor != 1 else { return nil }
        return (unit, axes.factor)
    }

    /// Export Profile… for a file's owners; nil unless a profile with samples is selected.
    static func profileSnapshot(image: CalibratedImage, url: URL?, measurements: ImageMeasurements,
                                software: String) -> ExportProfileSnapshot? {
        guard let selected = selectedProfile(in: measurements), selected.mark.points.count == 2 else { return nil }
        let profile = selected.profile
        return ExportProfileSnapshot(
            source: ExportSource(image: image, software: software),
            profile: profile,
            start: selected.mark.points[0], end: selected.mark.points[1],
            shown: shownPositions(of: profile, x: image.x, y: image.y),
            defaultName: profileName(fileName: image.fileName, number: selected.number, count: selected.count),
            directory: url?.deletingLastPathComponent(),
            message: profileMessage(samples: profile.samples.count, unit: profile.unit,
                                    isPhysical: profile.isPhysical, width: profile.width))
    }

    /// One item's snapshots: its own owners and nothing else.
    static func imageSnapshot(of item: OpenItem, software: String = softwareName()) -> ExportImageSnapshot? {
        guard let image = item.session.image else { return nil }
        return imageSnapshot(image: image, url: item.url, presentation: item.presentation,
                             measurements: item.measurements, software: software)
    }

    static func profileSnapshot(of item: OpenItem, software: String = softwareName()) -> ExportProfileSnapshot? {
        guard let image = item.session.image else { return nil }
        return profileSnapshot(image: image, url: item.url, measurements: item.measurements, software: software)
    }

    /// The window's selected item's: an export is of the file on screen, never of another open one.
    static func imageSnapshot(in openItems: OpenItems, software: String = softwareName()) -> ExportImageSnapshot? {
        openItems.selected.flatMap { imageSnapshot(of: $0, software: software) }
    }

    static func profileSnapshot(in openItems: OpenItems, software: String = softwareName()) -> ExportProfileSnapshot? {
        openItems.selected.flatMap { profileSnapshot(of: $0, software: software) }
    }
}
