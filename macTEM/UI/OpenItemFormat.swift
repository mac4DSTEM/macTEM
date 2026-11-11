//
//  OpenItemFormat.swift
//  Role: an open file's names and picture, pure: the titles that tell two files of one name apart (the quit question, the
//        window's title), the size and calibration line (`OpenItemRowFormat`), a thumbnail's pixels (`OpenItemThumbnailPixels`).
//        The sidebar's Open Files list that drew them is gone (2026-11-10): each file has a window of its own, a tab, so the tab
//        bar is the list of open files, as in Finder and Safari.
//

import ShellLayout
import ShellMetal
import SwiftUI
import ImagoCore
import TEMCore
import TEMSession

// MARK: - Pure text

/// The strings of a row, the Image menu and the open prompts, pure so a test pins them.
nonisolated enum OpenItemRowFormat {
    /// "2048 × 2048".
    static func size(width: Int, height: Int) -> String { "\(width) × \(height)" }

    /// The size and x sampling a row states: a spectrum image's scan (`FileInventory.scan`) when the file has one, else the image's own. A DM4
    /// spectrum image's image is its survey (2048 × 2048 beside a 432 × 172 scan), which is not the size of the data the file holds.
    static func shown(width: Int, height: Int, x: AxisCalibration?, scan: FileInventory.Scan?) -> (width: Int, height: Int, x: AxisCalibration?) {
        guard let scan else { return (width, height, x) }
        let sampling = scan.xScale.flatMap { scale in scan.xUnit.map { AxisCalibration(scale: scale, unit: $0) } }
        return (scan.width, scan.height, sampling)
    }

    /// The x sampling as the Info line writes it (`AppState.openedLine`): a metre axis in nm, µm or mm
    /// (`DisplaySampling`), the unit through `UnitDisplay.label`; nil when x is not calibrated —
    /// the x axis decides, whatever y says.
    static func sampling(_ x: AxisCalibration?) -> (number: String, unit: String)? {
        // A pattern's reciprocal axis is shown in Å⁻¹, the Diffraction room's unit, whatever the file wrote (nm⁻¹ beside Å⁻¹ on one screen).
        if let q = UnitDisplay.reciprocalAngstromsPerPixel(x) { return (UnitDisplay.number(q), "Å⁻¹") }
        guard let shown = DisplaySampling.perPixel(x), shown.isCalibrated else { return nil }
        return (UnitDisplay.number(shown.scale), UnitDisplay.label(shown.unit))
    }

    /// "2048 × 2048 · 0.045 nm/px", or "2048 × 2048 · not calibrated".
    static func detailLine(width: Int, height: Int, x: AxisCalibration?) -> String {
        let size = size(width: width, height: height)
        guard let sampling = sampling(x) else { return "\(size) · not calibrated" }
        return "\(size) · \(sampling.number) \(sampling.unit)/px"
    }

    /// The row's one spoken sentence: "scan.dm4, 2048 by 2048 pixels, 0.045 nanometres per pixel".
    static func accessibilityLabel(name: String, width: Int, height: Int, x: AxisCalibration?) -> String {
        let pixels = "\(name), \(width) by \(height) pixels"
        guard let sampling = sampling(x) else { return "\(pixels), not calibrated" }
        return "\(pixels), \(sampling.number) \(spokenUnit(sampling.unit)) per pixel"
    }

    /// A unit as VoiceOver should say it; a unit with no entry is spoken as written.
    static func spokenUnit(_ label: String) -> String {
        switch label {
        case "nm": "nanometres"
        case "µm": "micrometres"
        case "mm": "millimetres"
        case "Å": "ångströms"
        case "nm⁻¹": "inverse nanometres"
        case "Å⁻¹": "inverse ångströms"
        default: label
        }
    }

    /// The file names that more than one open file carries (compared as written: two folders, one name).
    static func ambiguousNames(_ names: [String]) -> Set<String> {
        var seen: Set<String> = [], repeated: Set<String> = []
        for name in names where !seen.insert(name).inserted { repeated.insert(name) }
        return repeated
    }

    /// The folder a row names in its second line: the parent folder when another open file shares the file's name
    /// (and it has one), else nil.
    static func folder(_ folder: String, isAmbiguous: Bool) -> String? {
        isAmbiguous && !folder.isEmpty ? folder : nil
    }

    /// A row's second line with its folder in front: "data · 68 × 68 · 0.25 nm/px"; unchanged without one.
    static func withFolder(_ line: String, folder: String?) -> String {
        folder.map { "\($0) · \(line)" } ?? line
    }

    /// The name as VoiceOver reads it: "scan.dm4, in data" when the folder tells two files apart.
    static func spokenName(name: String, folder: String?) -> String {
        folder.map { "\(name), in \($0)" } ?? name
    }

    /// The name with its parent folder first ("A/scan.dm4") when another open file shares it: the menus' titles; a
    /// sidebar row shows the plain name and the folder in its second line.
    static func title(name: String, folder: String, isAmbiguous: Bool) -> String {
        isAmbiguous && !folder.isEmpty ? "\(folder)/\(name)" : name
    }

    /// ".dm4, .dm3, .tif, .tiff or .mrc" — the formats the open path names, built from `ImageOpening.readableExtensions`.
    static func extensionList(_ extensions: [String]) -> String {
        let dotted = extensions.map { ".\($0)" }
        switch dotted.count {
        case 0: return ""
        case 1: return dotted[0]
        default: return dotted.dropLast().joined(separator: ", ") + " or " + dotted[dotted.count - 1]
        }
    }

    /// "Open a .dm4, .dm3, .tif, .tiff or .mrc image".
    static var openPrompt: String { "Open a \(extensionList(ImageOpening.readableExtensions)) image" }
}

/// The colormapped pixels of a thumbnail, pure so a test pins the mapping.
nonisolated enum OpenItemThumbnailPixels {
    /// RGBA, premultiplied, row-major. A value in [0, 1] takes the colour the pane's sampler would
    /// (`Colormaps.sampleRGB` on the 256-texel `lut`); the invalid sentinel (−1) and any non-finite or out-of-range value
    /// are transparent, so a masked pixel shows the row's background, as the pane draws it masked.
    static func rgba(_ thumbnail: Thumbnail, lut: [UInt8]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: thumbnail.normalized.count * 4)
        for (index, value) in thumbnail.normalized.enumerated() {
            guard value.isFinite, value >= 0, value <= 1 else { continue }
            let (r, g, b) = Colormaps.sampleRGB(lut, Double(value))
            bytes[index * 4] = r
            bytes[index * 4 + 1] = g
            bytes[index * 4 + 2] = b
            bytes[index * 4 + 3] = 255
        }
        return bytes
    }
}

extension OpenItems {
    /// Every open item's row title: its file name, with the parent folder first where two open files share a name.
    var displayTitles: [OpenItem.ID: String] {
        let names = items.map { $0.url.lastPathComponent }
        let ambiguous = OpenItemRowFormat.ambiguousNames(names)
        var titles: [OpenItem.ID: String] = [:]
        for item in items {
            let name = item.url.lastPathComponent
            titles[item.id] = OpenItemRowFormat.title(
                name: name, folder: item.url.deletingLastPathComponent().lastPathComponent,
                isAmbiguous: ambiguous.contains(name))
        }
        return titles
    }

}
