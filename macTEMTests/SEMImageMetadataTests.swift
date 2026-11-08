//
//  SEMImageMetadataTests.swift
//  The SEM TIFF record (TEMCore/SEM/SEMImageMetadata.swift) against RosettaSciIO 0.15.0 and tifffile (tools/parity/sem's
//  pinned stack): the parity part reads the vendor tag of each of RosettaSciIO's eight SEM test TIFFs (the tag's bytes, held in
//  each `m1/read-sem-tiff-*` bundle that tools/parity/sem/emit.py wrote from the real file, planted into a TIFF of the file's
//  own width and height) and compares every mapped value with that bundle: texts exactly, numbers to 1e-9 relative, axes at
//  RosettaSciIO's rtol 1e-4, nil exactly where the reference has no value. The rules part pins what the reference cannot (a Tescan header, a databar
//  height that disagrees with the image, the Zeiss unit conversion and rounding, the date shapes, Python's text rules) on
//  planted bytes, and the image part the axes and the crop.
//

import XCTest
import ImagoCore
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class SEMImageMetadataTests: XCTestCase {

    // MARK: Parity with RosettaSciIO on its SEM test files

    /// The harness's bundles of RosettaSciIO's eight SEM test TIFFs (tools/parity/sem/emit.py, `m1/read-sem-tiff-*`).
    static let semTIFFCases = ["m1/read-sem-tiff-fei-helios", "m1/read-sem-tiff-fei-helios-16bits", "m1/read-sem-tiff-fei-navcam",
                               "m1/read-sem-tiff-fei-navcam-no-irbeam", "m1/read-sem-tiff-fei-navcam-bad-floats", "m1/read-sem-tiff-zeiss",
                               "m1/read-sem-tiff-zeiss-1k", "m1/read-sem-tiff-zeiss-multipage"]

    func testEveryRosettaSciIOSEMFileReadsAsTheReference() throws {
        for name in Self.semTIFFCases {
            let ref = try SEMParityReference.load(name)
            let image = try XCTUnwrap(ref.values["image"] as? [String: Any], name)
            let tag = try XCTUnwrap(image["tag"] as? Int, name)
            let width = try XCTUnwrap(image["width"] as? Int), height = try XCTUnwrap(image["height"] as? Int)
            let bytes = try ref.array("vendor_tag").values.map { UInt8($0) }
            let got = try XCTUnwrap(SEMImageMetadata.read(data: PlantedSEMTIFF(width: width, height: height, tag: tag, bytes: bytes).build()), name)
            try check(got, against: ref, name)
            // A committed fixture is read whole as well: the record of the file is the record of its planted tag.
            if let url = ref.inputURL(), ref.manifest.inputs[0].path.hasPrefix("fixtures/") {
                let whole = try XCTUnwrap(SEMImageMetadata.read(path: url.path), "\(name): no SEM record from the file")
                try check(whole, against: ref, "\(name) (whole file)")
            }
        }
    }

    private func check(_ got: SEMImageMetadata, against ref: SEMParityReference, _ name: String) throws {
        let image = try XCTUnwrap(ref.values["image"] as? [String: Any], name)
        let vendor = try XCTUnwrap(image["vendor"] as? String, name)
        let height = try XCTUnwrap(image["height"] as? Int, name)
        XCTAssertEqual(got.vendor, vendor == "fei" ? .thermo : .zeiss, name)
        XCTAssertEqual(got.imageWidth, image["width"] as? Int, name)
        XCTAssertEqual(got.imageHeight, height, "\(name) height, the whole frame as RosettaSciIO reads it")

        // The axes RosettaSciIO's vendor branch gives the file (metres, or none).
        let axes = try XCTUnwrap(ref.values["axes"] as? [[String: Any]], name)
        for axis in axes {
            guard let axisName = axis["name"] as? String, ["width", "height"].contains(axisName) else { continue }
            let scale = axisName == "width" ? got.pixelSizeX : got.pixelSizeY
            XCTAssertEqual(axis["size"] as? Int, axisName == "width" ? got.imageWidth : got.imageHeight, "\(name) \(axisName) size")
            if let units = axis["units"] as? String {
                XCTAssertEqual(units, "m", name)
                // RosettaSciIO's own tolerance for the axes (test_tiff.py, `test_read_FEI_navcam_metadata`: rtol 1e-4). Its
                // `_order_axes_by_name` gives the height axis the x scale (HFW / ResolutionX) and the width axis the y scale; on
                // the navcam file (768 x 512 scan, non-square by 2.5e-6) that swap is inside this tolerance, and macTEM keeps
                // each scale on its own axis (docs/parity.md).
                assertClose(scale, axis["scale"] as? Double, "\(name) \(axisName) scale", rtol: 1e-4)
            } else {
                XCTAssertNil(scale, "\(name) \(axisName): RosettaSciIO leaves the file uncalibrated")
            }
        }

        // The mapped metadata (`mapping_fei`, `mapping_cz_sem`, through HyperSpy's load), key by key; a key the reference
        // lacks reads nil (the navcam file's unparseable floats are dropped there, and read nil here).
        let sem = ref.values["sem_metadata"] as? [String: Any] ?? [:]
        let stage = sem["Stage"] as? [String: Any] ?? [:]
        let general = ref.values["general"] as? [String: Any] ?? [:]
        func number(_ v: Any?) -> Double? { (v as? Double) ?? (v as? Int).map(Double.init) }
        XCTAssertFalse(got.rawFields.isEmpty, "\(name): the Vendor fields disclosure lists every key of the tag")
        XCTAssertEqual(got.pixelSizeSource != nil, got.pixelSizeX != nil,
                       "\(name): the Calibration Source row names the vendor field exactly when the file is calibrated")
        assertClose(got.beamEnergyKV, number(sem["beam_energy"]), "\(name) beam energy")
        assertClose(got.workingDistanceMM, number(sem["working_distance"]), "\(name) working distance")
        assertClose(got.dwellS, number(sem["dwell_time"]), "\(name) dwell")
        assertClose(got.beamCurrentNA, number(sem["beam_current"]), "\(name) beam current")
        assertClose(got.stageX, number(stage["x"]), "\(name) stage x")
        assertClose(got.stageY, number(stage["y"]), "\(name) stage y")
        assertClose(got.stageZ, number(stage["z"]), "\(name) stage z")
        assertClose(got.stageRotationDeg, number(stage["rotation"]), "\(name) stage rotation")
        assertClose(got.stageTiltDeg, number(stage["tilt"]), "\(name) stage tilt")
        XCTAssertEqual(got.instrument, sem["microscope"] as? String, "\(name) microscope")
        XCTAssertEqual(got.user, general["authors"] as? String, "\(name) authors")
        XCTAssertEqual(got.date, general["date"] as? String, "\(name) date")
        XCTAssertEqual(got.time, general["time"] as? String, "\(name) time")
        if let magText = sem["magnification"] as? String {
            XCTAssertEqual(got.magnificationText, magText, "\(name) magnification text")
            XCTAssertNil(got.magnification, name)
        } else {
            assertClose(got.magnification, number(sem["magnification"]), "\(name) magnification")
            XCTAssertNil(got.magnificationText, name)
        }
        if vendor == "zeiss" {
            XCTAssertEqual(got.detector, (sem["Detector"] as? [String: Any])?["detector_type"] as? String, "\(name) detector")
            XCTAssertEqual(got.stageUnit, "mm", name)
            XCTAssertNil(got.databarRows, "\(name): a Zeiss file is never cropped")
            let cz = try XCTUnwrap(ref.values["tifffile_cz_sem"] as? [String: Any], name)
            XCTAssertEqual(got.spotSize, number((cz["ap_spotsize"] as? [Any])?[1]), "\(name) spot")
            if let pressure = cz["ap_chamber_pressure"] as? [Any], pressure.count == 3 {
                XCTAssertEqual(pressure[2] as? String, "Pa", name)
                assertClose(got.chamberPressurePa, number(pressure[1]), "\(name) pressure")
            } else {
                XCTAssertNil(got.chamberPressurePa, name)
            }
        } else {
            XCTAssertEqual(got.stageUnit, "m", name)
            let fei = try XCTUnwrap(ref.values["tifffile_fei"] as? [String: Any], name)
            XCTAssertEqual(got.detector, fei["DetectorName"] as? String, "\(name) detector (tifffile's [Detectors] Name)")
            XCTAssertEqual(got.spotSize, number(fei["Spot"]), "\(name) spot ('' reads nil)")
            assertClose(got.chamberPressurePa, number(fei["ChPressure"]), "\(name) chamber pressure ('' reads nil)")
            let bar = try XCTUnwrap(fei["DatabarHeight"] as? Int, name), rows = try XCTUnwrap(fei["ResolutionY"] as? Int, name)
            XCTAssertEqual(rows + bar, height, "\(name): every Helios file's databar plus scan is the image")
            XCTAssertEqual(got.databarRows, bar, "\(name) databar")
            XCTAssertEqual(got.scanRows, rows, name)
        }
    }

    // MARK: Rules on planted bytes

    func testAThermoDatabarThatDoesNotFitTheImageIsNotRecorded() throws {
        let header = "[Image]\r\nResolutionY=442\r\n[PrivateFei]\r\nDatabarHeight=29\r\n"
        let fits = SEMImageMetadata.read(data: PlantedSEMTIFF(width: 8, height: 471, tag: 34682, bytes: Array(header.utf8) + [0]).build())
        XCTAssertEqual(fits?.databarRows, 29)
        let wrongHeight = SEMImageMetadata.read(data: PlantedSEMTIFF(width: 8, height: 470, tag: 34682, bytes: Array(header.utf8) + [0]).build())
        XCTAssertNil(wrongHeight?.databarRows, "442 + 29 is not 470: nothing is cut")
        XCTAssertEqual(wrongHeight?.vendor, .thermo)
        let noResolution = SEMImageMetadata.read(data: PlantedSEMTIFF(width: 8, height: 471, tag: 34682, bytes: Array("[PrivateFei]\r\nDatabarHeight=29\r\n".utf8) + [0]).build())
        XCTAssertNil(noResolution?.databarRows, "without [Image] ResolutionY the height is not checked, so it is not read")
    }

    /// A databar height that is no whole number an Int holds (inf, 1e300) or two heights whose sum overflows Int record no databar,
    /// and the rest of the record reads: each trapped in the conversion to Int (or the sum) before, while the TIFF opened.
    func testADatabarHeightBeyondIntIsNotRecordedAndTheRestReads() throws {
        let thermoRest = "[Beam]\r\nHV=15000\r\n[User]\r\nUser=paul\r\n"
        let thermoCases = [("inf", "29"), ("-inf", "29"), ("1e300", "29"), ("442", "inf"), ("442", "1e300"),
                           ("4611686018427387904", "4611686018427387904")]
        for (resolution, databar) in thermoCases {
            let header = "[Image]\r\nResolutionY=\(resolution)\r\n[PrivateFei]\r\nDatabarHeight=\(databar)\r\n" + thermoRest
            let what = "ResolutionY=\(resolution), DatabarHeight=\(databar)"
            let got = try XCTUnwrap(SEMImageMetadata.read(data: PlantedSEMTIFF(width: 8, height: 471, tag: 34682, bytes: Array(header.utf8) + [0]).build()), what)
            XCTAssertEqual(got.vendor, .thermo, what)
            XCTAssertNil(got.databarRows, what)
            XCTAssertEqual(got.scanRows, 471, "\(what): nothing is cut")
            assertClose(got.beamEnergyKV, 15, "\(what): HV still reads")
            XCTAssertEqual(got.user, "paul", what)
        }
        let fits = "[Image]\r\nResolutionY=442\r\n[PrivateFei]\r\nDatabarHeight=29\r\n" + thermoRest
        XCTAssertEqual(SEMImageMetadata.read(data: PlantedSEMTIFF(width: 8, height: 471, tag: 34682, bytes: Array(fits.utf8) + [0]).build())?.databarRows, 29,
                       "a height that fits reads as before")

        for strip in ["inf", "1e300"] {
            let header = "[MAIN]\r\nDevice=MIRA3 LMU\r\nImageStripSize=\(strip)\r\n[SEM]\r\nHV=15000\r\n"
            let got = try XCTUnwrap(SEMImageMetadata.read(data: PlantedSEMTIFF(width: 8, height: 840, tag: 50431, bytes: Array(header.utf8) + [0]).build()), strip)
            XCTAssertEqual(got.vendor, .tescan, strip)
            XCTAssertNil(got.databarRows, "ImageStripSize=\(strip)")
            XCTAssertEqual(got.scanRows, 840, strip)
            XCTAssertEqual(got.instrument, "MIRA3 LMU", strip)
            assertClose(got.beamEnergyKV, 15, "ImageStripSize=\(strip): HV still reads")
        }
    }

    func testAThermoHeaderReadsTheIRBeamFallbackAndEmptyValuesAsNil() throws {
        // The navcam shape: no [Scan], the field widths over the image resolution; HV and Spot empty.
        let header = "[User]\r\nDate=05/17/2022\r\nTime=09:07:08 AM\r\nUser=user\r\n[Beam]\r\nHV=\r\nSpot=\r\n"
            + "[IRBeam]\r\nHFW=0.202732\r\nVFW=0.135155\r\n[Image]\r\nResolutionX=768\r\nResolutionY=512\r\n"
            + "[Stage]\r\nStageZ=0\r\nWorkingDistance=-1.2e-05\r\n[Vacuum]\r\nChPressure=\r\n"
        let got = try XCTUnwrap(SEMImageMetadata.read(data: PlantedSEMTIFF(width: 768, height: 551, tag: 34682, bytes: Array(header.utf8) + [0]).build()))
        assertClose(got.pixelSizeX, 0.202732 / 768, "HFW / ResolutionX")
        assertClose(got.pixelSizeY, 0.135155 / 512, "VFW / ResolutionY")
        XCTAssertNil(got.beamEnergyKV, "HV= is not recorded, never 0")
        XCTAssertNil(got.spotSize)
        XCTAssertNil(got.chamberPressurePa)
        XCTAssertEqual(got.stageZ, 0, "a stored 0 position is a position")
        assertClose(got.workingDistanceMM, -0.012, "× 1e3, as RosettaSciIO")
        XCTAssertEqual(got.date, "2022-05-17")
        XCTAssertEqual(got.time, "09:07:08")
        XCTAssertNil(got.databarRows, "no DatabarHeight")
    }

    func testAThermoScanPixelWidthThatIsNotANumberLeavesTheFileUncalibrated() throws {
        let header = "[Scan]\r\nPixelWidth=abc\r\nPixelHeight=1e-8\r\n[IRBeam]\r\nHFW=0.2\r\nVFW=0.1\r\n[Image]\r\nResolutionX=8\r\nResolutionY=4\r\n"
        let got = try XCTUnwrap(SEMImageMetadata.read(data: PlantedSEMTIFF(width: 8, height: 4, tag: 34682, bytes: Array(header.utf8) + [0]).build()))
        XCTAssertNil(got.pixelSizeX, "RosettaSciIO's float() raises and the file opens uncalibrated; the IRBeam fallback is for a missing [Scan] only")
        XCTAssertNil(got.pixelSizeY)
    }

    func testATescanHeaderReadsAsNexusLIMSReadsIt() throws {
        let header = "\u{0}\u{0}garbage before\r\n[MAIN]\r\nDevice=MIRA3 LMU\r\nUserName=paul\r\nDate=2026-11-06\r\nTime=12:34:56\r\n"
            + "PixelSizeX=2.5e-08\r\nPixelSizeY=2.5e-08\r\nMagnification=5000\r\nImageStripSize=72\r\n"
            + "[SEM]\r\nHV=15000\r\nWD=0.0098\r\nDetector=SE\r\nDwellTime=3.2e-06\r\nSpotSize=1.1e-08\r\nChamberPressure=0.009\r\n"
            + "StageX=0.001\r\nStageY=0.002\r\nStageZ=0.03\r\nStageRotation=12.5\r\nStageTilt=0\r\nPredictedBeamCurrent=3e-10\r\n"
        // NexusLIMS starts at the first [MAIN]; the bytes before it (NULs included) are not the header. The plant keeps them
        // after the NUL-free marker so the TIFF text survives tifffile's bytes2str rule as well.
        let bytes = Array(header.replacingOccurrences(of: "\u{0}", with: " ").utf8) + [0]
        let got = try XCTUnwrap(SEMImageMetadata.read(data: PlantedSEMTIFF(width: 1024, height: 840, tag: 50431, bytes: bytes).build()))
        XCTAssertEqual(got.vendor, .tescan)
        XCTAssertEqual(got.instrument, "MIRA3 LMU")
        XCTAssertEqual(got.user, "paul")
        XCTAssertEqual(got.date, "2026-11-06")
        XCTAssertEqual(got.time, "12:34:56")
        assertClose(got.pixelSizeX, 2.5e-8, "metres")
        assertClose(got.pixelSizeY, 2.5e-8, "metres")
        XCTAssertEqual(got.magnification, 5000)
        assertClose(got.beamEnergyKV, 15, "V → kV")
        assertClose(got.workingDistanceMM, 9.8, "m → mm")
        XCTAssertEqual(got.detector, "SE")
        assertClose(got.dwellS, 3.2e-6, "seconds as stored")
        assertClose(got.spotSize, 1.1e-8, "metres as stored")
        XCTAssertEqual(got.spotSizeUnit, "m")
        assertClose(got.chamberPressurePa, 0.009, "pascals as stored")
        assertClose(got.beamCurrentNA, 0.3, "A → nA (NexusLIMS: amperes, ×1e12 to pA)")
        XCTAssertEqual(got.stageUnit, "m")
        assertClose(got.stageX, 0.001, "metres as stored")
        assertClose(got.stageRotationDeg, 12.5, "degrees")
        XCTAssertEqual(got.stageTiltDeg, 0)
        XCTAssertEqual(got.databarRows, 72)
        XCTAssertEqual(got.scanRows, 768)
        let tooTall = SEMImageMetadata.read(data: PlantedSEMTIFF(width: 1024, height: 72, tag: 50431, bytes: bytes).build())
        XCTAssertNil(tooTall?.databarRows, "a strip as tall as the image is no strip")
    }

    func testARealTescanTagReadsAsNexusLIMSReadsIt() throws {
        // NexusLIMS's own test file (tescan-pfib_dataZeroed.tif, MIT): tag 50431 opens with a binary thumbnail and has no
        // section headers. tools/parity/sem/sem-image/tescan_reference.py wrote the sections NexusLIMS parses from it.
        let url = try XCTUnwrap(Bundle(for: SEMImageMetadataTests.self).url(forResource: "tescan-reference", withExtension: "json"))
        let ref = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let want = try XCTUnwrap(ref["sections"] as? [String: [String: String]])
        let width = try XCTUnwrap(ref["width"] as? Int), height = try XCTUnwrap(ref["height"] as? Int)
        let bytes = try Self.fixture(try XCTUnwrap(ref["tagBytes"] as? String))
        XCTAssertTrue(bytes.contains(0) && !bytes.starts(with: Array("[MAIN]".utf8)), "the real tag, binary prefix and all")
        let got = try XCTUnwrap(SEMImageMetadata.read(data: PlantedSEMTIFF(width: width, height: height, tag: 50431, bytes: bytes).build()))
        XCTAssertEqual(got.vendor, .tescan)

        var sections: [String: [String: String]] = [:]
        for field in got.rawFields {
            let dot = try XCTUnwrap(field.key.firstIndex(of: "."))
            let name = String(field.key[..<dot]), key = String(field.key[field.key.index(after: dot)...])
            XCTAssertNil(sections[name]?[key], "\(field.key) once")
            sections[name, default: [:]][key] = field.value
        }
        XCTAssertEqual(sections, want, "every section and key exactly as NexusLIMS's configparser reads them")

        // NexusLIMS's field table on those values: V, m, s, Pa, A as stored, converted only for display.
        let sem = want["SEM"]!, main = want["MAIN"]!
        func n(_ s: String?) -> Double? { s.flatMap(Double.init) }
        assertClose(got.beamEnergyKV, n(sem["HV"]).map { $0 * 1e-3 }, "HV V → kV")
        assertClose(got.workingDistanceMM, n(sem["WD"]).map { $0 * 1e3 }, "WD m → mm")
        assertClose(got.beamCurrentNA, n(sem["PredictedBeamCurrent"]).map { $0 * 1e9 }, "PredictedBeamCurrent A → nA")
        assertClose(got.beamCurrentNA, 0.3003, "300.3 pA, as NexusLIMS's own test reads it")
        assertClose(got.spotSize, n(sem["SpotSize"]), "SpotSize m")
        assertClose(got.dwellS, n(sem["DwellTime"]), "DwellTime s")
        assertClose(got.chamberPressurePa, n(sem["ChamberPressure"]), "ChamberPressure Pa")
        assertClose(got.stageX, n(sem["StageX"]), "StageX m")
        assertClose(got.stageY, n(sem["StageY"]), "StageY m")
        assertClose(got.stageZ, n(sem["StageZ"]), "StageZ m")
        assertClose(got.stageRotationDeg, n(sem["StageRotation"]), "StageRotation")
        assertClose(got.stageTiltDeg, n(sem["StageTilt"]), "StageTilt")
        assertClose(got.pixelSizeX, n(main["PixelSizeX"]), "PixelSizeX m")
        assertClose(got.magnification, n(main["Magnification"]), "Magnification")
        XCTAssertEqual(got.detector, sem["Detector"])
        XCTAssertEqual(got.instrument, main["Device"])
        XCTAssertEqual(got.user, main["FullUserName"])
        XCTAssertEqual(got.date, "2025-12-03")
        XCTAssertEqual(got.time, "17:19:26")
        XCTAssertEqual(got.databarRows, 298)
        XCTAssertEqual(got.scanRows, 1280)
        XCTAssertEqual(got.pixelSizeSource, "Tescan PixelSizeX")
    }

    func testATescanHeaderConfigparserRefusesHasNoFields() {
        // NexusLIMS: configparser raises on a repeated key or a line without a delimiter, and the tag then gives nothing.
        XCTAssertNil(SEMImageMetadata.tescanSections(Array("[MAIN]\nDate=1\nDate=2\n".utf8)), "repeated key")
        XCTAssertNil(SEMImageMetadata.tescanSections(Array("[MAIN]\nno delimiter here\n".utf8)), "no delimiter")
        XCTAssertNil(SEMImageMetadata.tescanSections(Array("[MAIN]\nA=1\n[MAIN]\nB=2\n".utf8)), "repeated section")
        XCTAssertNil(SEMImageMetadata.tescanSections(Array("[MAIN]\nA=50%\n".utf8)), "a lone % fails interpolation")
        let ok = SEMImageMetadata.tescanSections(Array("\u{1}\u{2}Date=2025-12-03\r\nDevice=X\r\nHV=15000\r\nWD : 0.005\r\n".utf8))
        XCTAssertEqual(ok?.map(\.0), ["MAIN", "SEM"], "headers added: [MAIN] first, [SEM] at the line of the first SEM key")
        XCTAssertEqual(ok?[0].1.map(\.0), ["Date", "Device"])
        XCTAssertEqual(ok?[1].1.map { "\($0.0)=\($0.1)" }, ["HV=15000", "WD=0.005"], "= or : with spaces stripped")
        let percent = SEMImageMetadata.tescanSections(Array("[MAIN]\nA=50%%\n".utf8))
        XCTAssertEqual(percent?[0].1.first?.1, "50%")
    }

    func testAZeissValueIsConvertedWithItsUnitAndRoundedAsRosettaSciIORoundsIt() {
        // `_parse_tuple_Zeiss_with_units`: pint's conversion, then float("%.6e" % v).
        XCTAssertEqual(SEMImageMetadata.convert(50, from: "ns", to: "s"), 5e-8)
        XCTAssertEqual(SEMImageMetadata.convert(14.808, from: "mm", to: "mm"), 14.808)
        XCTAssertEqual(SEMImageMetadata.convert(1234.5678, from: "µm", to: "mm"), 1.234568, "7 significant digits")
        XCTAssertEqual(SEMImageMetadata.convert(1.0, from: "nA", to: "nA"), 1)
        XCTAssertEqual(SEMImageMetadata.convert(2.5, from: "pA", to: "nA"), 0.0025)
        XCTAssertEqual(SEMImageMetadata.convert(1.87e-6, from: "mbar", to: "Pa"), nil, "mbar is not an SI-prefixed unit here: not read")
        XCTAssertEqual(SEMImageMetadata.convert(3, from: "mm", to: "s"), nil, "a length is not a time")
    }

    func testTheCZSEMParserFollowsTifffile() {
        let text = "0\r\n0\r\n0\r\n2.614514e-006\r\n1.045845e+002\r\nAP_WD\r\nWD = 14.808 mm\r\nAP_MAG\r\nMag = 50.00 K X\r\n"
            + "DP_DETECTOR_TYPE\r\nDetector = HE-SE2\r\nSV_OPERATOR\r\nOperator = \r\nAP_TIME\r\nTime :9:40:32\r\nDP_FROZEN\r\nImage = Frozen\r\nlower\r\n"
        let (unnamed, keyed) = SEMImageMetadata.czSEM(text)
        XCTAssertEqual(unnamed.count, 6, "five numbers before the first key, and a line after the last value that is no key")
        XCTAssertEqual(unnamed[3], 2.614514e-6)
        XCTAssertNil(unnamed[5], "\"lower\" is not a number")
        XCTAssertEqual(keyed["ap_wd"], .init(name: "WD", number: 14.808, text: "14.808", unit: "mm"))
        XCTAssertEqual(keyed["ap_mag"], .init(name: "Mag", number: nil, text: "50.00 K X", unit: nil), "three words: text, as tifffile")
        XCTAssertEqual(keyed["dp_detector_type"], .init(name: "Detector", number: nil, text: "HE-SE2", unit: nil))
        XCTAssertEqual(keyed["sv_operator"], .init(name: "Operator", number: nil, text: "", unit: nil))
        XCTAssertEqual(keyed["ap_time"], .init(name: "Time", number: nil, text: "9:40:32", unit: nil), "a ':' line when there is no '='")
        XCTAssertEqual(keyed["dp_frozen"]?.text, "Frozen")
    }

    func testDatesAndTimesReadAsDateutilReadsThem() {
        XCTAssertEqual(SEMImageMetadata.isoDate("06/13/2016"), "2016-06-13", "month first")
        XCTAssertEqual(SEMImageMetadata.isoDate("13/06/2016"), "2016-06-13", "a first field above 12 is the day")
        XCTAssertEqual(SEMImageMetadata.isoDate("23 Dec 2015"), "2015-12-23")
        XCTAssertEqual(SEMImageMetadata.isoDate("18 Apr 2016"), "2016-04-18")
        XCTAssertEqual(SEMImageMetadata.isoDate("2026-11-06"), "2026-11-06")
        XCTAssertNil(SEMImageMetadata.isoDate("13.06.2016"), "a shape not listed is not guessed")
        XCTAssertNil(SEMImageMetadata.isoDate("00/13/2016"))
        XCTAssertEqual(SEMImageMetadata.isoTime("05:06:40 PM"), "17:06:40")
        XCTAssertEqual(SEMImageMetadata.isoTime("12:00:00 PM"), "12:00:00")
        XCTAssertEqual(SEMImageMetadata.isoTime("12:30:00 AM"), "00:30:00")
        XCTAssertEqual(SEMImageMetadata.isoTime("9:40:32"), "09:40:32")
        XCTAssertEqual(SEMImageMetadata.isoTime("22:42:02"), "22:42:02")
        XCTAssertNil(SEMImageMetadata.isoTime("25:00:00"))
    }

    func testPythonTextRules() {
        XCTAssertEqual(SEMImageMetadata.pythonSplitLines("a\r\nb\rc\nd\u{0B}e\u{85}f\u{2028}g\r\n"), ["a", "b", "c", "d", "e", "f", "g"])
        XCTAssertEqual(SEMImageMetadata.pythonSplitLines("a\n\nb"), ["a", "", "b"])
        XCTAssertTrue(SEMImageMetadata.pythonIsUpper("SV_OPERATOR"))
        XCTAssertTrue(SEMImageMetadata.pythonIsUpper("AP_WD2"))
        XCTAssertFalse(SEMImageMetadata.pythonIsUpper("0"), "no cased character")
        XCTAssertFalse(SEMImageMetadata.pythonIsUpper("WD = 14.8 mm"))
        XCTAssertEqual(SEMImageMetadata.pythonNumber("5000"), 5000)
        XCTAssertEqual(SEMImageMetadata.pythonNumber(" -2.3611 "), -2.3611)
        XCTAssertEqual(SEMImageMetadata.pythonNumber("1e-05"), 1e-5)
        XCTAssertEqual(SEMImageMetadata.pythonNumber("+3"), 3)
        XCTAssertNil(SEMImageMetadata.pythonNumber(""))
        XCTAssertNil(SEMImageMetadata.pythonNumber("ETD"))
        XCTAssertNil(SEMImageMetadata.pythonNumber("1_000"), "Python reads it; a deviation on purpose, named in the file")
        XCTAssertNil(SEMImageMetadata.pythonNumber("0x10"))
        XCTAssertEqual(SEMImageMetadata.pythonNumber("inf"), .infinity)
        XCTAssertEqual(SEMImageMetadata.pythonText(Data([0x41, 0x42, 0, 0x43])), "AB", "up to the first NUL")
        XCTAssertEqual(SEMImageMetadata.pythonText(Data([0xB5, 0x6D])), "µm", "cp1252 when not UTF-8")
    }

    func testATEMTIFFHasNoSEMRecord() {
        XCTAssertNil(SEMImageMetadata.read(data: PlantedSEMTIFF(width: 2, height: 2, tag: nil, bytes: []).build()))
        XCTAssertNil(SEMImageMetadata.read(data: PlantedSEMTIFF(width: 2, height: 2, tag: 34683, bytes: Array("<Metadata/>".utf8) + [0]).build()), "a Velox TIFF")
        XCTAssertNil(SEMImageMetadata.read(data: Data([1, 2, 3])), "not a TIFF: no record, no throw")
    }

    // MARK: The image

    func testTheRecordCalibratesAnUncalibratedImageAndNeverReplacesACalibration() throws {
        var sem = SEMImageMetadata(vendor: .zeiss, imageWidth: 4, imageHeight: 3, stageUnit: "mm")
        sem.pixelSizeX = 2.5e-6
        sem.pixelSizeY = 2.5e-6
        let plain = CalibratedImage(width: 4, height: 3, pixels: Array(repeating: 1, count: 12), x: nil, y: nil, fileName: "z.tif", source: "page 1", voltage: nil)
        let calibrated = sem.calibrated(plain)
        XCTAssertEqual(calibrated.x, AxisCalibration(scale: 2.5e-6, unit: "m"))
        XCTAssertEqual(calibrated.y, AxisCalibration(scale: 2.5e-6, unit: "m"))
        XCTAssertEqual(calibrated.pixels, plain.pixels)
        let own = CalibratedImage(width: 4, height: 3, pixels: plain.pixels, x: AxisCalibration(scale: 1e-9, unit: "m"), y: AxisCalibration(scale: 1e-9, unit: "m"),
                                  fileName: "z.tif", source: "page 1", voltage: nil)
        XCTAssertEqual(sem.calibrated(own), own, "the reader's own calibration stands")
    }

    func testTheCropRemovesTheDatabarRowsOnlyWhenTheyFit() throws {
        var sem = SEMImageMetadata(vendor: .thermo, imageWidth: 3, imageHeight: 4, stageUnit: "m")
        sem.databarRows = 1
        let pixels: [Float] = (0..<12).map(Float.init)
        let image = CalibratedImage(width: 3, height: 4, pixels: pixels, x: nil, y: nil, fileName: "h.tif", source: "page 1", voltage: nil)
        let cropped = sem.cropped(image)
        XCTAssertEqual(cropped.height, 3)
        XCTAssertEqual(cropped.pixels, Array(pixels[0..<9]), "the last row goes")
        XCTAssertEqual(sem.applied(to: image, cropDatabar: false), image)
        let otherSize = CalibratedImage(width: 3, height: 5, pixels: pixels + [0, 0, 0], x: nil, y: nil, fileName: "h.tif", source: "page 1", voltage: nil)
        XCTAssertEqual(sem.cropped(otherSize), otherSize, "a frame of another height is not cut")
        sem.databarRows = nil
        XCTAssertEqual(sem.cropped(image), image)
    }

    func testTheDemoSEMImageOpensCroppedAndCalibratedThroughTheReaders() throws {
        let data = DemoDocuments.semTIFF()
        let image = try TIFFImageReader.read(data: data, fileName: "Demo SEM image.tif")
        XCTAssertEqual(image.height, DemoDocuments.semScanRows + DemoDocuments.semDatabarRows)
        XCTAssertEqual(image.x, AxisCalibration(scale: DemoDocuments.semPixelSizeM, unit: "m"), "FormatoKit reads the xT calibration")
        let sem = try XCTUnwrap(SEMImageMetadata.read(data: data))
        XCTAssertEqual(sem.vendor, .thermo)
        XCTAssertEqual(sem.databarRows, DemoDocuments.semDatabarRows)
        XCTAssertEqual(sem.detector, DemoDocuments.semDetector)
        XCTAssertEqual(sem.beamEnergyKV, DemoDocuments.semHVVolts / 1000)
        XCTAssertEqual(sem.workingDistanceMM, DemoDocuments.semWorkingDistanceM * 1000)
        XCTAssertEqual(sem.instrument, DemoDocuments.semInstrument)
        XCTAssertEqual(sem.date, "2026-11-06")
        XCTAssertEqual(sem.time, "12:00:00")
        let shown = sem.applied(to: image, cropDatabar: true)
        XCTAssertEqual(shown.height, DemoDocuments.semScanRows)
        XCTAssertEqual(shown.x, image.x)
        XCTAssertEqual(sem.applied(to: image, cropDatabar: false).height, image.height)
    }

    // MARK: Helpers

    /// The two SEM TIFFs the parity harness commits (tools/parity/sem/fixtures) read as its bundles `m1/read-sem-tiff-fei-helios`
    /// and `m1/read-sem-tiff-zeiss` state (hyperspy.api.load over RosettaSciIO 0.15.0, D-SEM-16): the whole file through
    /// `SEMImageMetadata.read(path:)`, not only its tag bytes.
    private func assertClose(_ got: Double?, _ want: Double?, _ what: String, rtol: Double = 1e-9,
                             file: StaticString = #filePath, line: UInt = #line) {
        switch (got, want) {
        case (nil, nil): break
        case (let g?, let w?):
            if w == 0 { XCTAssertEqual(g, 0, what, file: file, line: line) }
            else { XCTAssertLessThanOrEqual(abs(g - w) / abs(w), rtol, "\(what): got \(g), reference \(w)", file: file, line: line) }
        default: XCTFail("\(what): got \(String(describing: got)), reference \(String(describing: want))", file: file, line: line)
        }
    }

    static func fixture(_ name: String) throws -> [UInt8] {
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        let url = try XCTUnwrap(Bundle(for: SEMImageMetadataTests.self).url(forResource: stem, withExtension: ext), name)
        return Array(try Data(contentsOf: url))
    }
}

