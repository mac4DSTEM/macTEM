//
//  DemoData.swift
//  Role: Help > Open Demo Data and the welcome canvas's Try Demo Data. The generated demo documents (TEMSession's DemoDocuments) and
//        the shipped ones (`DemoDocuments.Shipped`, real licensed files in the bundle) opened from the menu, so anyone without a
//        microscope file, App Review first, can try every room (macTEM#105). The launch options for the UI tests open the same
//        documents through `openDemo`, so the menu and the tests cannot drift apart.
//

import Foundation
import TEMSession
import ShellEDXModel
import ShellSpectroscopy

nonisolated enum DemoDocument: String, CaseIterable, Identifiable, Sendable {
    case lattice, diffraction, edx, eels
    /// The shipped SEM-EDS spectrum (`DemoDocuments.Shipped.semEDSSpectrum`), opened through the app's own Open like a file from disk.
    case semSpectrum
    /// The shipped nickel EBSD scan (`DemoDocuments.Shipped.nickelEBSD`), opened through the app's own Open into the Patterns room.
    case ebsd
    /// The shipped two-phase orientation map (`DemoDocuments.Shipped.duplexSteelMap`), opened through the app's own Open into the Maps room.
    case orientationMap

    var id: String { rawValue }

    /// The menu title: what the document is, then the room it opens in.
    var title: String {
        switch self {
        case .lattice: "Lattice Image"
        case .diffraction: "Au Diffraction Pattern"
        case .edx: "EDX Spectrum Image"
        case .eels: "EELS Spectrum Image"
        case .semSpectrum: DemoDocuments.Shipped.semEDSSpectrum.title
        case .ebsd: DemoDocuments.Shipped.nickelEBSD.title
        case .orientationMap: DemoDocuments.Shipped.duplexSteelMap.title
        }
    }

    /// The room the document is shown in once open.
    var room: WorkspaceArea {
        switch self {
        case .lattice: .image
        case .diffraction: .diffraction
        case .edx, .semSpectrum: .edx
        case .eels: .eels
        case .ebsd: .patterns
        case .orientationMap: .maps
        }
    }
}

extension AppState {
    /// Opens one generated demo document and shows its room. `regions` draws the UI tests' two rectangles and line on a
    /// spectrum image (`--demo-regions`); the menu never does. Returns the image open's task (the two images load like a
    /// file, the EBSD dataset's first pattern); the spectrum images bind at once.
    @discardableResult
    func openDemo(_ demo: DemoDocument, regions: Bool = false) -> Task<Void, Never>? {
        var task: Task<Void, Never>?
        switch demo {
        case .lattice:
            task = open(urls: [DemoDocuments.latticeURL])
        case .diffraction:
            task = open(urls: [DemoDocuments.patternURL])
        case .edx:
            edx.bind(DemoDocuments.edx())
            if regions { DemoDocuments.drawRegions(on: edx) }
        case .eels:
            guard let loaded = try? DemoDocuments.eels() else { return nil }
            eels.bind(loaded)
            if regions { DemoDocuments.drawRegions(on: eels) }
        case .semSpectrum:
            // The file in the bundle, through the Open route (`FileRouting`: a `.hspy` of one spectrum lands in the EDS room).
            guard let url = DemoDocuments.Shipped.semEDSSpectrum.url else { return nil }
            task = open(urls: [url])
        case .ebsd:
            // The file in the bundle, through the Open route (`FileRouting`: an h5ebsd file lands in the Patterns room).
            guard let url = DemoDocuments.Shipped.nickelEBSD.url else { return nil }
            task = open(urls: [url])
        case .orientationMap:
            // The file in the bundle, through the Open route (`FileRouting`: an `.ang` without patterns lands in the Maps room).
            guard let url = DemoDocuments.Shipped.duplexSteelMap.url else { return nil }
            task = open(urls: [url])
        }
        navigation.workspaceArea = demo.room
        return task
    }
}
