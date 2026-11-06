//
//  SEMEDSParityTests.swift
//  TEMCore's SEM-EDS window path (`SEMEDSLines`, the port of exspy 0.3.2's `get_lines_intensity`, `estimate_background_windows`,
//  `quantification_cliff_lorimer` and `weight_to_atomic`) against the committed bundles of tools/parity/sem on the BAM TM002 spectrum:
//  `m7/eds-lines-tm002` (figure F16: the lines exspy picks, the integration and background windows, the raw and background-subtracted
//  intensities), `m7/eds-quant-tm002` (figure F17: Cliff-Lorimer weight and atomic percent with unit and planted k-factors, the take-off
//  angle, each line's FWHM, the default background windows, a 2.1-FWHM window, the lines at 5, 20 and 30 kV) and `m7/eds-xray-database`
//  (the X-ray line table, exact). Tolerances are the bundles' (float64 reductions rtol 1e-7, docs/parity.md).
//  Red before the port: no `SEMEDSLines`. Red after a change to the channel rounding, the window merge or the Cliff-Lorimer chain:
//  the intensities move by whole channels' counts and the composition by percent.
//

import TEMCore
import XCTest

nonisolated final class SEMEDSParityTests: XCTestCase {

    private func tm002(_ ref: SEMParityReference) throws -> (HyperSpySpectrumFile.Spectrum, SEMEDSLines.Axis) {
        let url = try XCTUnwrap(ref.inputURL(), "the bundle names the TM002 fixture")
        let spectrum = try HyperSpySpectrumFile.read(path: url.path)
        XCTAssertEqual(spectrum.units, "keV")
        return (spectrum, SEMEDSLines.Axis(offsetKeV: spectrum.offset, scaleKeV: spectrum.scale, size: spectrum.counts.count))
    }

    // MARK: - The database

    func testXrayLineDatabaseIsExspys() throws {
        let ref = try SEMParityReference.load("m7/eds-xray-database")
        let elements = XrayLineDatabase.elements
        XCTAssertEqual(elements.map(\.symbol), ref.values["elements"] as? [String])
        XCTAssertEqual(elements.flatMap { e in e.lines.map { "\(e.symbol)_\($0.name)" } }, ref.values["xray_lines"] as? [String])
        SEMAssertParity(elements.map { Double($0.z) }, try ref.array("z"))
        SEMAssertParity(elements.map(\.atomicWeight), try ref.array("atomic_weight"))
        SEMAssertParity(elements.flatMap { $0.lines.map(\.energyKeV) }, try ref.array("line_energy_keV"))
        SEMAssertParity(elements.flatMap { $0.lines.map(\.weight) }, try ref.array("line_weight"))
        XCTAssertEqual(XrayLineDatabase.line("Mn_La")?.energyKeV, 0.63316)
        XCTAssertNil(XrayLineDatabase.line("Mn_Xa"))
        XCTAssertEqual(XrayLineDatabase.element("Li")?.lines, [], "exspy lists Li without X-ray lines")
    }

    // MARK: - The conditions the file states

    func testTM002ConditionsAreTheFilesAndTheTakeOffAngleIsExspys() throws {
        let ref = try SEMParityReference.load("m7/eds-quant-tm002")
        let (spectrum, _) = try tm002(ref)
        XCTAssertTrue(spectrum.isSEM)
        let c = spectrum.conditions
        XCTAssertEqual(c.beamEnergyKeV, 10.0)
        XCTAssertEqual(c.energyResolutionMnKaEV, 130.0)
        XCTAssertEqual(c.elevationAngleDeg, 37.0)
        XCTAssertEqual(c.azimuthAngleDeg, 0.0)
        XCTAssertEqual(c.tiltAlphaDeg, 0.0)
        XCTAssertEqual(c.tiltBetaDeg, 0.0)
        XCTAssertEqual(try XCTUnwrap(c.liveTimeS), 19.997292, accuracy: 1e-12)
        SEMAssertParity(c.takeOffAngleDeg, ref, scalar: "take_off_angle_deg")
        // exspy's docstring: 20° of stage tilt adds 20° to the take-off angle of this geometry.
        XCTAssertEqual(SEMEDSLines.takeOffAngle(tiltStage: 20, azimuth: 0, elevation: 37), 57.0, accuracy: 1e-9)
    }

    // MARK: - Figure F16

    func testFigureF16LinesWindowsAndIntensitiesMatchExspy() throws {
        let ref = try SEMParityReference.load("m7/eds-lines-tm002")
        let (spectrum, axis) = try tm002(ref)
        let resolution = spectrum.conditions.energyResolutionMnKaEV
        let lines = SEMEDSLines.lines(forElements: spectrum.elements, axis: axis, beamEnergyKeV: spectrum.conditions.beamEnergyKeV)
        XCTAssertEqual(lines, ref.values["xray_lines"] as? [String])
        let energies = try XCTUnwrap(ref.values["line_energies_keV"] as? [String: Double])
        for line in lines { XCTAssertEqual(SEMEDSLines.energy(line), energies[line], line) }

        let integration = try SEMEDSLines.integrationWindows(lines, width: 2.0, resolutionMnKaEV: resolution)
        SEMAssertParity(integration.flatMap { $0 }, try ref.array("integration_windows_keV"), shape: [lines.count, 2])
        let background = try SEMEDSLines.backgroundWindows(lines, lineWidth: (5.0, 2.0), resolutionMnKaEV: resolution)
        SEMAssertParity(background.flatMap { $0 }, try ref.array("background_windows_keV"), shape: [lines.count, 4])

        let raw = try SEMEDSLines.intensities(counts: spectrum.counts, axis: axis, integrationWindows: integration)
        SEMAssertParity(raw, try ref.array("intensity_raw"))
        let net = try SEMEDSLines.intensities(counts: spectrum.counts, axis: axis, integrationWindows: integration, backgroundWindows: background)
        SEMAssertParity(net, try ref.array("intensity_background_subtracted"))

        // The one call the EDS room makes gives the same numbers.
        let table = try SEMEDSLines.table(counts: spectrum.counts, axis: axis, elements: spectrum.elements, conditions: spectrum.conditions)
        XCTAssertEqual(table.map(\.line), lines)
        SEMAssertParity(table.map(\.rawIntensity), try ref.array("intensity_raw"))
        SEMAssertParity(table.map(\.intensity), try ref.array("intensity_background_subtracted"))
    }

    // MARK: - Figure F17 and the rest of the window path

    func testFigureF17CliffLorimerMatchesExspy() throws {
        let ref = try SEMParityReference.load("m7/eds-quant-tm002")
        let (spectrum, axis) = try tm002(ref)
        let table = try SEMEDSLines.table(counts: spectrum.counts, axis: axis, elements: spectrum.elements, conditions: spectrum.conditions)
        XCTAssertEqual(table.map(\.line), ref.values["xray_lines"] as? [String])
        SEMAssertParity(table.map(\.fwhmKeV), try ref.array("line_fwhm_keV"))

        let planted = try XCTUnwrap(ref.values["kfactors_planted"] as? [Double])
        for (name, k) in [("unit", [Double](repeating: 1, count: table.count)), ("planted", planted)] {
            let composition = try SEMEDSLines.quantify(table, kFactors: k)
            SEMAssertParity(composition.map(\.weightPercent), try ref.array("weight_percent_\(name)"))
            SEMAssertParity(composition.map(\.atomicPercent), try ref.array("atomic_percent_\(name)"))
            XCTAssertEqual(composition.map(\.weightPercent).reduce(0, +), 100, accuracy: 1e-9, name)
        }
    }

    func testDefaultBackgroundWindowsAndAWiderWindowMatchExspy() throws {
        let ref = try SEMParityReference.load("m7/eds-quant-tm002")
        let (spectrum, axis) = try tm002(ref)
        let resolution = spectrum.conditions.energyResolutionMnKaEV
        let lines = try XCTUnwrap(ref.values["xray_lines"] as? [String])
        let integration = try SEMEDSLines.integrationWindows(lines, resolutionMnKaEV: resolution)
        let background = try SEMEDSLines.backgroundWindows(lines, resolutionMnKaEV: resolution)
        SEMAssertParity(background.flatMap { $0 }, try ref.array("background_windows_default_keV"), shape: [lines.count, 4])
        let net = try SEMEDSLines.intensities(counts: spectrum.counts, axis: axis, integrationWindows: integration, backgroundWindows: background)
        SEMAssertParity(net, try ref.array("intensity_background_default"))
        let wider = try SEMEDSLines.integrationWindows(lines, width: 2.1, resolutionMnKaEV: resolution)
        let raw = try SEMEDSLines.intensities(counts: spectrum.counts, axis: axis, integrationWindows: wider)
        SEMAssertParity(raw, try ref.array("intensity_raw_width_2_1"))
    }

    func testLinesFollowTheBeamEnergyAsExspyPicksThem() throws {
        let ref = try SEMParityReference.load("m7/eds-quant-tm002")
        let (spectrum, axis) = try tm002(ref)
        let byBeam = try XCTUnwrap(ref.values["xray_lines_by_beam_energy"] as? [String: [String]])
        XCTAssertEqual(byBeam.count, 3)
        for (kv, expected) in byBeam {
            let beam = try XCTUnwrap(Double(kv))
            XCTAssertEqual(SEMEDSLines.lines(forElements: spectrum.elements, axis: axis, beamEnergyKeV: beam), expected, "\(kv) kV")
        }
    }

    // MARK: - Rules the bundles do not reach

    /// HyperSpy's channel rule: half a channel rounds towards zero for a non-negative energy, away from zero for a negative one; off the
    /// axis there is no channel.
    func testChannelRoundingIsHyperSpys() {
        let axis = SEMEDSLines.Axis(offsetKeV: -0.1, scaleKeV: 0.01, size: 1024)
        XCTAssertEqual(SEMEDSLines.index(of: -0.1, axis: axis), 0)
        XCTAssertEqual(SEMEDSLines.index(of: 0.0, axis: axis), 10)
        XCTAssertEqual(SEMEDSLines.index(of: 0.105, axis: axis), 20, "20.5 rounds towards zero")
        XCTAssertEqual(SEMEDSLines.index(of: 0.106, axis: axis), 21)
        XCTAssertEqual(SEMEDSLines.index(of: -0.045, axis: axis), 6, "5.5 at a negative energy rounds away from zero")
        XCTAssertNil(SEMEDSLines.index(of: -0.2, axis: axis))
        XCTAssertNil(SEMEDSLines.index(of: 10.5, axis: axis))
        XCTAssertEqual(try SEMEDSLines.channels(from: -0.5, to: 0.0, axis: axis), 0 ..< 10, "a start below the axis starts at 0")
        XCTAssertEqual(try SEMEDSLines.channels(from: 10.0, to: 20.0, axis: axis), 1010 ..< 1024, "a stop above the axis runs to the end")
        XCTAssertThrowsError(try SEMEDSLines.channels(from: 11.0, to: 12.0, axis: axis))
    }

    /// exspy's floor: a line at or below 0.1 counts never serves as the reference; one line above it is the whole composition.
    func testCliffLorimerFloorAndSingleLine() throws {
        XCTAssertEqual(try SEMEDSLines.cliffLorimer(intensities: [0.05, 200, 0], kFactors: [1, 1, 1]), [0, 1, 0])
        XCTAssertEqual(try SEMEDSLines.cliffLorimer(intensities: [0, 0], kFactors: [1, 1]), [0, 0])
        let two = try SEMEDSLines.cliffLorimer(intensities: [100, 300], kFactors: [1, 1])
        XCTAssertEqual(two[0], 0.25, accuracy: 1e-15)
        XCTAssertEqual(two[1], 0.75, accuracy: 1e-15)
        XCTAssertThrowsError(try SEMEDSLines.cliffLorimer(intensities: [1, 2], kFactors: [1]))
        XCTAssertEqual(try SEMEDSLines.weightToAtomic(weightPercent: [0, 0], elements: ["Cu", "Sn"]), [0, 0])
    }

    /// exspy's own docstring examples on this spectrum (`get_lines_intensity`): Mn La with the default window, and Mn Ka with
    /// background windows when Mn is the only element.
    func testExspyDocstringIntensities() throws {
        let ref = try SEMParityReference.load("m7/eds-lines-tm002")
        let (spectrum, axis) = try tm002(ref)
        let resolution = spectrum.conditions.energyResolutionMnKaEV
        let la = try SEMEDSLines.intensities(counts: spectrum.counts, axis: axis,
                                             integrationWindows: SEMEDSLines.integrationWindows(["Mn_La"], resolutionMnKaEV: resolution))
        XCTAssertEqual(la, [96700])
        let ka = ["Mn_Ka"]
        let ka21 = try SEMEDSLines.intensities(counts: spectrum.counts, axis: axis,
                                               integrationWindows: SEMEDSLines.integrationWindows(ka, width: 2.1, resolutionMnKaEV: resolution))
        XCTAssertEqual(ka21, [53597])
        let net = try SEMEDSLines.intensities(counts: spectrum.counts, axis: axis,
                                              integrationWindows: SEMEDSLines.integrationWindows(ka, resolutionMnKaEV: resolution),
                                              backgroundWindows: SEMEDSLines.backgroundWindows(ka, resolutionMnKaEV: resolution))
        XCTAssertEqual(net, [46716])
    }
}
