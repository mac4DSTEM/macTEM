// The FFT room's Export buttons as data (`FFTExportMenu`, 2026-10-15 placement fix): three items in order, each enabled by
// `ExportSnapshot.fftAvailability`'s rule, a disabled one carrying its reason as help. The availability rule itself is FFTExportSnapshotTests'.
import XCTest
@testable import macTEM

nonisolated final class FFTExportMenuTests: XCTestCase {

    private let allOn = FFTExportAvailability(transform: true, profile: true, spots: true)

    /// The three items, in order, with their words and no reason when all is available. Red under: a title changed, an item
    /// dropped or reordered, a reason on an enabled item.
    func testTheItemsAreNamedAndOrdered() {
        let entries = FFTExportMenu.entries(allOn, hasSpectrum: true)
        XCTAssertEqual(entries.map(\.title), ["Transform PNG…", "Radial profile CSV…", "Spots CSV…"])
        XCTAssertEqual(entries.map(\.isEnabled), [true, true, true])
        XCTAssertEqual(FFTExportMenu.Item.allCases.map(\.identifier), ["fft.export.transform", "fft.export.profile", "fft.export.spots"])
    }

    /// Why an item is off, by cause, as its help; the title never changes. Red under: a reason dropped, put back in the title, or the
    /// same words for every cause.
    func testTheItemsSayWhyTheyAreOff() {
        let noSpot = FFTExportMenu.entries(FFTExportAvailability(transform: true, profile: true, spots: false), hasSpectrum: true)
        XCTAssertEqual(noSpot[2].help, "measure a spot first")
        XCTAssertEqual(noSpot[2].title, "Spots CSV…")
        XCTAssertEqual(noSpot[0].help, FFTExportMenu.Item.transform.saves, "an enabled button says what it saves")
        let noBins = FFTExportMenu.entries(FFTExportAvailability(transform: true, profile: false, spots: true), hasSpectrum: true)
        XCTAssertEqual(noBins[1].help, "no radial profile for this transform")
        let updating = FFTExportMenu.entries(FFTExportAvailability(transform: false, profile: false, spots: false), hasSpectrum: true)
        XCTAssertEqual(updating[0].help, "the transform is updating")
        let none = FFTExportMenu.entries(FFTExportAvailability(transform: false, profile: false, spots: false), hasSpectrum: false)
        XCTAssertEqual(none.map(\.help), ["no transform yet", "no transform yet", "no transform yet"])
        XCTAssertEqual(none.map(\.title), ["Transform PNG…", "Radial profile CSV…", "Spots CSV…"])
    }

    /// Each item is enabled exactly when the availability says so. Red under: an item enabled by another's flag (Spots with no spot).
    func testEachItemFollowsItsOwnAvailability() {
        for (transform, profile, spots) in [(true, false, false), (false, true, false), (false, false, true), (true, true, false)] {
            let entries = FFTExportMenu.entries(FFTExportAvailability(transform: transform, profile: profile, spots: spots), hasSpectrum: true)
            XCTAssertEqual(entries.map(\.isEnabled), [transform, profile, spots])
            XCTAssertEqual(entries.map { $0.reason != nil }, [!transform, !profile, !spots], "a reason exactly when it is off")
        }
    }

    /// Each item opens its own panel, the call its File menu twin makes, and the row runs the item's panel. A function value cannot
    /// be compared, so the mapping is pinned at the source. Red under: the Radial Profile item calling the Spots export (or any swap),
    /// the row running something other than the item's panel.
    func testEachItemOpensItsOwnPanel() throws {
        let source = try FFTRoomWiringTests.squeezedUI("FFTRoomExport.swift")
        let calls: [FFTExportMenu.Item: String] = [.transform: "exportTransform", .profile: "exportRadialProfile", .spots: "exportSpots"]
        XCTAssertEqual(Set(calls.keys), Set(FFTExportMenu.Item.allCases))
        for (item, call) in calls {
            XCTAssertTrue(source.contains("case .\(item): ExportPanels.\(call) "), "\(item) opens ExportPanels.\(call)")
        }
        XCTAssertEqual(source.components(separatedBy: "ExportPanels.export").count - 1, 3, "no other panel call in the file")
        XCTAssertTrue(source.contains("Button(entry.title) { entry.item.panel(appState) }"), "the row runs the item's own panel")
        XCTAssertTrue(source.contains("InspectorSection(\"Export\")") && source.contains("InspectorActionRow {"), "an Export section of action rows")
        XCTAssertTrue(source.contains(".help(entry.help)") && source.contains(".disabled(!entry.isEnabled)"), "disabled, with the reason as help")
        XCTAssertFalse(source.contains("InspectorAdaptiveMenu") || source.contains(" Menu {"), "no pull-down")
    }

    /// The pull-down's help says what each item saves and that the panel flags a PNG of another shape. Red under: the sentence dropped.
    func testTheHelpSaysWhatEachItemSaves() {
        let help = FFTExportMenu.help
        for part in ["PNG", "scale bar", "the panel says when its shape differs", "the mean |F|²", "pixel count", "whether each is in the mask"] {
            XCTAssertTrue(help.contains(part), "the help names \(part): \(help)")
        }
    }
}
