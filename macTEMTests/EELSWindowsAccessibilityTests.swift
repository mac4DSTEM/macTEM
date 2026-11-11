//
//  EELSWindowsAccessibilityTests.swift
//  The EELS spectrum without a pointer: what it says (the energies shown and each picked edge's background and signal windows) and how a window is set
//  without a drag (one step of an adjustable element, "Widen" and "Narrow" for its upper end, the zoom and the pan as named actions).
//
//  WHAT IS PINNED: the words, exactly; the step (1 % of the core loss's range, never under one channel); and that a step is the drag's own move
//  (`EELSEdgeWindows.moved`), so it stops where a drag would. The windows decide I, at% and wt%: no step makes a window the drag could not.
//

import XCTest
import TEMCore

nonisolated final class EELSWindowsAccessibilityTests: XCTestCase {

    private static let windows = EELSEdgeWindows(background: 650...700, signal: 708...758)
    private static let english = Locale(identifier: "en_US")

    /// The spectrum's spoken value: the energies shown, then each edge's windows by name, in the reader's decimal mark. Red under: no value at all (the
    /// spectrum was a label only); an edge's windows left out.
    func testTheSpectrumSaysTheEnergiesShownAndEachEdgesWindows() {
        XCTAssertEqual(EELSRoomFormat.windowsSpeech(items: [(title: "Fe L2,3", windows: Self.windows)], shown: 283...1200, locale: Self.english),
                       "283 to 1200 eV shown; Fe L2,3 background 650 to 700 eV, signal 708 to 758 eV")
        XCTAssertEqual(EELSRoomFormat.windowsSpeech(items: [], shown: 0.5...1200, locale: Self.english), "0.5 to 1200 eV shown", "no edge picked: the energies alone")
        let carbon = EELSEdgeWindows(background: 240...280, signal: 284...334)
        XCTAssertEqual(EELSRoomFormat.windowsSpeech(items: [(title: "C K", windows: carbon), (title: "Fe L2,3", windows: Self.windows)], shown: 200...900,
                                                    locale: Self.english),
                       "200 to 900 eV shown; C K background 240 to 280 eV, signal 284 to 334 eV; Fe L2,3 background 650 to 700 eV, signal 708 to 758 eV")
        XCTAssertEqual(EELSRoomFormat.energySpan(650.5...700, locale: Locale(identifier: "de_DE")), "650,5 to 700 eV")
        XCTAssertEqual(EELSRoomFormat.windowName(edge: "Fe L2,3", isSignal: false), "Fe L2,3 background window")
        XCTAssertEqual(EELSRoomFormat.windowName(edge: "Fe L2,3", isSignal: true), "Fe L2,3 signal window")
    }

    /// One step is a hundredth of the core loss's energy range, and never less than one channel. Red under: a step of one channel on a 2048-channel
    /// axis (two thousand presses to cross it); a step under a channel on a short axis.
    func testOneStepIsAHundredthOfTheCoreLossAndNeverLessThanAChannel() {
        let core = EELSPlotCurve(origin: 200, step: 1, counts: [Double](repeating: 1, count: 701))   // 200 to 900 eV
        XCTAssertEqual(EELSWindowStep.stride(core: core), 7)
        let short = EELSPlotCurve(origin: 200, step: 0.5, counts: [Double](repeating: 1, count: 21))   // 200 to 210 eV: 1 % is 0.1 eV, under a channel
        XCTAssertEqual(EELSWindowStep.stride(core: short), 0.5)
    }

    /// A step is the drag's own move by one stride, up or down, and stops where a drag would: at the ends of the core loss, at the other window. Red under:
    /// a step with arithmetic of its own (a window pushed past the axis or into the other window).
    func testAStepIsTheDragsOwnMoveAndStopsWhereADragWould() {
        let w = Self.windows
        let limit: ClosedRange<Double> = 600...760
        let handles: [EELSEdgeWindows.Handle] = [.backgroundBody, .backgroundUpper, .signalBody, .signalUpper]
        for handle in handles {
            XCTAssertEqual(EELSWindowStep.stepped(w, handle: handle, increment: true, step: 7, within: limit), w.moved(handle, by: 7, within: limit))
            XCTAssertEqual(EELSWindowStep.stepped(w, handle: handle, increment: false, step: 7, within: limit), w.moved(handle, by: -7, within: limit))
        }
        // Adjusting moves the whole window and keeps its width; the signal stops at the end of the core loss.
        XCTAssertEqual(EELSWindowStep.stepped(w, handle: .signalBody, increment: true, step: 7, within: limit).signal, 710...760)
        XCTAssertEqual(EELSWindowStep.stepped(w, handle: .backgroundBody, increment: false, step: 7, within: limit).background, 643...693)
        var down = w
        for _ in 0..<20 { down = EELSWindowStep.stepped(down, handle: .backgroundBody, increment: false, step: 7, within: limit) }
        XCTAssertEqual(down.background, 600...650, "the background stops at the start of the core loss")
        XCTAssertEqual(down.signal, w.signal, "and leaves the signal window alone")
        // Widen and Narrow move the upper end; the background's stops at the signal window.
        XCTAssertEqual(EELSWindowStep.stepped(w, handle: .signalUpper, increment: false, step: 7, within: limit).signal, 708...751)
        XCTAssertEqual(EELSWindowStep.stepped(w, handle: .signalUpper, increment: true, step: 7, within: limit).signal, 708...760)
        let once = EELSWindowStep.stepped(w, handle: .backgroundUpper, increment: true, step: 7, within: limit)
        XCTAssertEqual(once.background, 650...707)
        XCTAssertEqual(EELSWindowStep.stepped(once, handle: .backgroundUpper, increment: true, step: 7, within: limit).background, 650...708)
    }

    /// The spectrum carries the value, the window elements and the named actions, and each element's change goes through the step and the drag's own
    /// `onWindows`. Red under: the spectrum a label alone; the windows reachable only by a drag; the zoom only by pinch, scroll or drag.
    func testTheSpectrumCarriesItsValueItsWindowElementsAndItsNamedActions() throws {
        let source = try FFTRoomWiringTests.squeezedUI("EELSRoom.swift")
        XCTAssertTrue(source.contains("let spoken = EELSRoomFormat.windowsSpeech(items: items.map { (title: EELSFitCompute.title($0.edge), windows: $0.windows) }, shown: w)"))
        XCTAssertTrue(source.contains(".accessibilityChildren { if let core = plot.core { EELSWindowElements(items: items, core: core, onWindows: onWindows) } }"))
        for name in ["Zoom in", "Zoom out", "Pan left", "Pan right", "Show whole spectrum", "Widen", "Narrow"] {
            XCTAssertTrue(source.contains(".accessibilityAction(named: \"\(name)\")"), "no \"\(name)\" action")
        }
        XCTAssertTrue(source.contains(".accessibilityAdjustableAction { direction in switch direction { case .increment: move(whole, up: true) case .decrement: move(whole, up: false)"))
        XCTAssertTrue(source.contains("onWindows(item.edge, EELSWindowStep.stepped(item.windows, handle: handle, increment: up, step: step, within: core.range))"),
                      "a step is handed to the same onWindows as a drag")
    }
}
