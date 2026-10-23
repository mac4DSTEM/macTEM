// The layout tests (window minimum, widest sidebar at the floor, the process area's drag extremes and toggle restore,
// WindowFillingLayout). The numbers are ShellLayout's (suite task 8, MacEMUI); the class is nonisolated and each test @MainActor.
import ShellLayout
import SwiftUI
import XCTest
@testable import macTEM

nonisolated final class NavigationSeamTests: XCTestCase {

    @MainActor func testInfobarDragReachesBothExtremesWithoutMovingTheFixedBarHeight() {
        let available: CGFloat = 600
        let hidden = ProcessAreaLayout.heights(fraction: 0, available: available)
        XCTAssertEqual(hidden.canvas, available)
        XCTAssertEqual(hidden.process, 0)

        let full = ProcessAreaLayout.heights(fraction: 1, available: available)
        XCTAssertEqual(full.canvas, 0)
        XCTAssertEqual(full.process, available)

        let draggedUp = ProcessAreaLayout.fraction(afterDrag: -300, available: available, from: 0.25)
        XCTAssertEqual(draggedUp, 0.75, accuracy: 0.001)
        let draggedDown = ProcessAreaLayout.fraction(afterDrag: 300, available: available, from: 0.25)
        XCTAssertEqual(draggedDown, 0, accuracy: 0.001)
    }

    /// `PanelNavigation.showProcessArea` (the shell's, held as `panels`) is `processFraction > 0` with a setter that restores `lastProcessFraction`.
    @MainActor func testProcessAreaToggleRestoresTheLastDraggedFraction() {
        let navigation = WorkspaceNavigation()
        navigation.panels.processFraction = 0.6
        navigation.panels.showProcessArea = false
        XCTAssertEqual(navigation.panels.processFraction, 0)
        XCTAssertEqual(navigation.panels.lastProcessFraction, 0.6)
        navigation.panels.showProcessArea = true
        XCTAssertEqual(navigation.panels.processFraction, 0.6)
        XCTAssertEqual(ProcessAreaLayout.toggled(from: 0.6, last: 0.6), 0)
        XCTAssertEqual(ProcessAreaLayout.toggled(from: 0, last: 0.6), 0.6)
    }

    /// The window's own minimum width covers the ideal columns plus both science panes at their floor, so nothing
    /// collapses a panel to make room. Pins the derivation, the 915 it gives, and that it stays above 900.
    @MainActor func testDatasetWindowMinimumWidthCoversTheIdealColumnsAndBothSciencePanes() {
        let required = LayoutPolicy.sidebarWidth.ideal + LayoutPolicy.inspectorWidth.ideal
            + LayoutPolicy.splitColumnDividerAllowance * 2 + LayoutPolicy.scienceMinimum
        XCTAssertGreaterThanOrEqual(LayoutPolicy.datasetWindowMinimumSize.width, required)
        XCTAssertEqual(LayoutPolicy.datasetWindowMinimumSize.width, 915)
        XCTAssertGreaterThanOrEqual(LayoutPolicy.datasetWindowMinimumSize.width, 900)
    }

    /// The sidebar dragged to its maximum must still leave the inspector and both science panes their floor at the
    /// window's minimum. A saved sidebar wider than that crashed every launch in the constraint loop at 915 pt
    /// (mac4DSTEM Gate D 2026-09-28).
    @MainActor func testTheWidestSidebarStillFitsTheMinimumWindow() {
        let required = LayoutPolicy.sidebarWidth.max + LayoutPolicy.inspectorWidth.min
            + LayoutPolicy.splitColumnDividerAllowance * 2 + LayoutPolicy.scienceMinimum
        XCTAssertLessThanOrEqual(required, LayoutPolicy.datasetWindowMinimumSize.width)
    }

    /// The window-width probe answers a finite proposal with itself, whatever the child needs. Red under the old
    /// shape (the split measured directly: 1190 in a 915-pt window) and under `max(proposal, child)`.
    @MainActor func testWindowFillingLayoutReportsTheOfferedSizeNotTheRigidChild() {
        let rigid = CGSize(width: 1190, height: 700)
        let reported = WindowFillingLayout.reportedSize(
            proposal: ProposedViewSize(width: 915, height: 600), child: rigid)
        XCTAssertEqual(reported.width, 915)
        XCTAssertEqual(reported.height, 600)
        // The sidebar's step-aside line reads that width: 915 < 1095.
        XCTAssertFalse(LayoutPolicy.navigatorFits(windowWidth: reported.width, inspectorVisible: true))
    }

    /// An ideal or unbounded query still goes to the child, so the window's ideal and maximum sizes are unchanged.
    /// Red if the layout answered 0 or infinity for those.
    @MainActor func testWindowFillingLayoutDefersIdealAndUnboundedQueriesToTheChild() {
        let child = CGSize(width: 1280, height: 800)
        let ideal = WindowFillingLayout.reportedSize(proposal: .unspecified, child: child)
        XCTAssertEqual(ideal, child)
        let unbounded = WindowFillingLayout.reportedSize(
            proposal: ProposedViewSize(width: .infinity, height: 500), child: child)
        XCTAssertEqual(unbounded.width, 1280)
        XCTAssertEqual(unbounded.height, 500)
    }
}
