//
//  PerformanceJourney.swift
//  How long the app takes for the actions a user waits for, on the demo documents: XCTest metrics (wall clock, memory, CPU) over five
//  iterations. Every iteration is a fresh launch (not measured, except "open"), then the measured action runs from the click to the
//  element that shows its result; waits are on that element, never a sleep. The clock includes XCUITest's own click latency
//  (tens of ms), so read the clock as an upper bound on what a user waits; the app's own time is the signpost interval around its
//  compute (`Signposts` in TEMCore, read by `XCTOSSignpostMetric`), reported beside it. Not part of the per-landing run: name it
//  (`tools/run-tests.sh ui PerformanceJourney`); the numbers go to docs/performance.md.
//

import XCTest

nonisolated final class PerformanceJourney: Journey {
    @MainActor private let performanceApp = XCUIApplication()

    @MainActor
    private func metrics(_ signposts: [String]) -> [any XCTMetric] {
        [XCTClockMetric(), XCTMemoryMetric(application: performanceApp), XCTCPUMetric(application: performanceApp)]
            + signposts.map { XCTOSSignpostMetric(subsystem: "com.mac4dstem.macTEM", category: "performance", name: $0) }
    }

    @MainActor
    private func relaunch(_ arguments: [String]) {
        performanceApp.terminate()
        performanceApp.launchArguments = ["--ui-testing"] + arguments
        performanceApp.launch()
        performanceApp.activate()
        _ = performanceApp.windows.firstMatch.waitForExistence(timeout: 20)
        app = performanceApp
    }

    /// Five iterations; each one: `prepare` (a fresh launch and the way to the room, unmeasured), then `action` measured.
    @MainActor
    private func measureAction(_ arguments: [String], signposts: [String], prepare: () -> Void = {}, action: () -> Void) {
        app = performanceApp
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        options.invocationOptions = [.manuallyStart]
        measure(metrics: metrics(signposts), options: options) {
            relaunch(arguments)
            prepare()
            startMeasuring()
            action()
        }
        performanceApp.terminate()
    }

    @MainActor func testOpenTheDemoImage() {
        app = performanceApp
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        options.invocationOptions = [.manuallyStart]
        measure(metrics: metrics(["open.image"]), options: options) {
            performanceApp.terminate()
            performanceApp.launchArguments = ["--ui-testing", "--demo-fixture"]
            startMeasuring()
            performanceApp.launch()
            XCTAssertTrue(performanceApp.staticTexts["Demo lattice"].firstMatch.waitForExistence(timeout: 60))
        }
        performanceApp.terminate()
    }

    @MainActor func testFFTSpotThenFindSpots() {
        measureAction(["--demo-fixture"], signposts: ["fft.spectrum", "fft.spot", "fft.find"], prepare: {
            _ = performanceApp.staticTexts["Demo lattice"].firstMatch.waitForExistence(timeout: 60)
            waitFor("workspace.fft").click()
            let pane = performanceApp.groups["Fourier transform"].firstMatch
            XCTAssertTrue(pane.waitForExistence(timeout: 60))
            showInspector(waitingFor: "fft.spots.find")
        }, action: {
            let pane = performanceApp.groups["Fourier transform"].firstMatch
            pane.coordinate(withNormalizedOffset: CGVector(dx: 0.5 + 27.0 / 512.0, dy: 0.5)).click()
            waitValue("fft.spotSpacing", timeout: 60) { !$0.isEmpty }
            waitFor("fft.spots.find").click()
            let more = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                self.performanceApp.descendants(matching: .any).matching(identifier: "fft.spotSpacing").count > 2
            }, object: nil)
            XCTAssertEqual(XCTWaiter().wait(for: [more], timeout: 60), .completed, "Find Spots found nothing")
        })
    }

    @MainActor func testEDXQuantify() {
        measureAction(["--demo-spectrum-fixture"], signposts: ["edx.refresh"], prepare: {
            waitFor("workspace.edx", timeout: 30).click()
            let verb = waitFor("workspace.primaryAction", timeout: 60)
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: verb)
            XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 60), .completed)
        }, action: {
            waitFor("workspace.primaryAction").click()
            waitFor("edx.composition.Mg", timeout: 120)
        })
    }

    /// The map is computed when the file opens, so this one is measured from the launch: open, the room, a pixel's t/λ.
    @MainActor func testEELSThickness() {
        app = performanceApp
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        options.invocationOptions = [.manuallyStart]
        measure(metrics: metrics(["eels.map"]), options: options) {
            performanceApp.terminate()
            performanceApp.launchArguments = ["--ui-testing", "--demo-eels-fixture"]
            startMeasuring()
            performanceApp.launch()
            waitFor("workspace.eels", timeout: 30).click()
            waitFor("eels.maps", timeout: 60)
            element("eels.maps").coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.2)).click()
            // The readout is the status line since the maps block became MacEMUI's (2026-10-23).
            let bar = waitFor("status.bar", timeout: 60)
            _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in bar.label.contains("t/\u{03BB}") }, object: nil)], timeout: 60)
        }
        performanceApp.terminate()
    }

    @MainActor func testParticlesCount() {
        measureAction(["--demo-fixture"], signposts: ["particles.analyse"], prepare: {
            _ = performanceApp.staticTexts["Demo lattice"].firstMatch.waitForExistence(timeout: 60)
            showInspector(waitingFor: "particles.show")
        }, action: {
            waitFor("particles.show").click()
            waitValue("particles.counts", timeout: 60) { $0 == "5" }
        })
    }

    @MainActor func testStackFrameStep() {
        measureAction(["--demo-stack-fixture"], signposts: ["stack.frame"], prepare: {
            showInspector(waitingFor: "image.stack.frame")
            waitValue("image.stack.frame", timeout: 30) { $0 == "1" }
        }, action: {
            waitFor("image.stack.next").click()
            waitValue("image.stack.frame", timeout: 30) { $0 == "2" }
        })
    }
}