/// A minimal little-endian TIFF of `width` × `height` 8-bit grey pixels (all zero) and, when `tag` is given, that tag as ASCII
/// holding exactly `bytes` (the vendor tag of a real file, or a planted header). Only the tags the SEM reader looks at.
nonisolated struct PlantedSEMTIFF {
    let width: Int
    let height: Int
    let tag: Int?
    let bytes: [UInt8]

    func build() -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        var entries: [(Int, Int, Int, [UInt8])] = [   // code, type, count, payload (inline when ≤ 4 bytes)
            (256, 4, 1, le32(width)), (257, 4, 1, le32(height)), (258, 3, 1, le16(8) + [0, 0]), (259, 3, 1, le16(1) + [0, 0]),
            (262, 3, 1, le16(1) + [0, 0]), (273, 4, 1, []), (277, 3, 1, le16(1) + [0, 0]), (278, 4, 1, le32(height)),
            (279, 4, 1, le32(width * height)),
        ]
        if let tag { entries.append((tag, 2, bytes.count, bytes)) }
        entries.sort { $0.0 < $1.0 }
        let ifdStart = 8, heapStart = ifdStart + 2 + 12 * entries.count + 4
        var heap: [UInt8] = []
        var ifd = le16(entries.count)
        // The pixels sit first in the heap so the strip offset is known before the entries are written.
        let pixelsAt = heapStart
        heap += [UInt8](repeating: 0, count: width * height)
        for (code, type, count, payload) in entries {
            ifd += le16(code) + le16(type) + le32(count)
            if code == 273 {
                ifd += le32(pixelsAt)
            } else if payload.count <= 4 {
                ifd += payload + [UInt8](repeating: 0, count: 4 - payload.count)
            } else {
                if heap.count % 2 == 1 { heap.append(0) }
                ifd += le32(heapStart + heap.count)
                heap += payload
            }
        }
        ifd += le32(0)
        return Data([0x49, 0x49] + le16(42) + le32(ifdStart) + ifd + heap)
    }
}
