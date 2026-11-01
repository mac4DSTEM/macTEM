//
//  ImageOpeningTests.swift
//  Pins `ImageOpening` and the value it returns: the object rule (the first object, in file order,
//  that is not the thumbnail, has exactly two dimensions larger than one and whose axes do not carry two different
//  units), the two refusals by name (an unknown
//  extension; a file with no 2D image, whose message lists what the file holds), `calibratedImage(_:fileName:)`
//  carrying origin, scale and units unchanged with a missing axis staying nil, `CalibratedImage.hasSquarePixels`
//  (exact, units included), and `AxisCalibration.value(at:)` = (i − origin) · scale.
//  Files are built in memory (DM4TestFile): DM4ImageObject and DM4Image have no package initialiser.
//

import ShellLayout
import ImagoCore
import XCTest
import TEMCore
import FormatoDM

nonisolated final class ImageOpeningTests: XCTestCase {

    private typealias Axis = DM4TestFile.Axis
    private static let nm = Axis(origin: 0, scale: 0.5, units: "nm")

    /// An RGBA thumbnail (8 × 6), a [170, 1] line scan, a [16, 2, 3] stack: nothing here is an image.
    private static let notImages: [DM4TestFile.Node] = [
        DM4TestFile.object(name: "Image Of run", dims: [8, 6], axes: [nm, nm], rgba: true),
        DM4TestFile.object(name: "Line scan", dims: [170, 1], axes: [nm, nm]),
        DM4TestFile.object(name: "Stack", dims: [16, 2, 3], axes: [nm, nm, nm]),
    ]

    // MARK: The object rule

    func testTheFirstNonThumbnailObjectWithExactlyTwoDimensionsOverOneIsChosen() throws {
        let data = DM4TestFile.file(Self.notImages + [
            DM4TestFile.object(name: "HAADF", dims: [5, 4, 1], axes: [Self.nm, Self.nm, Self.nm]),  // singleton dropped
            DM4TestFile.object(name: "BF", dims: [6, 3], axes: [Self.nm, Self.nm]),
        ])
        let objects = try DM4Experiment.list(data: data)
        XCTAssertEqual(objects.map(\.index), [1, 2, 3, 4, 5])
        XCTAssertEqual(objects[0].role, .thumbnail, "the RGBA object is the thumbnail (data type 23)")
        XCTAssertEqual(ImageOpening.primaryImageObject(in: objects)?.index, 4,
                       "not the 2D thumbnail, not [170, 1], not [16, 2, 3]; [5, 4, 1] before the later [6, 3]")
    }

    func testAThumbnailNamedByTheRootListIsSkippedWhateverItsDataType() throws {
        // Object 1 is int16, not RGBA: only the root `Thumbnails` list says it is the thumbnail.
        let data = DM4TestFile.file([
            DM4TestFile.object(name: "preview", dims: [8, 6], axes: [Self.nm, Self.nm]),
            DM4TestFile.object(name: "BF", dims: [6, 3], axes: [Self.nm, Self.nm]),
        ], extraRoot: [DM4TestFile.thumbnailList(0)])
        let objects = try DM4Experiment.list(data: data)
        XCTAssertEqual(objects.map(\.role), [.thumbnail, .unknown])
        XCTAssertEqual(ImageOpening.primaryImageObject(in: objects)?.index, 2)
    }

    func testNoObjectIsChosenWhenNoneIsATwoDimensionalImage() throws {
        let data = DM4TestFile.file(Self.notImages + [
            DM4TestFile.object(name: "4D", dims: [2, 2, 2, 3], axes: [Self.nm, Self.nm, Self.nm, Self.nm]),
        ])
        XCTAssertNil(ImageOpening.primaryImageObject(in: try DM4Experiment.list(data: data)))
        XCTAssertNil(ImageOpening.primaryImageObject(in: []))
    }

    func testOpeningAFileReadsTheChosenObject() throws {
        let pixels: [Int16] = [-3, 7, 11, -20, 0, 32767]
        let path = try DM4TestFile.write(DM4TestFile.file(Self.notImages + [
            DM4TestFile.object(name: "HAADF", dims: [3, 2], axes: [Self.nm, Self.nm], pixels: pixels),
        ]), named: "multi.dm4", for: self)
        let image = try ImageOpening.openNow(path: path)
        XCTAssertEqual([image.width, image.height], [3, 2])
        XCTAssertEqual(image.pixels, pixels.map(Float.init))
        XCTAssertEqual(image.source, "ImageList.4 · HAADF")
        XCTAssertEqual(image.fileName, "multi.dm4")
    }

    /// A 2D object whose axes are in different units is a spectrum image (here a CL line scan: wavelength in
    /// nm along x, position in µm along y), not a specimen image; the image after it is chosen.
    func testATwoDimensionalObjectWhoseAxesCarryDifferentUnitsIsSkipped() throws {
        let wavelength = Axis(origin: -8680, scale: 0.0934, units: "nm")
        let position = Axis(origin: 0, scale: 0.0206, units: "\u{00B5}m")
        let data = DM4TestFile.file([
            DM4TestFile.object(name: "Image Of run", dims: [8, 6], axes: [Self.nm, Self.nm], rgba: true),
            DM4TestFile.object(name: "CL spectrum image", dims: [6, 3], axes: [wavelength, position]),
            DM4TestFile.object(name: "BF", dims: [4, 2], axes: [Self.nm, Self.nm]),
        ])
        XCTAssertEqual(ImageOpening.primaryImageObject(in: try DM4Experiment.list(data: data))?.index, 3)

        let path = try DM4TestFile.write(DM4TestFile.file([
            DM4TestFile.object(name: "CL spectrum image", dims: [6, 3], axes: [wavelength, position]),
        ]), named: "cl.dm4", for: self)
        XCTAssertThrowsError(try ImageOpening.openNow(path: path)) { error in
            XCTAssertEqual(error as? ImageOpening.Refusal,
                           .noImage(file: "cl.dm4", objects: "6 × 3 in nm and \u{00B5}m"))
        }
    }

    /// `object` with `ImageTags.Meta Data.Format` = `format` (DM4TestFile.object writes no Meta Data group).
    private static func withFormat(_ format: String, _ object: DM4TestFile.Node) -> DM4TestFile.Node {
        guard case .group(let label, let kids) = object else { preconditionFailure("not an object") }
        return .group(label, kids.map { kid in
            guard case .group("ImageTags", let tags) = kid else { return kid }
            return .group("ImageTags", tags + [.group("Meta Data", [.text("Format", format)])])
        })
    }

    /// Format tag, case 1: both axes in nm, so only the Format tag names it a spectrum image: refused, and the message
    /// says what the object is.
    func testAnObjectTaggedSpectrumImageIsRefusedWhateverItsUnits() throws {
        let si = Self.withFormat("Spectrum image", DM4TestFile.object(name: "SI", dims: [6, 3], axes: [Self.nm, Self.nm]))
        let thumb = DM4TestFile.object(name: "Image Of run", dims: [8, 6], axes: [Self.nm, Self.nm], rgba: true)
        let objects = try DM4Experiment.list(data: DM4TestFile.file([thumb, si]))
        XCTAssertEqual(objects[1].metaDataFormat, "Spectrum image")
        XCTAssertNil(ImageOpening.primaryImageObject(in: objects))
        let path = try DM4TestFile.write(DM4TestFile.file([thumb, si]), named: "si.dm4", for: self)
        XCTAssertThrowsError(try ImageOpening.openNow(path: path)) { error in
            XCTAssertEqual(error as? ImageOpening.Refusal,
                           .noImage(file: "si.dm4", objects: "thumbnail 8 × 6; 6 × 3 spectrum image"))
        }
    }

    /// Format tag, case 2: the tagged spectrum image first, then an image tagged "Image": the second is opened.
    func testTheImageAfterATaggedSpectrumImageIsOpened() throws {
        let pixels: [Int16] = [4, -5, 6, 7]
        let path = try DM4TestFile.write(DM4TestFile.file([
            DM4TestFile.object(name: "Image Of run", dims: [8, 6], axes: [Self.nm, Self.nm], rgba: true),
            Self.withFormat("Spectrum image", DM4TestFile.object(name: "SI", dims: [6, 3], axes: [Self.nm, Self.nm])),
            Self.withFormat("Image", DM4TestFile.object(name: "BF", dims: [2, 2], axes: [Self.nm, Self.nm], pixels: pixels)),
        ]), named: "si-image.dm4", for: self)
        let image = try ImageOpening.openNow(path: path)
        XCTAssertEqual(image.source, "ImageList.3 · BF")
        XCTAssertEqual([image.width, image.height], [2, 2])
        XCTAssertEqual(image.pixels, pixels.map(Float.init))
        XCTAssertEqual(image.x?.unit, "nm")
    }

    /// Format tag, case 3: only the exact Format "Spectrum image" is skipped.
    func testOtherFormatsOpen() throws {
        for format in ["Diffraction image", "Image", "Spectrum image ", "spectrum image"] {
            let path = try DM4TestFile.write(DM4TestFile.file([
                Self.withFormat(format, DM4TestFile.object(name: "DP", dims: [3, 2], axes: [Self.nm, Self.nm])),
            ]), named: "other.dm4", for: self)
            XCTAssertEqual(try ImageOpening.openNow(path: path).source, "ImageList.1 · DP", "Format '\(format)'")
        }
    }

    /// An axis without a unit is uncalibrated, not in a different unit: such an object is still an image.
    func testAnAxisWithNoUnitDoesNotMakeTheUnitsDifferent() throws {
        let unitless = Axis(origin: 0, scale: 1, units: "")
        let data = DM4TestFile.file([
            DM4TestFile.object(name: "half", dims: [6, 3], axes: [Self.nm, unitless]),
            DM4TestFile.object(name: "none", dims: [4, 2], axes: [unitless, unitless]),
        ])
        XCTAssertEqual(ImageOpening.primaryImageObject(in: try DM4Experiment.list(data: data))?.index, 1)
    }

    // MARK: Refusals

    func testAnUnknownExtensionIsRefusedByNameNotByPath() {
        func refusal(_ path: String) -> ImageOpening.Refusal? {
            do { _ = try ImageOpening.openNow(path: path); return nil }
            catch { return error as? ImageOpening.Refusal }
        }
        let ser = refusal("/Volumes/Lab Disk/run 7/scan.SER")
        XCTAssertEqual(ser, .unreadableFormat(file: "scan.SER", ext: "ser"))
        XCTAssertEqual(ser?.errorDescription,
                       "scan.SER is a .ser file. macTEM opens .dm4, .dm3, .tif, .mrc and Velox .emd images; other formats are not read yet.")
        XCTAssertFalse(ser?.errorDescription?.contains("Lab Disk") ?? true, "the message never shows the folders")
        let bare = refusal("/tmp/README")
        XCTAssertEqual(bare, .unreadableFormat(file: "README", ext: ""))
        XCTAssertEqual(bare?.errorDescription,
                       "README is a file without an extension. macTEM opens .dm4, .dm3, .tif, .mrc and Velox .emd images; other formats are not read yet.")
        // Upper-case DM and TIFF extensions are readable: a missing file is a read error, not a format refusal.
        for path in ["/nonexistent-\(UUID().uuidString)/IMAGE.DM4", "/nonexistent-\(UUID().uuidString)/old.Dm3"] {
            XCTAssertThrowsError(try ImageOpening.openNow(path: path)) { error in
                XCTAssertNil(error as? ImageOpening.Refusal, "\(path): \(error)")
                guard case DM4Error.cannotOpen = error else { return XCTFail("\(path): \(error)") }
            }
        }
        for path in ["/nonexistent-\(UUID().uuidString)/scan.TIF", "/nonexistent-\(UUID().uuidString)/scan.tiff",
                     "/nonexistent-\(UUID().uuidString)/map.MRC"] {
            XCTAssertThrowsError(try ImageOpening.openNow(path: path)) { error in
                XCTAssertNil(error as? ImageOpening.Refusal, "\(path): \(error)")
                XCTAssertEqual((error as? CocoaError)?.code, .fileReadNoSuchFile, "\(path): \(error)")
            }
        }
    }

    func testAFileWithNoTwoDimensionalImageIsRefusedWithWhatItHolds() throws {
        let path = try DM4TestFile.write(DM4TestFile.file(Self.notImages), named: "nothing.dm4", for: self)
        XCTAssertThrowsError(try ImageOpening.openNow(path: path)) { error in
            let expected = ImageOpening.Refusal.noImage(file: "nothing.dm4", objects: "thumbnail 8 × 6; 170 × 1; 16 × 2 × 3")
            XCTAssertEqual(error as? ImageOpening.Refusal, expected)
            XCTAssertEqual((error as? LocalizedError)?.errorDescription,
                           "nothing.dm4 holds no 2D image (thumbnail 8 × 6; 170 × 1; 16 × 2 × 3). Image stacks and spectrum images are not read yet.")
        }
        let empty = try DM4TestFile.write(DM4TestFile.file([]), named: "empty.dm4", for: self)
        XCTAssertThrowsError(try ImageOpening.openNow(path: empty)) { error in
            XCTAssertEqual(error as? ImageOpening.Refusal, .noImage(file: "empty.dm4", objects: "no image objects"))
        }
    }

    // MARK: The calibrated image

    func testTheCalibratedImageCarriesOriginScaleAndUnitsUnchanged() throws {
        let x = Axis(origin: 12, scale: 0.0123, units: "nm")
        let y = Axis(origin: -4.5, scale: 0.0246, units: "\u{00B5}m")   // µm, MICRO SIGN, as GMS writes it
        let data = DM4TestFile.file([
            DM4TestFile.object(name: "HAADF", dims: [3, 2], axes: [x, y], pixels: [1, 2, 3, 4, 5, 6], voltage: 300_000),
        ])
        let dm = try DM4Experiment.readImage(data: data, index: 1)
        let image = ImageOpening.calibratedImage(dm, fileName: "f.dm4")
        XCTAssertEqual(image.x, AxisCalibration(scale: Double(Float(0.0123)), unit: "nm", origin: 12))
        XCTAssertEqual(image.y, AxisCalibration(scale: Double(Float(0.0246)), unit: "\u{00B5}m", origin: -4.5))
        XCTAssertEqual(image.y?.unit.unicodeScalars.map(\.value), [0xB5, 0x6D], "the unit string is not normalised")
        XCTAssertEqual(image.x?.origin, dm.xAxis?.origin)
        XCTAssertEqual(image.x?.scale, dm.xAxis?.scale)
        XCTAssertEqual(image.y?.scale, dm.yAxis?.scale)
        XCTAssertEqual([image.width, image.height], [3, 2])
        XCTAssertEqual(image.pixels, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(image.fileName, "f.dm4")
        XCTAssertEqual(image.source, "ImageList.1 · HAADF")
        XCTAssertEqual(image.voltage, 300_000)
    }

    func testAnUncalibratedAxisStaysNilAndAnUnnamedObjectIsNamedByItsIndex() throws {
        let data = DM4TestFile.file([
            DM4TestFile.object(name: nil, dims: [8, 6], axes: [Self.nm, Self.nm], rgba: true),
            DM4TestFile.object(name: nil, dims: [3, 2], axes: nil),
        ])
        let dm = try DM4Experiment.readImage(data: data, index: 2)
        XCTAssertNil(dm.xAxis)
        let image = ImageOpening.calibratedImage(dm, fileName: "g.dm4")
        XCTAssertNil(image.x)
        XCTAssertNil(image.y)
        XCTAssertNil(image.hasSquarePixels)
        XCTAssertNil(image.voltage)
        XCTAssertEqual(image.source, "ImageList.2", "no name, no separator")
    }

    func testSquarePixelsCompareScaleAndUnitsExactly() {
        func image(_ x: AxisCalibration?, _ y: AxisCalibration?) -> CalibratedImage {
            CalibratedImage(width: 1, height: 1, pixels: [0], x: x, y: y, fileName: "a.dm4", source: "s", voltage: nil)
        }
        let a = AxisCalibration(scale: 0.25, unit: "nm", origin: 0)
        XCTAssertEqual(image(a, AxisCalibration(scale: 0.25, unit: "nm", origin: 7)).hasSquarePixels, true,
                       "origins may differ")
        XCTAssertEqual(image(a, AxisCalibration(scale: 0.25.nextUp, unit: "nm", origin: 0)).hasSquarePixels, false,
                       "exact: one ulp is not square")
        XCTAssertEqual(image(a, AxisCalibration(scale: 0.25, unit: "Å", origin: 0)).hasSquarePixels, false,
                       "0.25 nm and 0.25 Å are not the same sampling")
        XCTAssertNil(image(a, nil).hasSquarePixels)
        XCTAssertNil(image(nil, a).hasSquarePixels)
        XCTAssertNil(image(nil, nil).hasSquarePixels)
    }

    /// One definition of a physical sampling (`AxisCalibration.isCalibrated`), shared by the scale bar and the inspector:
    /// a unit and a finite, positive scale. GMS writes scale 1 with no unit for an uncalibrated image.
    func testAnAxisIsCalibratedOnlyWithAUnitAndAPositiveFiniteScale() {
        XCTAssertTrue(AxisCalibration(scale: 0.0123, unit: "nm", origin: 0).isCalibrated)
        XCTAssertFalse(AxisCalibration(scale: 1, unit: "", origin: 0).isCalibrated, "GMS's uncalibrated axis")
        XCTAssertFalse(AxisCalibration(scale: -0.0123, unit: "nm", origin: 0).isCalibrated, "a length per pixel is positive")
        XCTAssertFalse(AxisCalibration(scale: 0, unit: "nm", origin: 0).isCalibrated)
        XCTAssertFalse(AxisCalibration(scale: .nan, unit: "nm", origin: 0).isCalibrated)
        XCTAssertFalse(AxisCalibration(scale: .infinity, unit: "nm", origin: 0).isCalibrated)
        let unitless = AxisCalibration(scale: 1, unit: "", origin: 0)
        let image = CalibratedImage(width: 1, height: 1, pixels: [0], x: unitless, y: unitless,
                                    fileName: "a.dm4", source: "s", voltage: nil)
        XCTAssertNil(image.hasSquarePixels, "two uncalibrated axes are not square pixels; they are no pixels at all")
    }

    func testAnAxisValueIsTheIndexMinusTheOriginTimesTheScale() {
        let x = AxisCalibration(scale: 0.5, unit: "nm", origin: 12)
        XCTAssertEqual(x.value(at: 12), 0, "the origin is the pixel index of the physical zero")
        XCTAssertEqual(x.value(at: 0), -6)
        XCTAssertEqual(x.value(at: 13.5), 0.75)
        let y = AxisCalibration(scale: 0.25, unit: "nm", origin: -4.5)
        XCTAssertEqual(y.value(at: 0), 1.125, "a negative origin puts the zero before the first row")
        XCTAssertEqual(y.value(at: -4.5), 0)
        XCTAssertEqual(y.value(at: 23), 6.875)
    }
}
