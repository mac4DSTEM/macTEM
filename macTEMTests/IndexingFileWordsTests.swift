//
//  IndexingFileWordsTests.swift
//  The Indexing room's words that a file quotes are in `en_US_POSIX` (#302): the Refine settings and the dictionary's master pattern
//  and energy reach the session report through `SEMSessionLedger` with `ExportSnapshot.labelLocale`, and the dictionary method JSON
//  writes its `energy` words with a point; the screen keeps the reader's locale. The process locale cannot be changed from inside a
//  test, so each file string is pinned to the literal of the explicit `en_US_POSIX` call, and de_DE is the control that the literal
//  separates the two locales. A master pattern at 10 and 12.5 kV gives the energy a decimal mark (only the words read its energies).
//  Red before: `IndexingRefineSettings.words`, `IndexingMasterPattern.summary` and the energy words had no `locale` form, and the
//  report and the method JSON wrote them in the reader's locale ("12,5 kV" on a German Mac).
//

import Foundation
import FormatoCore
import TEMCore
import TEMSession
import XCTest
@testable import macTEM

nonisolated final class IndexingFileWordsTests: XCTestCase {
    private static let report = ExportSnapshot.labelLocale
    private static let german = Locale(identifier: "de_DE")

    /// The shipped Ni master pattern with `energies` in place of its one 20 kV.
    private func masterPattern(energies: [Double]) throws -> IndexingMasterPattern {
        let url = try XCTUnwrap(DemoDocuments.Shipped.nickelMasterPattern.url, "DemoData/ holds no master pattern")
        let read = try IndexingMasterPattern.load(url)
        var master = read.master
        master.energies = energies
        return IndexingMasterPattern(url: read.url, master: master)
    }

    /// A plan of `phase` against `master` for a 1 × 1 scan of 4 × 4 px patterns with one projection centre and one orientation:
    /// nothing is projected, the plan carries the words.
    private func plan(_ phase: IndexingPhase, master: IndexingMasterPattern, beamEnergy: Double?) throws -> DictionaryIndexingPlan {
        let side = 4
        let dataset = EBSDDataset(format: .generated, manufacturer: "test", version: "", scanGroup: "s", scanGroups: ["s"], scanRows: 1,
                                  scanColumns: 1, patternRows: side, patternColumns: side, dataType: .uint8, stepY: 1, stepX: 1,
                                  detector: EBSDDetectorGeometry(rows: side, columns: side, projectionCenters: [SIMD3(0.5, 0.2, 0.5)]),
                                  patterns: EBSDPatternSource(url: URL(fileURLWithPath: "/planted"), datasetPath: "",
                                                              fileShape: [1, 1, side, side], dataType: .uint8))
        let access = try EBSDMemoryPatterns(dataset: dataset, bytes: Data(count: side * side))
        return try DictionaryIndexingPlan(source: IndexingSource(processed: access), phase: phase, master: master, settings: .roomDefault,
                                          fileDetector: dataset.detector, beamEnergy: beamEnergy, rotations: [SIMD4<Double>(1, 0, 0, 0)])
    }

    private func preset(_ name: String) throws -> IndexingPhase {
        try XCTUnwrap(IndexingPhase.presets.first { $0.name == name })
    }

    /// The Refine words the report's row takes (the ledger passes its locale): the trust region with a point, the screen's with the
    /// reader's mark. Red under: the ledger's Refine row made with `words`, which drops the locale (the de_DE control reads a point).
    func testTheRefineWordsHaveAPointInTheReport() {
        let both = IndexingRefineSettings(target: .both, trustAngle: 2.5, trustPC: 0.05)
        XCTAssertEqual(both.words(locale: Self.report), "Both · ±2.5° · PC ±0.05 · Nelder–Mead")
        XCTAssertEqual(both.words(locale: Self.german), "Both · ±2,5° · PC ±0,05 · Nelder–Mead", "the control: de_DE writes a comma")
        XCTAssertEqual(both.words, both.words(locale: .autoupdatingCurrent), "Output and Info keep the reader's locale")
        XCTAssertEqual(IndexingRefineSettings().words(locale: Self.report), "Orientation · ±2° · Nelder–Mead")

        let row = SEMSessionLedger.refineField(both, locale: Self.report)
        XCTAssertEqual(row.name, "Refine")
        XCTAssertEqual(row.value, "Both · ±2.5° · PC ±0.05 · Nelder–Mead")
        XCTAssertEqual(SEMSessionLedger.refineField(both, locale: Self.german).value, "Both · ±2,5° · PC ±0,05 · Nelder–Mead", "the control")
    }

    /// The Refine words write the trust region as its typed field shows it (`Num.decimalField`, four significant digits), in
    /// `UnitDisplay.number`'s printf digits, so the words name the setting the run used. Red before: three significant digits dropped
    /// the fourth, "±2.68°" by FormatStyle and then "±2.67°" by printf for a trust typed as 2.675°.
    func testTheRefineWordsWriteTheTrustAsItsField() {
        let typed = IndexingRefineSettings(target: .orientation, trustAngle: 2.675)
        XCTAssertEqual(typed.words(locale: Self.report), "Orientation · ±2.675° · Nelder–Mead")
        XCTAssertEqual(typed.words(locale: Self.german), "Orientation · ±2,675° · Nelder–Mead")
        let long = IndexingRefineSettings(target: .both, trustAngle: 1.23456, trustPC: 0.012346)
        XCTAssertEqual(long.words(locale: Self.report),
                       "Both · ±\(1.23456.formatted(Num.decimalField.locale(Self.report)))° · "
                       + "PC ±\(0.012346.formatted(Num.decimalField.locale(Self.report))) · Nelder–Mead", "the fields' digits")
        XCTAssertEqual(long.words(locale: Self.report), "Both · ±1.235° · PC ±0.01235 · Nelder–Mead")
        XCTAssertEqual(IndexingRefineSettings(target: .projectionCenter, trustPC: 0.0125).words(locale: Self.report), "PC · PC ±0.0125 · Nelder–Mead")
    }

    /// The master pattern's energies and the energy a dictionary is projected for, in the locale asked for; the room's words stay in
    /// the reader's.
    func testTheEnergyWordsTakeTheLocaleAskedFor() throws {
        let range = try masterPattern(energies: [10, 12.5, 15])
        XCTAssertEqual(range.energyWords(locale: Self.report), "10 to 15 kV")
        let low = try masterPattern(energies: [10, 12.5])
        XCTAssertEqual(low.energyWords(locale: Self.report), "10 to 12.5 kV")
        XCTAssertEqual(low.energyWords(locale: Self.german), "10 to 12,5 kV", "the control")
        XCTAssertEqual(low.summary(locale: Self.report), "ni · 10 to 12.5 kV · Lambert · 401 × 401")
        XCTAssertEqual(low.summary(locale: Self.german), "ni · 10 to 12,5 kV · Lambert · 401 × 401", "the control")
        XCTAssertEqual(low.summary, low.summary(locale: .autoupdatingCurrent), "the Dictionary section keeps the reader's locale")

        let beam = try DictionaryIndexingPlan.energy(master: range.master, beamEnergy: 12.5, locale: Self.report).get()
        XCTAssertEqual(beam.value, 12.5)
        XCTAssertEqual(beam.words, "12.5 kV, the scan's beam energy")
        XCTAssertEqual(try DictionaryIndexingPlan.energy(master: range.master, beamEnergy: 12.5, locale: Self.german).get().words,
                       "12,5 kV, the scan's beam energy", "the control")
        XCTAssertEqual(try DictionaryIndexingPlan.energy(master: range.master, beamEnergy: 12.5).get().words,
                       try DictionaryIndexingPlan.energy(master: range.master, beamEnergy: 12.5, locale: .autoupdatingCurrent).get().words,
                       "the room's words are the reader's")
    }

    /// The dictionary method JSON's `energy` words have a point, one plan's and each phase's of a run against several; `energyKeV`
    /// beside them is the number. The plan's own words are the reader's. Red under, on a Mac that writes a comma: the record built
    /// with `energyWords`.
    func testTheMethodJSONWritesTheEnergyWithAPoint() throws {
        let master = try masterPattern(energies: [10, 12.5])
        let ni = try plan(try preset("Ni"), master: master, beamEnergy: 12.5)
        XCTAssertEqual(ni.energy, 12.5)
        XCTAssertEqual(ni.energyWords(locale: Self.report), "12.5 kV, the scan's beam energy", "the beam energy the plan was built for")
        XCTAssertEqual(ni.energyWords(locale: Self.german), "12,5 kV, the scan's beam energy", "the control")
        XCTAssertEqual(ni.energyWords, ni.energyWords(locale: .autoupdatingCurrent), "Info keeps the reader's locale")

        let oneJSON = try ni.methodJSON(fileName: "scan.h5", points: 1, indexed: 1)
        let one = try XCTUnwrap(try JSONSerialization.jsonObject(with: oneJSON) as? [String: Any])
        XCTAssertEqual(one["energy"] as? String, "12.5 kV, the scan's beam energy")
        XCTAssertEqual(one["energyKeV"] as? Double, 12.5)

        let al = try plan(try preset("Al"), master: master, beamEnergy: 12.5)
        let mergedJSON = try DictionaryIndexingPlan.methodJSON([ni, al], fileName: "scan.h5", points: 1, indexed: 1, indexedByPhase: [1, 0])
        let merged = try XCTUnwrap(try JSONSerialization.jsonObject(with: mergedJSON) as? [String: Any])
        let phases = try XCTUnwrap(merged["phases"] as? [[String: Any]])
        XCTAssertEqual(phases.map { $0["energy"] as? String }, ["12.5 kV, the scan's beam energy", "12.5 kV, the scan's beam energy"])
    }

    /// The report's Master, Energy and phase master rows: the Info words' shape, the energies in the report's locale. Red under: the
    /// ledger's rows made with `IndexingInfoFormat.master`, `phaseMaster` or `energyWords` (the de_DE control reads a point).
    func testTheReportsDictionaryRowsHaveAPoint() throws {
        let master = try masterPattern(energies: [10, 12.5])
        let ni = try plan(try preset("Ni"), master: master, beamEnergy: 12.5)
        let al = try plan(try preset("Al"), master: master, beamEnergy: 12.5)
        func values(_ plans: [DictionaryIndexingPlan], _ locale: Locale) -> [String: String] {
            Dictionary(SEMSessionLedger.dictionaryFields(plans, locale: locale).map { ($0.name, $0.value) },
                       uniquingKeysWith: { first, _ in first })
        }
        let file = master.fileName
        XCTAssertEqual(values([ni], Self.report)["Master"], "\(file) · ni · 10 to 12.5 kV · Lambert · 401 × 401")
        XCTAssertEqual(values([ni], Self.german)["Master"], "\(file) · ni · 10 to 12,5 kV · Lambert · 401 × 401", "the control")
        XCTAssertEqual(values([ni], Self.report)["Energy"], "12.5 kV, the scan's beam energy")
        XCTAssertEqual(values([ni], Self.german)["Energy"], "12,5 kV, the scan's beam energy", "the control")
        XCTAssertEqual(values([ni], Self.report)["Dictionary"], IndexingInfoFormat.dictionary(ni, locale: Self.report))
        XCTAssertEqual(values([ni, al], Self.report)["Ni master"], "\(file) · 12.5 kV, the scan's beam energy")
        XCTAssertEqual(values([ni, al], Self.report)["Al master"], "\(file) · 12.5 kV, the scan's beam energy")
        XCTAssertEqual(values([ni, al], Self.german)["Al master"], "\(file) · 12,5 kV, the scan's beam energy", "the control")
        XCTAssertEqual(values([ni, al], Self.report)["Dictionary"], IndexingInfoFormat.dictionaries([ni, al], locale: Self.report))

        // In the reader's locale the rows read as the Indexing room's Info rows.
        let reader = Locale.autoupdatingCurrent
        XCTAssertEqual(SEMSessionLedger.dictionaryFields([ni], locale: reader).map(\.value),
                       [IndexingInfoFormat.master(ni), ni.energyWords, IndexingInfoFormat.dictionary(ni)])
        XCTAssertEqual(SEMSessionLedger.dictionaryFields([ni, al], locale: reader).map(\.name), ["Ni master", "Al master", "Dictionary"])
        XCTAssertEqual(SEMSessionLedger.dictionaryFields([ni, al], locale: reader).map(\.value),
                       [IndexingInfoFormat.phaseMaster(ni), IndexingInfoFormat.phaseMaster(al), IndexingInfoFormat.dictionaries([ni, al])])
        XCTAssertTrue(SEMSessionLedger.dictionaryFields([], locale: reader).isEmpty)
    }
}
