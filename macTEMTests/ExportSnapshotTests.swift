//
//  ExportSnapshotTests.swift
//  Pins what an export takes from the selected file when its panel opens (`ExportSnapshot`, `ExportPanels`):
//  the default names (the bare stem, never an extension), the message and status
//  lines, the options' defaults, when the two commands are enabled, the display settings as the shader gets them, the marks
//  labelled in en_US_POSIX whatever the reader's locale, a profile after its width changed equal to `LineProfile.sample` on
//  the current image, the selected item and nothing else, and the save panels' configuration and the accessory's size.
//  Every expected string is a literal worked out by hand (the comment on each test gives the arithmetic), never read back
//  from the code under test. The TEMCore renderer and writers are pinned elsewhere (ImageExport*Tests, ProfileCSVTests, the
//  export-parity harness); nothing here renders or writes a file, and no panel is shown.
//
//  Each test names, in its comment, the changes to the production code that turn it red. Every one of them was applied ALONE
//  to a scratch copy of the production file (2026-10-13, an isolated tree of git HEAD plus this lane's and lane A's files),
//  the class run, and the test it names went red with the assertion it is meant to fail on: 46 mutations, 21 tests; some
//  also turn other tests red, which is not a defect (the stem, the width and the locale are pinned in more than one place).
//  The lane's logs are in its report, not the repo.
//
//  The tests under "What OK writes", "A re-read file", "The shown unit" and the window and announcement tests were added by
//  A review (2026-10-14), each for a change that had passed every gate: the hand-over from a snapshot to its writer (the ends
//  swapped, the shown unit dropped, the marks or the options not passed), a cold file read again without its profiles
//  recomputed, the shown factor right only for a metre axis, a profile whose end was moved, a window closed under the
//  sheet, a spoken line at default priority. Each was broken once on a scratch copy, as above.
//

import ShellMetal
import ImagoCore
import AppKit
import UniformTypeIdentifiers
import XCTest
import FormatoCore
import TEMCore
import TEMSession
@testable import macTEM

/// The generation a test reader gives the pixels of the file "a.dm4": bumped to say the file changed on disk, read by the
/// reader off the main actor.
nonisolated private final class ReaderGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func bump() { lock.lock(); n += 1; lock.unlock() }
}

