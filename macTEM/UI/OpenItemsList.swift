//
//  OpenItemsList.swift
//  Role: the sidebar's list of the files open in the window (design study §4) — one 40-pt thumbnail row
//        per `OpenItem`, in opening order, the selection bound to `OpenItems.selection`. Rows describe UI only: the
//        text comes from `OpenItemRowFormat` (pure, tested), the picture from `OpenItemThumbnailPixels` (pure, tested),
//        and every state — the selection, closing, the reads — is `OpenItems`'.
//
//        Observation: the list reads `OpenItems.items` (opening and closing a file) and each row reads its own
//        `OpenItem` (its summary, residency, colormap), so a finished read re-draws one row, not the list. A row's
//        colormapped CGImage is made in `.task(id:)` off the main actor, from the 96-px `Thumbnail` the item keeps
//        (kept through eviction), so a cold item still shows its picture.
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

    /// The picture, off the main actor: the thumbnail through `lut`, at its own size (the view scales it, aspect kept).
    @concurrent
    static func image(_ thumbnail: Thumbnail, lut: [UInt8]) async -> CGImage? {
        let bytes = rgba(thumbnail, lut: lut)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: thumbnail.width, height: thumbnail.height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: thumbnail.width * 4,
                       space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
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

    /// The parent folder of every open file whose name another open file shares (the sidebar rows' second line).
    var ambiguousFolders: [OpenItem.ID: String] {
        let ambiguous = OpenItemRowFormat.ambiguousNames(items.map { $0.url.lastPathComponent })
        var folders: [OpenItem.ID: String] = [:]
        for item in items {
            if let folder = OpenItemRowFormat.folder(item.url.deletingLastPathComponent().lastPathComponent,
                                                     isAmbiguous: ambiguous.contains(item.url.lastPathComponent)) {
                folders[item.id] = folder
            }
        }
        return folders
    }

}

// MARK: - The list

/// The open files, below the rooms. Click or ↑/↓ selects, ⌫ closes the selected one; the order is the order of opening
/// (no drag reorder: it would owe Move Up/Move Down actions for nothing). The header is the column's own, above the
/// list, so it stays while the rows scroll; the selected row is scrolled into view when the selection changes.
struct OpenItemsList: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var openItems = appState.openItems
        let folders = openItems.ambiguousFolders
        let several = openItems.items.count > 1
        VStack(alignment: .leading, spacing: 0) {
            Text("Open Files")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, LayoutPolicy.sidebarSectionHeaderInset)
                .padding(.vertical, LayoutPolicy.sidebarSectionHeaderVerticalPadding)
                .accessibilityAddTraits(.isHeader)
            ScrollViewReader { proxy in
                List(selection: $openItems.selection) {
                    ForEach(openItems.items) { item in
                        OpenItemRow(item: item, folder: folders[item.id], canCloseOthers: several)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .onDeleteCommand { openItems.closeSelected() }
                .accessibilityIdentifier("sidebar.openItems")
                // The least scroll that brings the selected row into view (a nil anchor): a file opened below the
                // fold, or reached by ⌘⇧] or the Image menu, is seen.
                .onChange(of: openItems.selectedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }
}

/// One open file: a 40-pt picture, the name, one line of size and calibration. Reads only its own `OpenItem`.
struct OpenItemRow: View {
    let item: OpenItem
    /// The parent folder, when another open file shares the name: the row's second line starts with it.
    let folder: String?
    let canCloseOthers: Bool
    @Environment(AppState.self) private var appState
    @State private var picture: CGImage?

    /// What the picture is made from; the task re-runs when either changes (a new thumbnail after a re-read, the colormap).
    private struct PictureKey: Equatable {
        let thumbnail: Thumbnail?
        let colormap: ColormapKind
    }

    /// The file's own name; the folder, where it is needed, is in the second line.
    private var title: String { item.url.lastPathComponent }

    var body: some View {
        let summary = item.summary
        let key = PictureKey(thumbnail: summary?.thumbnail, colormap: item.presentation.colormap)
        HStack(spacing: LayoutPolicy.openItemRowSpacing) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                detail(summary)
            }
            Spacer(minLength: 0)
            status
        }
        .frame(height: LayoutPolicy.openItemThumbnailSide)
        .contentShape(Rectangle())
        .help(item.readFailure ?? item.url.path)
        .contextMenu {
            Button("Close") { appState.openItems.close(item.id) }
            Button("Close Others") { appState.openItems.closeOthers(keeping: item.id) }
                .disabled(!canCloseOthers)
            Divider()
            Button("Show in Finder") { DatasetLocationActions.reveal(url: item.url) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel(summary))
        .accessibilityAction(named: "Close") { appState.openItems.close(item.id) }
        .accessibilityAction(named: "Show in Finder") { DatasetLocationActions.reveal(url: item.url) }
        .task(id: key) {
            guard let thumbnail = key.thumbnail else { picture = nil; return }
            let lut = Colormaps.lutRGBA(key.colormap)
            let made = await OpenItemThumbnailPixels.image(thumbnail, lut: lut)
            if !Task.isCancelled { picture = made }
        }
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            if let picture {
                // Pixel aspect kept: the thumbnail has the image's aspect, the frame is square.
                Image(decorative: picture, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: LayoutPolicy.openItemThumbnailSide, height: LayoutPolicy.openItemThumbnailSide)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func detail(_ summary: ImageSummary?) -> some View {
        if let summary {
            let size = OpenItemRowFormat.withFolder(
                OpenItemRowFormat.size(width: summary.width, height: summary.height), folder: folder)
            let full = OpenItemRowFormat.withFolder(
                OpenItemRowFormat.detailLine(width: summary.width, height: summary.height, x: summary.x), folder: folder)
            // The first that fits wins; the size, which every image has, never gets cut (ImagePane's header rule); a
            // folder too long for the row is the part that truncates.
            ViewThatFits(in: .horizontal) {
                Text(verbatim: full).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Text(verbatim: size).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Text(verbatim: size).lineLimit(1).truncationMode(.middle)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            Text("Reading…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var status: some View {
        if item.readFailure != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .help(item.readFailure ?? "")
        } else if item.residency == .reading {
            ProgressView().controlSize(.small)
        }
    }

    private var spokenName: String { OpenItemRowFormat.spokenName(name: title, folder: folder) }

    private func spokenLabel(_ summary: ImageSummary?) -> String {
        var label: String
        if let summary {
            label = OpenItemRowFormat.accessibilityLabel(name: spokenName, width: summary.width, height: summary.height, x: summary.x)
        } else {
            label = "\(spokenName), reading"
        }
        if let failure = item.readFailure { label += ", could not be read: \(failure)" }
        return label
    }
}
