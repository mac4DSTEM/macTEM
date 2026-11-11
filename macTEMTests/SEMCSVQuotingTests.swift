//
//  SEMCSVQuotingTests.swift
//  The CSV writers quote a text cell and keep a file or region name on its header line with ImagoKit's `CSVText` (#338): a phase
//  called `Fe "a", bcc` stays one cell of the indexing results CSV and of the Maps room's grains CSV, a verdict holding a carriage
//  return is quoted in the Diffraction readout, and a line break in a file, region or crystal name does not start a line of its own
//  in the Diffraction, Particles and EELS headers. Ordinary names write the bytes they wrote before.
//
//  Red before the change: the phase cell is `"Fe "a", bcc"` (the quote not doubled, so an RFC 4180 reader takes `Fe a, bcc`), the
//  verdict is written bare, and `b.dm4` (or the crystal's `film`) lands on a line of its own without the `#`.
//

import XCTest
import SpectroEELS
import TEMCore
@testable import macTEM

nonisolated final class SEMCSVQuotingTests: XCTestCase {

    /// The cells of one CSV line by RFC 4180: a quoted cell may hold commas, and a doubled quote inside it is one quote.
    private static func cells(_ line: String) -> [String] {
        var out: [String] = []
        var cell = ""
        var quoted = false
        var i = line.startIndex
        while i < line.endIndex {
            let character = line[i]
            let next = line.index(after: i)
            if quoted, character == "\"", next < line.endIndex, line[next] == "\"" {
                cell.append("\"")
                i = line.index(after: next)
                continue
            }
            if character == "\"" {
                quoted.toggle()
            } else if character == ",", !quoted {
                out.append(cell)
                cell = ""
            } else {
                cell.append(character)
            }
            i = next
        }
        out.append(cell)
        return out
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// The indexing results CSV of one Hough point of nickel under `name`: the header line and the point's line.
    private static func indexingCSV(phaseNamed name: String) throws -> (lines: [String], row: IndexingResult.Row) {
        var phase = try XCTUnwrap(IndexingPhase.presets.first { $0.name == "Ni" })
        phase.name = name
        var solution = HoughIndexer.Solution()
        solution.quaternion = SIMD4(1, 0, 0, 0)
        solution.phase = 0
        solution.confidence = 0.5
        solution.fit = 1
        solution.matchedBands = 8
        solution.patternQuality = 10
        var result = IndexingResult(scanRows: 1, scanColumns: 1, phases: [phase])
        result.land([solution], at: 0)
        let row = try XCTUnwrap(result.rows.first)
        return (lines(result.csv(stepX: 1.5, stepY: 1.5)).filter { !$0.isEmpty }, row)
    }

    /// The Maps room's grains CSV of a 4 × 4 map of one orientation in one phase under `name` (one grain of 16 points), without its
    /// empty last line.
    private static func grainsCSV(phaseNamed name: String) throws -> [String] {
        let grid = CrystalMap.coordinates(shape: (rows: 4, columns: 4), steps: (dy: 1.5, dx: 1.5))
        let phase = CrystalPhase(name: name, spaceGroup: 229, pointGroup: "m-3m", lattice: [2.87, 2.87, 2.87, 90, 90, 90])
        let map = try CrystalMap(euler: Array(repeating: SIMD3<Double>(0.1, 0.2, 0.3), count: 16), phaseIDs: Array(repeating: 0, count: 16),
                                 x: grid.x, y: grid.y, phaseList: PhaseList([(0, phase)]), scanUnit: "um")
        let analysis = try MapAnalysis.run(map, settings: MapAnalysisSettings(boundaryDegrees: 5, minimumSize: 1, kamMaxDegrees: 5))
        XCTAssertEqual(analysis.table.count, 1)
        return lines(MapsRoomFormat.grainsCSV(analysis, slip: [], loadDirection: .z)).filter { !$0.isEmpty }
    }

    private static func diffractionHeader(fileName: String) -> DiffractionExportHeader {
        DiffractionExportHeader(fileName: fileName, centreRow: 256, centreColumn: 256, centreSource: "typed", calibration: "none", deltaQ: nil,
                                wavelengthAngstroms: nil, lengthPixels: nil, lengthMM: nil, fitVersusFilePercent: nil, crystal: "Au",
                                crystalSHA256: nil, kMax: 2, tolerancePercent: 3)
    }

    /// A phase name holding a quote and a comma is one RFC 4180 cell, so every line keeps its twelve fields and the name reads back
    /// whole; a name with only a comma is quoted as before and an ordinary name is written bare, the line unchanged.
    func testAPhaseNameWithAQuoteAndACommaStaysOneCellOfTheIndexingCSV() throws {
        let name = "Fe \"a\", bcc"
        let quoted = try Self.indexingCSV(phaseNamed: name)
        XCTAssertEqual(quoted.lines.count, 2)
        XCTAssertTrue(quoted.lines[1].contains(",\"Fe \"\"a\"\", bcc\","), quoted.lines[1])
        XCTAssertEqual(Self.cells(quoted.lines[0]).count, 12)
        let fields = Self.cells(quoted.lines[1])
        XCTAssertEqual(fields.count, 12, quoted.lines[1])
        XCTAssertEqual(fields[4], name)

        let comma = try Self.indexingCSV(phaseNamed: "Ti, alpha")
        XCTAssertTrue(comma.lines[1].contains(",\"Ti, alpha\","), comma.lines[1])

        let plain = try Self.indexingCSV(phaseNamed: "Ni")
        func number(_ v: Double) -> String { v.isFinite ? String(format: "%.6g", v) : "" }
        let r = plain.row
        XCTAssertEqual(plain.lines[0], "row,column,x,y,phase,phi1_deg,Phi_deg,phi2_deg,ci,fit_deg,matched_bands,pattern_quality")
        XCTAssertEqual(plain.lines[1], "0,0,0,0,Ni,\(number(r.phi1)),\(number(r.capitalPhi)),\(number(r.phi2)),0.5,1,8,10")
    }

    /// The same phase name is one RFC 4180 cell of the Maps room's grains CSV too, so the header and the grain line keep their thirteen
    /// fields and the name reads back whole; a name with only a comma is quoted as before and an ordinary name is written bare. Red
    /// before: the cell was `"Fe "a", bcc"`, which a reader takes as `Fe a, bcc`.
    func testAPhaseNameWithAQuoteAndACommaStaysOneCellOfTheGrainsCSV() throws {
        let name = "Fe \"a\", bcc"
        let quoted = try Self.grainsCSV(phaseNamed: name)
        XCTAssertEqual(quoted.count, 2)
        XCTAssertTrue(quoted[1].contains(",\"Fe \"\"a\"\", bcc\","), quoted[1])
        XCTAssertEqual(Self.cells(quoted[0]).count, 13, quoted[0])
        let fields = Self.cells(quoted[1])
        XCTAssertEqual(fields.count, 13, quoted[1])
        XCTAssertEqual(fields[1], name)

        XCTAssertTrue(try Self.grainsCSV(phaseNamed: "Ti, alpha")[1].hasPrefix("1,\"Ti, alpha\",16,"))
        let plain = try Self.grainsCSV(phaseNamed: "Ni")
        XCTAssertEqual(plain[0], "grain,phase,points,area_um2,ecd_um,phi1_deg,Phi_deg,phi2_deg,gos_deg,neighbours,centroid_column,centroid_row,"
                                 + "schmid_max_load_z")
        XCTAssertTrue(plain[1].hasPrefix("1,Ni,16,"), plain[1])
    }

    /// A line break in the file name stays on the `# file:` line of the Diffraction readout, so every line before the column header is
    /// a comment; a cell holding a carriage return or a quote is quoted with its quotes doubled; an ordinary readout is unchanged.
    func testALineBreakInAFileNameStaysOnTheDiffractionHeaderLine() throws {
        let row = DiffractionReadoutRow(id: UUID(), kind: .ring, number: 1, radiusPx: 33.5, q: 0.25, d: 4, family: "{111}", dListed: 4,
                                        deltaPercent: 0, oddsText: "2 to 1, \"close\"", verdict: "matches\r{111}", validation: "")
        let broken = Self.lines(DiffractionExport.text(rows: [row], header: Self.diffractionHeader(fileName: "a\nb.dm4")))
        let columns = try XCTUnwrap(broken.firstIndex(of: DiffractionExport.columns))
        XCTAssertEqual(columns, 5)
        for line in broken[..<columns] { XCTAssertTrue(line.hasPrefix("#"), line) }
        XCTAssertEqual(broken[1], "# file: a b.dm4")
        XCTAssertEqual(broken[columns + 1], "ring,1,33.5,0.25,4,{111},4,0,\"2 to 1, \"\"close\"\"\",\"matches\r{111}\",")

        let plainRow = DiffractionReadoutRow(id: UUID(), kind: .spot, number: 2, radiusPx: 40, q: 0.5, d: 2, family: "{200}", dListed: 2.04,
                                             deltaPercent: -2, oddsText: "one family", verdict: "matches {200}", validation: "",
                                             isCalibrating: true)
        let plain = DiffractionExport.text(rows: [plainRow], header: Self.diffractionHeader(fileName: "gold rings.dm4"))
        XCTAssertEqual(plain, ["# macTEM diffraction readout",
                               "# file: gold rings.dm4",
                               "# centre: row 256, column 256 (typed)",
                               "# calibration: none; delta_q  per A per px; wavelength  A; L  px; L  mm; fit versus file  %",
                               "# crystal: Au; k_max 2 per A; tolerance 3 % of q",
                               "kind,number,R_px,q_per_A,d_A,family,d_listed_A,delta_percent,odds,verdict,calibrating",
                               "spot,2,40,0.5,2,{200},2.04,-2,one family,matches {200},yes"].joined(separator: "\n") + "\n")
    }

    /// A CIF whose data block names nothing, or only a VESTA placeholder, gives the crystal its file's base name, so a line break in
    /// that name stays on the `# crystal:` line of the Diffraction readout too; an ordinary name and its sha256 give the line they
    /// gave before.
    func testALineBreakInACrystalNameStaysOnTheDiffractionHeaderLine() throws {
        var header = Self.diffractionHeader(fileName: "gold rings.dm4")
        header.crystal = "gold\nfilm"
        header.crystalSHA256 = "ab12"
        let broken = Self.lines(DiffractionExport.text(rows: [], header: header))
        let columns = try XCTUnwrap(broken.firstIndex(of: DiffractionExport.columns))
        XCTAssertEqual(columns, 5)
        for line in broken[..<columns] { XCTAssertTrue(line.hasPrefix("#"), line) }
        XCTAssertEqual(broken[4], "# crystal: gold film sha256 ab12; k_max 2 per A; tolerance 3 % of q")

        header.crystal = "Au"
        let plain = Self.lines(DiffractionExport.text(rows: [], header: header))
        XCTAssertEqual(plain[4], "# crystal: Au sha256 ab12; k_max 2 per A; tolerance 3 % of q")
    }

    /// A line break in the file or region name stays on the first line of the EELS results, spectrum, regions and thickness CSVs and
    /// of the particles CSV; ordinary names give the header lines they gave before.
    func testALineBreakInAFileOrRegionNameStaysOnTheEELSAndParticleHeaderLines() throws {
        let broken = "a\nb.dm4"
        let results = Self.lines(EELSExports.resultsCSV([], fileName: "a\r\nb.dm4", regionName: "Region\n1", thickness: "t", method: "m"))
        XCTAssertEqual(results.first, "# macTEM EELS results, file: a  b.dm4, region: Region 1, " + EELSLiterature.headerLine)
        XCTAssertEqual(Array(results.dropFirst().prefix(2)), ["# t", "# m"])
        XCTAssertEqual(Self.lines(EELSExports.resultsCSV([], fileName: "143.dm4", regionName: "Whole map", thickness: "t", method: "m")).first,
                       "# macTEM EELS results, file: 143.dm4, region: Whole map, " + EELSLiterature.headerLine)

        let low = EELSPlotCurve(origin: -1, step: 0.5, counts: [1, 2])
        let plot = EELSPlotData(regionName: "Region\u{2028}1", pixels: 4, low: low, core: nil, zlpMaskEV: nil, model: nil, edges: [], thickness: nil)
        let spectrum = Self.lines(EELSExports.spectrumCSV(plot, fileName: broken))
        XCTAssertEqual(Array(spectrum.prefix(2)), ["# macTEM EELS spectrum, file: a b.dm4, region: Region 1, 4 px, counts summed over the region",
                                                   "segment,energy_eV,counts,model"])

        let regions = Self.lines(EELSExports.regionsCSV([], fileName: broken))
        XCTAssertEqual(Array(regions.prefix(2)), ["# macTEM EELS regions, file: a b.dm4, " + EELSLiterature.headerLine,
                                                  "region,pixels,i_total,t_over_lambda"])

        let map = try EELSCompute.map(image: try EELSRoomTests.image(), threshold: .fixed(2.5), meanFreePath: nil)
        let diagnostics = Self.lines(EELSCompute.diagnosticsCSV(map, fileName: broken))
        XCTAssertTrue(diagnostics[0].hasPrefix("# macTEM EELS thickness, file: a b.dm4, method: "), diagnostics[0])
        XCTAssertEqual(diagnostics[1], "x,y,t_over_lambda,sigma_counting,i0,i_total,zlp_centre_eV,threshold_eV,thickness_nm,unavailable")

        let report = try ParticleCompute.analyse(pixels: ParticleTests.planted(), width: ParticleTests.width, height: ParticleTests.height,
                                                 settings: ParticleSettings())
        let scale = ParticleScale(perPixel: 0.5, unit: "nm")
        let particles = Self.lines(ParticleFormat.csv(report, scale: scale, fileName: broken))
        XCTAssertEqual(particles[0], "# macTEM particles, file: a b.dm4")
        XCTAssertTrue(particles[1].hasPrefix("# threshold: "), particles[1])
        XCTAssertEqual(Self.lines(ParticleFormat.csv(report, scale: scale, fileName: "p.dm4")).first, "# macTEM particles, file: p.dm4")
    }
}