nonisolated final class ExportSnapshotTests: XCTestCase {

    // MARK: - Fixtures

    private static let software = "macTEM 0.1.0 (1)"
    private static let posix = Locale(identifier: "en_US_POSIX")
    private static let german = Locale(identifier: "de_DE")

    private static func axis(_ scale: Double, _ units: String) -> AxisCalibration { AxisCalibration(scale: scale, unit: units, origin: 0) }

    /// 8 × 6 pixels of a deterministic non-linear pattern, so a profile of width 5 differs from one of width 1 and every
    /// pixel is a value the file really holds (0…96). `shift` makes another file of the same size (the same file changed).
    nonisolated private static func pattern(width: Int, height: Int, shift: Int = 0) -> [Float] {
        (0..<width * height).map { Float(($0 * 37 + ($0 / width) * 11 + shift * 31) % 97) }
    }

    nonisolated private static func image(width: Int = 8, height: Int = 6, x: AxisCalibration? = AxisCalibration(scale: 0.5, unit: "nm", origin: 0),
                                          y: AxisCalibration? = AxisCalibration(scale: 0.8, unit: "nm", origin: 0),
                                          fileName: String = "scan.dm4", source: String = "ImageList.1",
                                          notes: [String] = [], shift: Int = 0) -> CalibratedImage {
        CalibratedImage(width: width, height: height, pixels: pattern(width: width, height: height, shift: shift), x: x, y: y,
                        fileName: fileName, source: source, voltage: nil, notes: notes)
    }

    /// The owners of one open file, as `OpenItem` makes them: the presentation holds the canvas the reader built.
    @MainActor private func owners(_ image: CalibratedImage) -> (presentation: ImagePresentation, measurements: ImageMeasurements) {
        let presentation = ImagePresentation()
        presentation.show(AppState.canvas(for: image))
        return (presentation, ImageMeasurements())
    }

    @MainActor private func imageSnapshot(_ image: CalibratedImage, _ owners: (presentation: ImagePresentation, measurements: ImageMeasurements),
                                          url: URL? = URL(fileURLWithPath: "/data/run1/scan.dm4")) throws -> ExportImageSnapshot {
        try XCTUnwrap(ExportSnapshot.imageSnapshot(image: image, url: url, presentation: owners.presentation,
                                                   measurements: owners.measurements, software: Self.software))
    }

    // MARK: - Software and names

    /// The writer the files name: the bundle's version, then its build in parentheses. Red under: the parentheses dropped;
    /// the build before the version.
    func testTheSoftwareLineIsTheBundlesVersionAndBuild() {
        XCTAssertEqual(ExportSnapshot.softwareName(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"]),
                       "macTEM 0.1.0 (1)")
        XCTAssertEqual(ExportSnapshot.softwareName(info: ["CFBundleShortVersionString": "2.3.4", "CFBundleVersion": "77"]),
                       "macTEM 2.3.4 (77)")
        XCTAssertEqual(ExportSnapshot.softwareName(info: ["CFBundleShortVersionString": "0.1.0"]), "macTEM 0.1.0")
        XCTAssertEqual(ExportSnapshot.softwareName(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": ""]),
                       "macTEM 0.1.0")
        XCTAssertEqual(ExportSnapshot.softwareName(info: [:]), "macTEM")
        XCTAssertEqual(ExportSnapshot.softwareName(info: nil), "macTEM")
        // The running bundle (the app is the test host) states both.
        let running = ExportSnapshot.softwareName()
        XCTAssertNotNil(running.range(of: #"^macTEM \d+\.\d+\.\d+ \(\d+\)$"#, options: .regularExpression),
                        "\(running) is not 'macTEM <version> (<build>)'")
    }

    /// "scan" for "scan.dm4", never an extension: the panel's content type supplies it (mac4DSTEM shipped "scan.png.png"
    /// twice). Red under: the file name returned whole; a name with no stem left empty.
    func testTheDefaultNamesAreTheBareStem() {
        XCTAssertEqual(ExportSnapshot.imageName(fileName: "scan.dm4"), "scan")
        XCTAssertEqual(ExportSnapshot.imageName(fileName: "scan.v2.dm4"), "scan.v2")
        XCTAssertEqual(ExportSnapshot.imageName(fileName: "sample \u{00C5} \u{00B5}.mrc"), "sample \u{00C5} \u{00B5}")
        XCTAssertEqual(ExportSnapshot.imageName(fileName: "noextension"), "noextension")
        XCTAssertEqual(ExportSnapshot.imageName(fileName: ""), "image")
        for name in ["scan.dm4", "scan.v2.tif", "a.emd"] {
            XCTAssertFalse(ExportSnapshot.imageName(fileName: name).hasSuffix(".png"))
            XCTAssertFalse(ExportSnapshot.imageName(fileName: name).hasSuffix(".dm4"))
        }
    }

    /// One profile mark in the file: "scan-profile"; several: the N-th by its place among the profile marks, from 1.
    /// Red under: the number added to a lone profile; the number counted from 0.
    func testAProfilesNameTellsSeveralOfOneFileApart() {
        XCTAssertEqual(ExportSnapshot.profileName(fileName: "scan.dm4", number: 1, count: 1), "scan-profile")
        XCTAssertEqual(ExportSnapshot.profileName(fileName: "scan.dm4", number: 1, count: 3), "scan-profile-1")
        XCTAssertEqual(ExportSnapshot.profileName(fileName: "scan.dm4", number: 2, count: 3), "scan-profile-2")
        XCTAssertEqual(ExportSnapshot.profileName(fileName: "scan.dm4", number: 3, count: 3), "scan-profile-3")
    }

    // MARK: - The words

    /// The panels' message lines: the PNG's says it is the whole image (the export ignores zoom and pan), the CSV's
    /// counts the samples and states the position unit as the file states it. Red under: "1 samples"; the file's unit
    /// claimed for a profile in pixels.
    func testTheMessagesSayWhatTheFileWillHold() {
        XCTAssertEqual(ExportSnapshot.imageMessage(width: 1024, height: 1024),
                       "Whole image, 1024 \u{00D7} 1024 px, with the contrast and colormap shown.")
        XCTAssertEqual(ExportSnapshot.imageMessage(width: 4096, height: 3072),
                       "Whole image, 4096 \u{00D7} 3072 px, with the contrast and colormap shown.")
        XCTAssertEqual(ExportSnapshot.profileMessage(samples: 51, unit: "m", isPhysical: true, width: 3),
                       "51 samples \u{00B7} positions in m, as the file states it \u{00B7} width 3 px")
        XCTAssertEqual(ExportSnapshot.profileMessage(samples: 4096, unit: "nm", isPhysical: true, width: 1),
                       "4096 samples \u{00B7} positions in nm, as the file states it \u{00B7} width 1 px")
        XCTAssertEqual(ExportSnapshot.profileMessage(samples: 1, unit: "px", isPhysical: false, width: 25),
                       "1 sample \u{00B7} positions in px \u{00B7} width 25 px")
    }

    /// The infobar's lines: working, then the file written, and what the bar's plate could not hold. The infobar is one
    /// line cut at its tail, so the notice comes right after the name, before the size. Red under: the
    /// ellipsis written as three dots; the left-out clause dropped; the notice put back at the tail.
    func testTheStatusLinesNameTheFileAndWhatWasLeftOut() {
        XCTAssertEqual(ExportSnapshot.exportingLine(name: "scan.png"), "Exporting scan.png\u{2026}")
        XCTAssertEqual(ExportSnapshot.imageDoneLine(name: "scan.png", width: 1024, height: 768, barLeftOut: false),
                       "Exported scan.png \u{2014} 1024 \u{00D7} 768 px")
        XCTAssertEqual(ExportSnapshot.imageDoneLine(name: "tiny.png", width: 100, height: 80, barLeftOut: true),
                       "Exported tiny.png without the scale bar (the image is too small) \u{2014} 100 \u{00D7} 80 px")
        XCTAssertEqual(ExportSnapshot.profileDoneLine(name: "scan-profile.csv", samples: 51),
                       "Exported scan-profile.csv \u{2014} 51 samples")
        XCTAssertEqual(ExportSnapshot.profileDoneLine(name: "p.csv", samples: 1), "Exported p.csv \u{2014} 1 sample")
    }

    /// A side above TEMCore's limit is refused by name before the panel asks for a place. Red under: the limit moved by
    /// one (`>=`); only the width checked.
    func testASideAboveTheLimitIsRefusedByNameBeforeThePanel() {
        XCTAssertNil(ExportSnapshot.refusal(width: 16384, height: 16384))
        XCTAssertEqual(ExportSnapshot.refusal(width: 16385, height: 100), .tooLarge(width: 16385, height: 100))
        XCTAssertEqual(ExportSnapshot.refusal(width: 100, height: 20000), .tooLarge(width: 100, height: 20000))
        XCTAssertEqual(ExportFile.Failure.tooLarge(width: 20000, height: 300).errorDescription,
                       "The image is 20000 \u{00D7} 300 px; export takes at most 16384 px a side.")
    }

    // MARK: - Defaults and options

    /// The scale bar starts as the Display section's Show Scale Bar of THIS file, Marks start on and are offered only when
    /// the file has marks (omitted, never dimmed). Red under: the scale bar always on; Marks always offered.
    @MainActor func testTheDefaultsFollowTheFileNotTheApp() throws {
        let image = Self.image()
        let bare = owners(image)
        bare.presentation.showsScaleBar = false
        XCTAssertEqual(try imageSnapshot(image, bare).defaults,
                       ExportImageDefaults(scaleBar: false, marks: true, offersMarks: false))
        bare.presentation.showsScaleBar = true
        XCTAssertEqual(try imageSnapshot(image, bare).defaults,
                       ExportImageDefaults(scaleBar: true, marks: true, offersMarks: false))
        bare.measurements.add(ImageMark(kind: .distance, points: [ImagePoint(x: 0, y: 0), ImagePoint(x: 3, y: 2)]), on: image)
        XCTAssertEqual(try imageSnapshot(image, bare).defaults,
                       ExportImageDefaults(scaleBar: true, marks: true, offersMarks: true))
        // The panel's checkboxes start as the defaults.
        let choices = ExportImageChoices(ExportImageDefaults(scaleBar: false, marks: true, offersMarks: true))
        XCTAssertFalse(choices.scaleBar)
        XCTAssertTrue(choices.marks)
        XCTAssertTrue(choices.offersMarks)
    }

    /// TEMCore draws marks only when the panel offered them and they were left on: a file without marks never asks for
    /// them, whatever the checkbox model holds. Red under: `offersMarks` ignored; the scale bar tied to the marks.
    func testMarksAreDrawnOnlyWhenOfferedAndLeftOn() {
        XCTAssertEqual(ExportSnapshot.options(scaleBar: true, marks: true, offersMarks: true),
                       ImageExport.Options(scaleBar: true, marks: true))
        XCTAssertEqual(ExportSnapshot.options(scaleBar: true, marks: false, offersMarks: true),
                       ImageExport.Options(scaleBar: true, marks: false))
        XCTAssertEqual(ExportSnapshot.options(scaleBar: false, marks: true, offersMarks: false),
                       ImageExport.Options(scaleBar: false, marks: false), "nothing to draw, nothing asked for")
        XCTAssertEqual(ExportSnapshot.options(scaleBar: false, marks: true, offersMarks: true),
                       ImageExport.Options(scaleBar: false, marks: true))
    }

    // MARK: - Enabled

    /// Both commands need an image with its pixels, the Image room and no read running; the second also a profile with
    /// samples selected. Red under: the FFT room exporting; the loading condition dropped; the profile command following
    /// the image command alone.
    @MainActor func testTheCommandsAreEnabledOnlyWhereTheyCanAct() {
        func available(hasImage: Bool = true, area: WorkspaceArea = .image, isLoading: Bool = false,
                       profile: Bool = true) -> ExportAvailability {
            ExportSnapshot.availability(hasImage: hasImage, area: area, isLoading: isLoading, profileHasSamples: profile)
        }
        XCTAssertEqual(available(), ExportAvailability(image: true, profile: true))
        XCTAssertEqual(available(profile: false), ExportAvailability(image: true, profile: false))
        XCTAssertEqual(available(hasImage: false), ExportAvailability(image: false, profile: false))
        XCTAssertEqual(available(isLoading: true), ExportAvailability(image: false, profile: false))
        for area in WorkspaceArea.allCases where area != .image {
            XCTAssertEqual(available(area: area), ExportAvailability(image: false, profile: false), "\(area.title)")
        }
        // A window with nothing open exports nothing.
        XCTAssertEqual(ExportSnapshot.availability(of: AppState()), ExportAvailability(image: false, profile: false))
    }

    // MARK: - The image

    /// The display settings go to TEMCore as the shader gets them: the window as fractions of the raw range, the gamma, the
    /// colormap's LUT and name, and the raw window and range for the metadata. The file's own axes, never the shown ones.
    /// 8 × 6 pattern with finite range lo…hi; a window of 20…50 is (20 − lo)/(hi − lo) … (50 − lo)/(hi − lo).
    /// Red under: the window's edges swapped; the gamma not passed; the LUT always gray; the raw range not passed; a metre
    /// axis converted before it is recorded.
    @MainActor func testTheSnapshotCarriesTheDisplayAsTheShaderGetsIt() throws {
        let metres = Self.axis(4.46179e-11, "m")
        let image = Self.image(x: metres, y: metres, notes: ["8-bit render, not counts"])
        let o = owners(image)
        o.presentation.colormap = .viridis
        o.presentation.windowLow = 20
        o.presentation.windowHigh = 50
        o.presentation.gamma = 2.2
        let lo = try XCTUnwrap(image.pixels.min()), hi = try XCTUnwrap(image.pixels.max())
        let snapshot = try imageSnapshot(image, o)

        XCTAssertEqual(snapshot.display.width, 8)
        XCTAssertEqual(snapshot.display.height, 6)
        XCTAssertEqual(snapshot.display.normalized, try XCTUnwrap(o.presentation.canvas).normalized)
        XCTAssertEqual(snapshot.display.low, (20 - lo) / (hi - lo))
        XCTAssertEqual(snapshot.display.high, (50 - lo) / (hi - lo))
        XCTAssertEqual(snapshot.display.gamma, 2.2)
        XCTAssertEqual(snapshot.display.colormap, "viridis")
        XCTAssertEqual(snapshot.display.lut, Colormaps.lutRGBA(.viridis))
        XCTAssertNotEqual(snapshot.display.lut, Colormaps.lutRGBA(.gray), "the control: viridis is not gray")
        XCTAssertEqual(snapshot.display.lut.count, 1024, "256 RGBA texels")
        XCTAssertEqual(snapshot.display.windowLow, 20)
        XCTAssertEqual(snapshot.display.windowHigh, 50)
        XCTAssertEqual(snapshot.display.rawRange, lo...hi)

        // The source names the file as the file states it: a Velox pixel stays in metres.
        XCTAssertEqual(snapshot.source.software, Self.software)
        XCTAssertEqual(snapshot.source.fileName, "scan.dm4")
        XCTAssertEqual(snapshot.source.object, "ImageList.1")
        XCTAssertEqual(snapshot.source.width, 8)
        XCTAssertEqual(snapshot.source.height, 6)
        XCTAssertEqual(snapshot.source.x, metres)
        XCTAssertEqual(snapshot.source.y, metres)
        XCTAssertEqual(snapshot.source.notes, ["8-bit render, not counts"])
        XCTAssertEqual(snapshot.defaultName, "scan")
        XCTAssertEqual(snapshot.message, "Whole image, 8 \u{00D7} 6 px, with the contrast and colormap shown.")
        XCTAssertEqual(snapshot.directory?.path, "/data/run1")
    }

    /// A window with no settings is the full range; a file with no pixels in the canvas has no snapshot. Red under: a
    /// canvas of another size accepted (TEMCore would trap on it).
    @MainActor func testWithoutAWindowTheFullRangeAndWithoutAMatchingCanvasNoSnapshot() throws {
        let image = Self.image()
        let o = owners(image)
        let snapshot = try imageSnapshot(image, o)
        XCTAssertEqual(snapshot.display.low, 0)
        XCTAssertEqual(snapshot.display.high, 1)
        XCTAssertEqual(snapshot.display.gamma, 1)
        XCTAssertEqual(snapshot.display.colormap, "gray")
        XCTAssertNil(snapshot.display.windowLow)
        XCTAssertNil(snapshot.display.windowHigh)

        let nothing = ImagePresentation()
        XCTAssertNil(ExportSnapshot.imageSnapshot(image: image, url: nil, presentation: nothing,
                                                  measurements: ImageMeasurements(), software: Self.software),
                     "no canvas, no snapshot")
        let other = owners(Self.image(width: 5, height: 4))
        XCTAssertNil(ExportSnapshot.imageSnapshot(image: image, url: nil, presentation: other.presentation,
                                                  measurements: ImageMeasurements(), software: Self.software),
                     "a canvas of another size is not this image's")
    }

    // MARK: - The marks

    /// The marks' labels are `MarkFormat`'s in en_US_POSIX, not the reader's locale: a de_DE user still gets "5 nm · 7.81 px"
    /// in the figure. 6 columns × 0.5 nm and 5 rows × 0.8 nm are (3, 4) nm = 5 nm, and √61 = 7.8102 px. The control below
    /// shows the literal separates the two locales on any Mac. The process locale cannot be changed from inside a test, and
    /// this Mac's own writes a comma (en_US with the German region, measured 2026-10-13), so the mutation "labels made in
    /// the reader's locale" is red here; on a Mac whose locale already writes a point only the constant's check would be.
    /// Red under: the labels made in the reader's locale; the locale constant changed to en_US (the identifier check).
    @MainActor func testTheMarksAreLabelledInPOSIXWhateverTheReadersLocale() throws {
        let image = Self.image()
        let o = owners(image)
        let distance = ImageMark(kind: .distance, points: [ImagePoint(x: 0, y: 0), ImagePoint(x: 6, y: 5)])
        o.measurements.add(distance, on: image)
        let snapshot = try imageSnapshot(image, o)
        XCTAssertEqual(snapshot.marks.map(\.label), ["5 nm \u{00B7} 7.81 px"])
        XCTAssertEqual(MarkFormat.value(distance, x: image.x, y: image.y, locale: Self.german), "5 nm \u{00B7} 7,81 px",
                       "the control: the same mark in de_DE reads with a comma")
        XCTAssertEqual(ExportSnapshot.labelLocale.identifier, "en_US_POSIX")
    }

    /// Each kind, its points, its width: only a profile has one (a distance made with a width of 7 exports 1), an angle keeps
    /// its three points with the vertex in the middle, and the order is the list's. 5 columns of 0.5 nm are 2.5 nm.
    /// Red under: an angle mapped to a distance; the width passed through for every kind (and, here, the labels made in
    /// the reader's locale).
    @MainActor func testEachMarkKeepsItsKindPointsAndOnlyAProfilesWidth() throws {
        let image = Self.image()
        let o = owners(image)
        let a = ImagePoint(x: 1, y: 1), b = ImagePoint(x: 6, y: 1), c = ImagePoint(x: 3, y: 4)
        o.measurements.add(ImageMark(kind: .distance, points: [a, b], width: 7), on: image)
        o.measurements.add(ImageMark(kind: .angle, points: [a, c, b]), on: image)
        o.measurements.add(ImageMark(kind: .profile, points: [a, b], width: 4), on: image)
        let marks = try imageSnapshot(image, o).marks
        XCTAssertEqual(marks.map(\.kind), [.distance, .angle, .profile])
        XCTAssertEqual(marks.map(\.points), [[a, b], [a, c, b], [a, b]])
        XCTAssertEqual(marks.map(\.width), [1, 1, 4])
        XCTAssertEqual(marks[0].label, "2.5 nm \u{00B7} 5 px")
        XCTAssertEqual(marks[2].label, "Profile \u{00B7} 2.5 nm")
    }

    // MARK: - The profile

    /// A profile after its width changed equals `LineProfile.sample` on the current image at the new width: the snapshot
    /// reads the owner's recomputed profile, and the ends are the mark's. The control: the width changed the numbers.
    /// Red under: the snapshot sampling at a fixed width 1; the ends swapped.
    @MainActor func testAProfileAfterItsWidthChangedEqualsLineProfileSampleOnTheCurrentImage() throws {
        let image = Self.image()
        let o = owners(image)
        let start = ImagePoint(x: 0.5, y: 1), end = ImagePoint(x: 6.5, y: 4)
        o.measurements.add(ImageMark(kind: .profile, points: [start, end]), on: image)
        let id = try XCTUnwrap(o.measurements.selection)
        let before = try XCTUnwrap(ExportSnapshot.profileSnapshot(image: image, url: nil, measurements: o.measurements,
                                                                  software: Self.software))
        XCTAssertEqual(before.profile, LineProfile.sample(image, from: start, to: end, width: 1))

        o.measurements.setWidth(id, 5, on: image)
        let after = try XCTUnwrap(ExportSnapshot.profileSnapshot(image: image, url: nil, measurements: o.measurements,
                                                                 software: Self.software))
        XCTAssertEqual(after.profile, LineProfile.sample(image, from: start, to: end, width: 5))
        XCTAssertEqual(after.profile.width, 5)
        XCTAssertNotEqual(after.profile.samples, before.profile.samples, "the control: width 5 is not width 1")
        XCTAssertEqual(after.start, start)
        XCTAssertEqual(after.end, end)
        XCTAssertEqual(after.source.fileName, "scan.dm4")
        XCTAssertEqual(after.defaultName, "scan-profile")
        // hypot(6, 3) + 1 = 7.7 -> 8 samples, 0.5 nm columns and 0.8 nm rows: positions in nm.
        XCTAssertEqual(after.profile.samples.count, 8)
        XCTAssertEqual(after.message,
                       "8 samples \u{00B7} positions in nm, as the file states it \u{00B7} width 5 px")
    }

    /// A profile after an END was dragged equals `LineProfile.sample` on the current image between the new ends: the
    /// snapshot reads the owner's recomputed profile, and the ends it names are the moved ones (the width test above
    /// changes the width only; the CSV's samples and its `start` / `end` lines would otherwise be the drag's first
    /// position). Each end is moved in turn. The control: the moved line has other samples. Red under: `ImageMeasurements.move`
    /// not recomputing the profile (the scratch copy only: TEMSession is not this lane's); the ends not taken from the mark.
    @MainActor func testAProfileAfterAnEndMovedEqualsLineProfileSampleOnTheCurrentImage() throws {
        let image = Self.image()
        let o = owners(image)
        let start = ImagePoint(x: 0.5, y: 1), end = ImagePoint(x: 6.5, y: 4)
        o.measurements.add(ImageMark(kind: .profile, points: [start, end], width: 2), on: image)
        let id = try XCTUnwrap(o.measurements.selection)
        func snapshot() throws -> ExportProfileSnapshot {
            try XCTUnwrap(ExportSnapshot.profileSnapshot(image: image, url: nil, measurements: o.measurements,
                                                         software: Self.software))
        }
        let before = try snapshot()
        XCTAssertEqual(before.profile, LineProfile.sample(image, from: start, to: end, width: 2))

        let movedEnd = ImagePoint(x: 3.5, y: 5)
        o.measurements.move(id, point: 1, to: movedEnd, on: image)
        let afterEnd = try snapshot()
        XCTAssertEqual(afterEnd.profile, LineProfile.sample(image, from: start, to: movedEnd, width: 2))
        XCTAssertEqual(afterEnd.start, start)
        XCTAssertEqual(afterEnd.end, movedEnd)
        XCTAssertNotEqual(afterEnd.profile.samples, before.profile.samples, "the control: the other end gives other samples")

        let movedStart = ImagePoint(x: 2, y: 0.5)
        o.measurements.move(id, point: 0, to: movedStart, on: image)
        let afterStart = try snapshot()
        XCTAssertEqual(afterStart.profile, LineProfile.sample(image, from: movedStart, to: movedEnd, width: 2))
        XCTAssertEqual(afterStart.start, movedStart)
        XCTAssertEqual(afterStart.end, movedEnd)
        XCTAssertNotEqual(afterStart.profile.samples, afterEnd.profile.samples)
    }

    /// Only a selected profile with samples exports: nothing selected, a distance selected, and a line with no samples
    /// (a line over the profile sample cap, on a 2^24-pixel-wide image) give no snapshot; with several profiles the N-th one selected is named
    /// "-profile-N". Red under: the selection ignored (the first profile taken); an empty profile accepted; the numbering
    /// counting every mark rather than the profiles.
    @MainActor func testOnlyASelectedProfileWithSamplesExports() throws {
        let image = Self.image()
        let o = owners(image)
        func snapshot() -> ExportProfileSnapshot? {
            ExportSnapshot.profileSnapshot(image: image, url: nil, measurements: o.measurements, software: Self.software)
        }
        XCTAssertNil(snapshot(), "nothing selected")

        let distance = ImageMark(kind: .distance, points: [ImagePoint(x: 0, y: 0), ImagePoint(x: 5, y: 0)])
        o.measurements.add(distance, on: image)
        XCTAssertNil(snapshot(), "a distance is selected")

        let first = ImageMark(kind: .profile, points: [ImagePoint(x: 0, y: 1), ImagePoint(x: 4, y: 1)])
        let second = ImageMark(kind: .profile, points: [ImagePoint(x: 1, y: 2), ImagePoint(x: 6, y: 5)])
        o.measurements.add(first, on: image)
        XCTAssertEqual(snapshot()?.defaultName, "scan-profile", "one profile in the file (the distance is not one): no number")
        o.measurements.add(second, on: image)
        XCTAssertEqual(snapshot()?.defaultName, "scan-profile-2")
        XCTAssertEqual(snapshot()?.start, second.points[0])
        o.measurements.selection = first.id
        XCTAssertEqual(snapshot()?.defaultName, "scan-profile-1")
        XCTAssertEqual(snapshot()?.end, first.points[1])
        XCTAssertEqual(ExportSnapshot.selectedProfile(in: o.measurements)?.count, 2)

        // A profile with no samples. The owner clamps every point onto the image, so a coordinate of 2e15
        // is no longer reachable through `add`; the state the owner CAN hold is a line longer than LineProfile's cap of
        // 2^24 samples, which only a 2^24-pixel-wide image has: its full row is 2^24 pixels long, one over the cap.
        let wide = Self.image(width: 1 << 24, height: 1)
        let wideOwner = ImageMeasurements()
        let empty = ImageMark(kind: .profile, points: [ImagePoint(x: -0.5, y: 0), ImagePoint(x: Double(1 << 24) - 0.5, y: 0)])
        wideOwner.add(empty, on: wide)
        XCTAssertEqual(wideOwner.marks.first?.points, empty.points, "setup: the clamp leaves the full row as drawn")
        XCTAssertEqual(wideOwner.profiles[empty.id]?.samples.count, 0, "setup: a line over the sample cap has none")
        XCTAssertNil(ExportSnapshot.profileSnapshot(image: wide, url: nil, measurements: wideOwner, software: Self.software),
                     "a profile with no samples is not exported")
        XCTAssertNil(ExportSnapshot.selectedProfile(in: wideOwner))
    }

    /// The unit the app shows positions in, named only when it differs from the file's: a Velox metre pixel (4.46179e-11 m)
    /// is shown in nm, × 1e9; an SEM pixel (2e-6 m) in µm, × 1e6; a file already in nm, an uncalibrated one and a profile in
    /// pixels name none. Red under: the factor 1; a nm file reporting a "shown" line.
    @MainActor func testTheShownUnitIsNamedOnlyWhenItDiffersFromTheFiles() throws {
        func shown(_ axis: AxisCalibration?) throws -> (unit: String, factor: Double)? {
            let image = Self.image(width: 16, height: 4, x: axis, y: axis)
            let o = owners(image)
            o.measurements.add(ImageMark(kind: .profile, points: [ImagePoint(x: 0, y: 1), ImagePoint(x: 10, y: 1)]), on: image)
            return try XCTUnwrap(ExportSnapshot.profileSnapshot(image: image, url: nil, measurements: o.measurements,
                                                                software: Self.software)).shown
        }
        let velox = try XCTUnwrap(shown(Self.axis(4.46179e-11, "m")))
        XCTAssertEqual(velox.unit, "nm")
        XCTAssertEqual(velox.factor, 1e9)
        let sem = try XCTUnwrap(shown(Self.axis(2e-6, "m")))
        XCTAssertEqual(sem.unit, "\u{00B5}m")
        XCTAssertEqual(sem.factor, 1e6)
        XCTAssertNil(try shown(Self.axis(0.5, "nm")), "the file's unit is the shown one")
        XCTAssertNil(try shown(nil), "not calibrated: pixels")
    }

    /// The CSV panel's words for a Velox profile: the unit AS THE FILE STATES IT, though the app shows nm. 10 columns of
    /// 4.46179e-11 m, hypot(10, 0) + 1 = 11 samples; and in pixels for an uncalibrated file.
    /// Red under: the shown unit written as the file's.
    @MainActor func testTheProfileMessageStatesTheFilesUnit() throws {
        func message(_ axis: AxisCalibration?) throws -> String {
            let image = Self.image(width: 16, height: 4, x: axis, y: axis)
            let o = owners(image)
            o.measurements.add(ImageMark(kind: .profile, points: [ImagePoint(x: 0, y: 1), ImagePoint(x: 10, y: 1)]), on: image)
            return try XCTUnwrap(ExportSnapshot.profileSnapshot(image: image, url: nil, measurements: o.measurements,
                                                                software: Self.software)).message
        }
        XCTAssertEqual(try message(Self.axis(4.46179e-11, "m")),
                       "11 samples \u{00B7} positions in m, as the file states it \u{00B7} width 1 px")
        XCTAssertEqual(try message(nil), "11 samples \u{00B7} positions in px \u{00B7} width 1 px")
    }

    // MARK: - The shown unit

    /// `shownPositions` for every unit rule `MarkFormat.shown` has: a metre axis in nm below 1 µm, in µm below 1 mm, in mm
    /// above, with the LARGER pixel as the reference (so two pixels either side of a boundary agree on one unit); other
    /// units pass through spelled by `displayLabel` (a different spelling is named, the same one is not). And the relation
    /// the CSV's one line promises: the file's positions times the named factor are the chart's positions, bit for bit, in
    /// the chart's unit. Each case is a literal worked out by hand: 0.9 µm and 1.1 µm pixels are µm (the larger is
    /// 1.1e-6 m, ≥ 1e-6), 5e-10 m and 9e-10 m are nm (both below 1e-6).
    /// Red under: the reference taken from x alone (or y alone); the "same spelling" test dropped (an "A" file reporting no
    /// unit); the factor of mm wrong (reported as 1).
    @MainActor func testTheShownLineIsTheChartsUnitAndFactorForEveryUnitTheAppConverts() throws {
        struct Case {
            let x: AxisCalibration?, y: AxisCalibration?
            let unit: String?, factor: Double
            let note: String
        }
        let cases: [Case] = [
            Case(x: Self.axis(4.46179e-11, "m"), y: Self.axis(4.46179e-11, "m"), unit: "nm", factor: 1e9, note: "Velox"),
            Case(x: Self.axis(2e-6, "m"), y: Self.axis(2e-6, "m"), unit: "\u{00B5}m", factor: 1e6, note: "SEM µm"),
            Case(x: Self.axis(2e-3, "m"), y: Self.axis(2e-3, "m"), unit: "mm", factor: 1e3, note: "mm"),
            Case(x: Self.axis(0.9e-6, "m"), y: Self.axis(1.1e-6, "m"), unit: "\u{00B5}m", factor: 1e6,
                 note: "the reference is the larger pixel (y)"),
            Case(x: Self.axis(1.1e-6, "m"), y: Self.axis(0.9e-6, "m"), unit: "\u{00B5}m", factor: 1e6,
                 note: "the reference is the larger pixel (x)"),
            Case(x: Self.axis(5e-10, "m"), y: Self.axis(9e-10, "m"), unit: "nm", factor: 1e9, note: "both below 1 µm"),
            Case(x: Self.axis(0.5, "nm"), y: Self.axis(0.8, "nm"), unit: nil, factor: 1, note: "a nm file: nothing to say"),
            Case(x: Self.axis(0.1, "A"), y: Self.axis(0.1, "A"), unit: "\u{00C5}", factor: 1, note: "an A file is shown as Å"),
            Case(x: Self.axis(0.1, "angstrom"), y: Self.axis(0.1, "angstrom"), unit: "\u{00C5}", factor: 1, note: "angstrom"),
            Case(x: Self.axis(2, "1/nm"), y: Self.axis(2, "1/nm"), unit: "nm\u{207B}\u{00B9}", factor: 1, note: "reciprocal"),
            Case(x: Self.axis(0.5, "um"), y: Self.axis(0.5, "um"), unit: nil, factor: 1, note: "an unrecognised spelling is shown as written"),
            Case(x: Self.axis(0.5, "nm"), y: Self.axis(0.8, "\u{00B5}m"), unit: nil, factor: 1, note: "two units: pixels"),
            Case(x: nil, y: nil, unit: nil, factor: 1, note: "not calibrated: pixels"),
        ]
        for c in cases {
            let image = Self.image(width: 16, height: 4, x: c.x, y: c.y)
            let measurements = ImageMeasurements()
            measurements.add(ImageMark(kind: .profile, points: [ImagePoint(x: 0, y: 1), ImagePoint(x: 10, y: 1)]), on: image)
            let snapshot = try XCTUnwrap(ExportSnapshot.profileSnapshot(image: image, url: nil, measurements: measurements,
                                                                        software: Self.software), c.note)
            XCTAssertEqual(snapshot.shown?.unit, c.unit, c.note)
            if c.unit != nil { XCTAssertEqual(snapshot.shown?.factor, c.factor, c.note) }
            // The chart's positions, in the chart's unit.
            let chart = MarkFormat.chartPositions(snapshot.profile, x: c.x, y: c.y)
            let factor = snapshot.shown?.factor ?? 1
            XCTAssertEqual(chart.positions.map(\.bitPattern), snapshot.profile.positions.map { ($0 * factor).bitPattern }, c.note)
            if let unit = snapshot.shown?.unit { XCTAssertEqual(chart.unit, unit, c.note) }
        }
    }

    /// Whatever `shown` says, the CSV's position column is the profile's own Double, in the file's unit: the shown factor is
    /// named in one header line and never applied to the numbers, for any factor and not only the Velox 1e9. A 16 × 4
    /// image of 0.5 × 0.8 nm pixels, a width-4 profile from (1, 1) to (9, 2).
    /// Red under: the positions multiplied by the shown factor for any factor but 1e9 (an SEM or mm file).
    @MainActor func testEveryShownFactorLeavesThePositionsInTheFilesUnit() throws {
        let image = Self.image(width: 16, height: 4)
        let start = ImagePoint(x: 1, y: 1), end = ImagePoint(x: 9, y: 2)
        let profile = LineProfile.sample(image, from: start, to: end, width: 4)
        XCTAssertEqual(profile.width, 4, "setup")
        for factor in [1e9, 1e6, 1e3, 1.0, 0.5] {
            let text = try XCTUnwrap(ProfileCSV.text(profile, start: start, end: end,
                                                     source: ExportSource(image: image, software: Self.software),
                                                     shown: (unit: "u", factor: factor)))
            let rows = text.components(separatedBy: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }.dropFirst()
                .map { $0.components(separatedBy: ",") }
            XCTAssertEqual(rows.compactMap { Double($0[0])?.bitPattern }, profile.positions.map(\.bitPattern), "factor \(factor)")
            XCTAssertTrue(text.contains("\n# shown in macTEM as: u (x \(factor))\n"), "factor \(factor)")
        }
    }

    // MARK: - The selected item

    /// Two files are open: the snapshot is of the one selected, with its own pixels, marks and folder, and selecting the
    /// other changes it. Nothing of the first leaks into the second. Red under: the first item taken whatever is
    /// selected.
    @MainActor func testTheSnapshotIsOfTheSelectedItemAndNothingElse() async throws {
        let a = URL(fileURLWithPath: "/data/one/a.dm4"), b = URL(fileURLWithPath: "/data/two/b.dm4")
        let items = OpenItems(identify: { FileIdentity(path: $0.path) }, reader: { request in
            Self.opened(request.url)
        })
        items.open(urls: [a, b])
        await items.settled()
        let itemA = try XCTUnwrap(items.items.first { $0.url == a })
        let itemB = try XCTUnwrap(items.items.first { $0.url == b })
        let imageA = try XCTUnwrap(itemA.session.image)
        itemA.measurements.add(ImageMark(kind: .distance, points: [ImagePoint(x: 0, y: 0), ImagePoint(x: 6, y: 5)]), on: imageA)
        itemA.measurements.add(ImageMark(kind: .profile, points: [ImagePoint(x: 0, y: 1), ImagePoint(x: 6, y: 1)]), on: imageA)

        XCTAssertEqual(items.selected?.url, a, "setup: the first file of a batch is selected")
        let first = try XCTUnwrap(ExportSnapshot.imageSnapshot(in: items, software: Self.software))
        XCTAssertEqual(first.source.fileName, "a.dm4")
        XCTAssertEqual(first.display.width, 8)
        XCTAssertEqual(first.marks.count, 2)
        XCTAssertEqual(first.defaultName, "a")
        XCTAssertEqual(first.directory?.path, "/data/one")
        XCTAssertTrue(first.defaults.offersMarks)
        XCTAssertEqual(ExportSnapshot.profileSnapshot(in: items, software: Self.software)?.source.fileName, "a.dm4")

        items.select(itemB.id)
        let second = try XCTUnwrap(ExportSnapshot.imageSnapshot(in: items, software: Self.software))
        XCTAssertEqual(second.source.fileName, "b.dm4")
        XCTAssertEqual(second.display.width, 5)
        XCTAssertEqual(second.display.height, 4)
        XCTAssertTrue(second.marks.isEmpty, "a's marks are not b's")
        XCTAssertEqual(second.defaultName, "b")
        XCTAssertEqual(second.directory?.path, "/data/two")
        XCTAssertFalse(second.defaults.offersMarks)
        XCTAssertNil(second.source.x, "b is not calibrated")
        XCTAssertNil(ExportSnapshot.profileSnapshot(in: items, software: Self.software), "b has no profile; a's is not offered")

        items.select(itemA.id)
        XCTAssertEqual(ExportSnapshot.imageSnapshot(in: items, software: Self.software)?.marks.count, 2)
        XCTAssertNil(ExportSnapshot.imageSnapshot(in: OpenItems(reader: { Self.opened($0.url) }), software: Self.software),
                     "no file open, no snapshot")
    }

    /// The reader a test passes: "a.dm4" is 8 × 6 and calibrated, anything else 5 × 4 and not.
    nonisolated private static func opened(_ url: URL) -> OpenedImage {
        let isA = url.lastPathComponent == "a.dm4"
        let image = isA ? Self.image(fileName: "a.dm4") : Self.image(width: 5, height: 4, x: nil, y: nil, fileName: "b.dm4")
        return OpenedImage(image: image, canvas: AppState.canvas(for: image), metadata: AcquisitionMetadata(), url: url,
                           thumbnail: nil, bookmark: nil)
    }

    // MARK: - A re-read file

    /// A file that goes cold and is read again after it changed on disk exports the profile of the pixels now on screen,
    /// never the one measured on the first read; while it is cold nothing exports. Two files, a width-3 profile on "a", the
    /// byte budget cut to 1 so selecting "b" sends "a" cold, "a" changed (its pixels shifted), selected and restored.
    /// Red under: `OpenItem.publish` not recomputing the file's profiles (`measurements.refresh(on:)`) — on the scratch copy
    /// only, OpenItems.swift is not this lane's.
    @MainActor func testAReReadOfAChangedFileExportsTheProfileOfTheNewPixels() async throws {
        let generation = ReaderGeneration()
        let a = URL(fileURLWithPath: "/data/one/a.dm4"), b = URL(fileURLWithPath: "/data/two/b.dm4")
        let items = OpenItems(identify: { FileIdentity(path: $0.path) }, reader: { request in
            let isA = request.url.lastPathComponent == "a.dm4"
            let image = Self.image(fileName: request.url.lastPathComponent, shift: isA ? generation.value : 0)
            return OpenedImage(image: image, canvas: AppState.canvas(for: image), metadata: AcquisitionMetadata(), url: request.url,
                               thumbnail: nil, bookmark: Data([1]))
        })
        items.open(urls: [a, b])
        await items.settled()
        let itemA = try XCTUnwrap(items.items.first { $0.url == a }), itemB = try XCTUnwrap(items.items.first { $0.url == b })
        let first = try XCTUnwrap(itemA.session.image)
        let start = ImagePoint(x: 0.5, y: 1), end = ImagePoint(x: 6.5, y: 4)
        itemA.measurements.add(ImageMark(kind: .profile, points: [start, end], width: 3), on: first)
        let before = try XCTUnwrap(ExportSnapshot.profileSnapshot(in: items, software: Self.software)).profile
        XCTAssertEqual(before, LineProfile.sample(first, from: start, to: end, width: 3))

        items.select(itemB.id)
        items.budgetBytes = 1
        XCTAssertEqual(itemA.residency, .cold, "setup: a went cold")
        generation.bump()                                   // the file changed on disk while a was cold
        items.select(itemA.id)
        XCTAssertNil(ExportSnapshot.profileSnapshot(in: items, software: Self.software), "cold: nothing to export")
        items.restoreSelected()
        await items.settled()
        XCTAssertEqual(itemA.residency, .resident, "setup: a was read again")
        let second = try XCTUnwrap(itemA.session.image)
        XCTAssertNotEqual(second.pixels, first.pixels, "setup: the pixels changed")
        let snapshot = try XCTUnwrap(ExportSnapshot.profileSnapshot(in: items, software: Self.software))
        XCTAssertEqual(snapshot.profile, LineProfile.sample(second, from: start, to: end, width: 3))
        XCTAssertNotEqual(snapshot.profile.samples, before.samples, "the control: the new pixels give other samples")
    }

    // MARK: - What OK writes

    /// A fresh path in the temporary folder for one export, removed after the test.
    private func scratchFile(_ ext: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ExportSnapshotTests-\(UUID().uuidString).\(ext)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// What the panel's OK writes is the snapshot's own mark, profile and unit, read back from the file: the ends in the
    /// order drawn (x column, y row), the width, the shown line of a Velox pixel, the file's own axes, and every row bit for
    /// bit — the whole file equal to `ProfileCSV.text` built from the test's own literals. 16 × 8 pixels of 4.46179e-11 m,
    /// a width-3 profile from (1.5, 2.25) to (12.75, 5).
    /// Red under: the ends swapped in the hand-over; `shown` dropped; the source's axes dropped; another profile handed over.
    @MainActor func testTheProfileSnapshotWritesItsOwnValuesToTheChosenFile() async throws {
        let metres = Self.axis(4.46179e-11, "m")
        let image = CalibratedImage(width: 16, height: 8, pixels: (0..<128).map { Float(($0 * 13) % 50) }, x: metres, y: metres,
                                    fileName: "scan.emd", source: "TIFF", voltage: nil)
        let start = ImagePoint(x: 1.5, y: 2.25), end = ImagePoint(x: 12.75, y: 5)
        let measurements = ImageMeasurements()
        measurements.add(ImageMark(kind: .profile, points: [start, end], width: 3), on: image)
        let snapshot = try XCTUnwrap(ExportSnapshot.profileSnapshot(image: image, url: nil, measurements: measurements,
                                                                    software: Self.software))
        let url = scratchFile("csv")
        try await snapshot.write(to: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\n# start: x=1.5, y=2.25 (image pixels"), "start is the first end drawn")
        XCTAssertTrue(text.contains("\n# end: x=12.75, y=5.0\n"))
        XCTAssertTrue(text.contains("\n# width: 3 px\n"))
        XCTAssertTrue(text.contains("\n# shown in macTEM as: nm (x 1000000000.0)\n"))
        XCTAssertTrue(text.contains("\n# x scale: 4.46179e-11 m per px, origin 0.0 px\n"))
        // The whole file, from the test's OWN inputs: the line drawn, the file's pixels and axes, the software, the shown unit.
        let expected = try XCTUnwrap(ProfileCSV.text(LineProfile.sample(image, from: start, to: end, width: 3),
                                                     start: start, end: end,
                                                     source: ExportSource(image: image, software: Self.software),
                                                     shown: (unit: "nm", factor: 1e9)))
        XCTAssertEqual(text, expected)
        let rows = text.components(separatedBy: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }.dropFirst()
            .map { $0.components(separatedBy: ",") }
        XCTAssertEqual(rows.compactMap { Double($0[0])?.bitPattern }, snapshot.profile.positions.map(\.bitPattern))
        XCTAssertEqual(rows.compactMap { Double($0[1])?.bitPattern }, snapshot.profile.samples.map(\.bitPattern))
    }

    /// The PNG's Description text chunk as a JSON object, found by walking the chunks: tEXt, or iTXt (UTF-8) when the text
    /// is not ASCII. The writer's own chunk checks (CRCs, the order) are pinned in ImageExportRenderTests.
    private static func description(of png: Data) throws -> [String: Any] {
        let bytes = [UInt8](png)
        var i = 8                                                    // after the signature
        while i + 8 <= bytes.count {
            let length = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            let type = String(decoding: bytes[i + 4..<i + 8], as: UTF8.self)
            guard i + 8 + length + 4 <= bytes.count else { break }
            let body = Array(bytes[i + 8..<i + 8 + length])
            if type == "tEXt" || type == "iTXt", let nul = body.firstIndex(of: 0),
               String(decoding: body[..<nul], as: UTF8.self) == "Description" {
                var start = nul + 1
                if type == "iTXt" {
                    start += 2                                       // the compression flag and method
                    for _ in 0..<2 {                                 // the language tag, then the translated keyword
                        while start < body.count, body[start] != 0 { start += 1 }
                        start += 1
                    }
                }
                let json = try JSONSerialization.jsonObject(with: Data(body[start...]))
                return try XCTUnwrap(json as? [String: Any], "the Description is a JSON object")
            }
            i += 8 + length + 4
        }
        throw XCTSkip("no Description chunk")                       // never reached on a valid export: the asserts say so
    }

    /// What the image panel's OK writes: a PNG of the snapshot's file whose Description names that file, its object, its
    /// axes, its colormap and window, and — as the options say — the scale bar and the marks. Two writes with the options
    /// opposite ways round (a swapped or constant pair is red in one of them). 256 × 192 pixels of 0.5 × 0.8 nm, viridis,
    /// a window of 20…50, a 120-column distance (60 nm) and a 60-column profile of width 3 (30 nm).
    /// Red under: the marks dropped in the hand-over; the options ignored (a constant, or the two swapped); the source's
    /// file name or axes not handed over; the colormap or the window not handed over.
    @MainActor func testTheImageSnapshotWritesAPNGThatNamesItsFileObjectScalesAndMarks() async throws {
        let image = Self.image(width: 256, height: 192)
        let o = owners(image)
        o.presentation.colormap = .viridis
        o.presentation.windowLow = 20
        o.presentation.windowHigh = 50
        o.measurements.add(ImageMark(kind: .distance, points: [ImagePoint(x: 10, y: 20), ImagePoint(x: 130, y: 20)]), on: image)
        o.measurements.add(ImageMark(kind: .profile, points: [ImagePoint(x: 10, y: 50), ImagePoint(x: 70, y: 50)], width: 3), on: image)
        let snapshot = try imageSnapshot(image, o)

        // Scale bar asked for, marks not.
        let barUrl = scratchFile("png")
        let barOnly = try await snapshot.write(to: barUrl, options: ImageExport.Options(scaleBar: true, marks: false))
        XCTAssertEqual(try Data(contentsOf: barUrl), barOnly.png, "the file is the rendered PNG")
        XCTAssertEqual(barOnly.width, 256)
        XCTAssertEqual(barOnly.height, 192)
        let bar = try Self.description(of: barOnly.png)
        XCTAssertEqual(bar["file"] as? String, "scan.dm4")
        XCTAssertEqual(bar["object"] as? String, "ImageList.1")
        XCTAssertEqual(bar["software"] as? String, Self.software)
        XCTAssertEqual(bar["width"] as? Int, 256)
        XCTAssertEqual(bar["height"] as? Int, 192)
        XCTAssertEqual(bar["colormap"] as? String, "viridis")
        XCTAssertEqual((bar["window"] as? [String: Any])?["low"] as? Double, 20)
        XCTAssertEqual((bar["window"] as? [String: Any])?["high"] as? Double, 50)
        let xScale = try XCTUnwrap(bar["x_scale"] as? [String: Any])
        XCTAssertEqual(xScale["scale"] as? Double, 0.5)
        XCTAssertEqual(xScale["units"] as? String, "nm")
        XCTAssertEqual(xScale["origin"] as? Double, 0)
        let yScale = try XCTUnwrap(bar["y_scale"] as? [String: Any])
        XCTAssertEqual(yScale["scale"] as? Double, 0.8)
        XCTAssertTrue(bar["scale_bar"] is [String: Any], "the scale bar was asked for")
        XCTAssertTrue(bar["marks"] is NSNull, "the marks were not")

        // Marks asked for, scale bar not.
        let marksUrl = scratchFile("png")
        let marksOnly = try await snapshot.write(to: marksUrl, options: ImageExport.Options(scaleBar: false, marks: true))
        XCTAssertEqual(try Data(contentsOf: marksUrl), marksOnly.png)
        let drawn = try Self.description(of: marksOnly.png)
        XCTAssertTrue(drawn["scale_bar"] is NSNull, "the scale bar was not asked for")
        let marks = try XCTUnwrap(drawn["marks"] as? [[String: Any]])
        XCTAssertEqual(marks.map { $0["kind"] as? String }, ["distance", "profile"])
        XCTAssertEqual(marks.map { $0["width"] as? Int }, [1, 3])
        XCTAssertEqual(marks.map { $0["label"] as? String }, ["60 nm \u{00B7} 120 px", "Profile \u{00B7} 30 nm"])
        let points = try XCTUnwrap(marks[0]["points"] as? [[String: String]])
        XCTAssertEqual(points, [["x": "10.0", "y": "20.0"], ["x": "130.0", "y": "20.0"]])
    }

    // MARK: - The panels

    /// The PNG panel: the content type supplies the extension (the name field holds the bare stem), the extension is shown,
    /// the verb is Export, the sheet opens in the image's folder with the message, and the accessory is there. Red under:
    /// an extension typed into the name; the folder dropped; the extension hidden; the accessory dropped.
    @MainActor func testTheImagePanelIsNamedAndPlacedAsTheDesignSays() throws {
        let image = Self.image()
        let o = owners(image)
        o.measurements.add(ImageMark(kind: .distance, points: [ImagePoint(x: 0, y: 0), ImagePoint(x: 3, y: 2)]), on: image)
        let snapshot = try imageSnapshot(image, o)
        let panel = ExportPanels.imagePanel(for: snapshot, choices: ExportImageChoices(snapshot.defaults))
        XCTAssertEqual(panel.allowedContentTypes, [.png])
        XCTAssertEqual(panel.nameFieldStringValue, "scan")
        XCTAssertEqual(panel.nameFieldLabel, "Export As:")
        XCTAssertEqual(panel.prompt, "Export")
        XCTAssertEqual(panel.message, "Whole image, 8 \u{00D7} 6 px, with the contrast and colormap shown.")
        XCTAssertEqual(panel.directoryURL?.path, "/data/run1")
        XCTAssertFalse(panel.isExtensionHidden)
        XCTAssertTrue(panel.canCreateDirectories)
        XCTAssertNotNil(panel.accessoryView)
    }

    /// The CSV panel: no accessory, `commaSeparatedText` supplies ".csv", the name is the profile's bare stem. Red under:
    /// an accessory on the CSV panel; the PNG type.
    @MainActor func testTheProfilePanelHasNoAccessoryAndTheCSVType() throws {
        let image = Self.image()
        let o = owners(image)
        o.measurements.add(ImageMark(kind: .profile, points: [ImagePoint(x: 0, y: 1), ImagePoint(x: 6, y: 1)], width: 3), on: image)
        let snapshot = try XCTUnwrap(ExportSnapshot.profileSnapshot(image: image, url: URL(fileURLWithPath: "/data/run1/scan.dm4"),
                                                                    measurements: o.measurements, software: Self.software))
        let panel = ExportPanels.profilePanel(for: snapshot)
        XCTAssertEqual(panel.allowedContentTypes, [.commaSeparatedText])
        XCTAssertEqual(panel.allowedContentTypes.first?.preferredFilenameExtension, "csv")
        XCTAssertEqual(panel.nameFieldStringValue, "scan-profile")
        XCTAssertEqual(panel.nameFieldLabel, "Export As:")
        XCTAssertEqual(panel.prompt, "Export")
        XCTAssertEqual(panel.message, "7 samples \u{00B7} positions in nm, as the file states it \u{00B7} width 3 px")
        XCTAssertEqual(panel.directoryURL?.path, "/data/run1")
        XCTAssertNil(panel.accessoryView)
    }

    /// The accessory takes its size once, from its content: the frame is the hosting view's fitting size, positive, and
    /// without Marks it is narrower and not shorter. Red under: the frame left empty; Marks always drawn.
    @MainActor func testTheAccessoryTakesItsSizeFromItsContent() {
        let both = ExportPanels.accessory(for: ExportImageChoices(scaleBar: true, marks: true, offersMarks: true))
        let one = ExportPanels.accessory(for: ExportImageChoices(scaleBar: true, marks: true, offersMarks: false))
        XCTAssertGreaterThan(both.frame.width, 0)
        XCTAssertGreaterThan(both.frame.height, 0)
        XCTAssertEqual(both.frame.size, both.fittingSize)
        XCTAssertEqual(one.frame.size, one.fittingSize)
        XCTAssertLessThan(one.frame.width, both.frame.width, "Marks is omitted, not dimmed")
        XCTAssertEqual(one.frame.height, both.frame.height, "the height is the checkboxes' either way")
    }

    /// A window closed under its sheet cancels the sheet: AppKit takes the sheet away with the window and never calls the
    /// completion handler, so without the observer the await never returns (measured on `close`). A test
    /// window, a real PNG panel as its sheet, the window closed; the await returns `.cancel` within three seconds.
    /// Red under: the willClose observer not registered (the response stays nil, and the test cancels the panel itself so
    /// nothing is left suspended).
    @MainActor func testAWindowClosedUnderTheSheetCancelsIt() async throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 320), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        let panel = ExportPanels.savePanel(type: .png, name: "scan", directory: nil, message: "")
        var response: NSApplication.ModalResponse?
        let sheet = Task.immediate { response = await ExportPanels.present(panel, on: window) }
        XCTAssertNotNil(window.attachedSheet, "setup: the sheet is on the window at once")

        window.close()
        // A hang is endless, so any bound tells it from the answer; the answer takes the sheet's closing animation (0.30 s,
        // measured three times on this Mac), so the bound is 3 s and not a tight one a loaded Mac could miss.
        var waited = 0
        while response == nil, waited < 300 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        let ended = response
        if ended == nil { panel.cancel(nil) }
        await sheet.value
        XCTAssertEqual(ended, .cancel, "a window closed under its sheet is a cancel, within three seconds")
    }

    /// The sheet's other end is the ordinary one: what the user chose comes back as it is (OK is OK), so the closing
    /// observer changes nothing for a sheet that ends the usual way. Red under: the helper answering `.cancel` whatever ended
    /// the sheet.
    @MainActor func testTheSheetReturnsWhatTheUserChose() async throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 320), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        let panel = ExportPanels.savePanel(type: .png, name: "scan", directory: nil, message: "")
        var response: NSApplication.ModalResponse?
        let sheet = Task.immediate { response = await ExportPanels.present(panel, on: window) }
        XCTAssertNotNil(window.attachedSheet, "setup: the sheet is on the window at once")
        window.endSheet(panel, returnCode: .OK)
        await sheet.value
        XCTAssertEqual(response, .OK)
        XCTAssertNil(window.attachedSheet)
    }

    /// The line VoiceOver is given is the infobar's own words at high priority: the line is posted as the sheet goes away,
    /// while VoiceOver speaks the focus returning to the window. Red under: the priority left at the default.
    @MainActor func testTheAnnouncementIsTheInfobarsLineAtHighPriority() {
        let line = ExportSnapshot.imageDoneLine(name: "tiny.png", width: 100, height: 80, barLeftOut: true)
        let spoken = ExportPanels.announcement(line)
        XCTAssertEqual(String(spoken.characters), line)
        XCTAssertEqual(spoken.accessibilitySpeechAnnouncementPriority, .high)
    }
}
