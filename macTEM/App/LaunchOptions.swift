//
//  LaunchOptions.swift
//  Role: the launch arguments the UI tests (and a person) start the app with, read in the App target only, never in a kit
//        (docs: macEM-suite process/ui-testing-2026-10-21.md section 2).
//
//          --ui-testing            ignore the saved window and split geometry and the saved application state, so every launch is the same window
//          --demo-fixture          open the generated "Demo lattice" image (DemoDocuments, in memory)
//          --demo-diffraction-fixture open the generated "Demo Au pattern" (a ring pattern with planted centre and scale) in the Diffraction room
//          --demo-spectrum-fixture open the generated "Demo EDX" spectrum image in the EDX room
//          --demo-eels-fixture     open the generated "Demo EELS" spectrum image in the EELS room
//          --demo-regions          with the EDX fixture: two rectangles (4 x 4 and 8 x 8 pixels) and a line across the maps, as if drawn
//          --demo-stack-fixture    open the generated "Demo stack" (24 frames, a multi-page TIFF written to the temporary folder)
//          --demo-msa-fixture      open the demo EDX spectrum as an .msa file through the app's Open (routed by content to the EDX room)
//          --appearance light|dark force the window's colour scheme (the system's otherwise)
//          --open <path>           (repeatable) open that file at launch through a drop's path, after the demo fixtures; an absolute path only
//          --export-dir <path>     where an export journey writes without a save panel (Export Results); relative: inside the app's temporary folder
//

import Foundation

struct LaunchOptions: Equatable {
    var isUITesting = false
    var demoImage = false
    var demoPattern = false
    var demoSpectrum = false
    var demoEELS = false
    var demoStack = false
    var demoSpectrumFile = false
    var demoRegions = false
    /// `--appearance light|dark`: the colour scheme the window is forced to (a journey's light-mode screenshot), else the system's.
    var appearance: String?
    /// `--open <path>`, in the order given: absolute paths only (a relative one is refused, nothing to resolve it against).
    var openFiles: [URL] = []
    var exportDirectory: URL?
    /// The argument as given: a relative one names a folder inside the app's temporary folder.
    var exportDirectoryName: String?
    var exportDirectoryIsRelative: Bool { exportDirectoryName.map { !$0.hasPrefix("/") } ?? false }

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        isUITesting = arguments.contains("--ui-testing")
        demoImage = arguments.contains("--demo-fixture")
        demoPattern = arguments.contains("--demo-diffraction-fixture")
        demoSpectrum = arguments.contains("--demo-spectrum-fixture")
        demoEELS = arguments.contains("--demo-eels-fixture")
        demoRegions = arguments.contains("--demo-regions")
        demoStack = arguments.contains("--demo-stack-fixture")
        demoSpectrumFile = arguments.contains("--demo-msa-fixture")
        for (i, argument) in arguments.enumerated() where argument == "--open" && arguments.indices.contains(i + 1) && arguments[i + 1].hasPrefix("/") {
            openFiles.append(URL(fileURLWithPath: arguments[i + 1]))
        }
        if let i = arguments.firstIndex(of: "--appearance"), arguments.indices.contains(i + 1), ["light", "dark"].contains(arguments[i + 1]) {
            appearance = arguments[i + 1]
        }
        if let i = arguments.firstIndex(of: "--export-dir"), arguments.indices.contains(i + 1) {
            exportDirectoryName = arguments[i + 1]
            exportDirectory = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
        }
    }

    /// The saved window geometry a UI test must not inherit: the keys `tools/run-tests.sh clear_test_host_geometry` clears, in code.
    static func clearSavedGeometry(in defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("NSWindow Frame") || key.hasPrefix("NSSplitView Subview Frames") {
            defaults.removeObject(forKey: key)
        }
    }

    /// A UI-testing launch starts from no saved window geometry and no saved application state, before any window is made (mac4DSTEM's
    /// `UITestingLaunch.resetSavedState`, the same reset). A launch that quit with the window closed (or was killed by the test) leaves a saved state
    /// that the next launch restores into no window at all, `-ApplePersistenceIgnoreState` notwithstanding (open-items 2026-10-23: only `open -F`
    /// and a clean quit cleared it); removing the saved state is what `open -F` does. Never for a person's launch.
    static func resetSavedState(defaults: UserDefaults = .standard, home: String = NSHomeDirectory(),
                                bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        clearSavedGeometry(in: defaults)
        if let id = bundleIdentifier {
            let saved = URL(fileURLWithPath: home).appendingPathComponent("Library/Saved Application State/\(id).savedState")
            try? FileManager.default.removeItem(at: saved)
        }
        defaults.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }
}
